import Foundation

// Pure-Swift incremental MPEG-TS demuxer for Twitch low-latency HLS segments.
//
// Designed for chunked HTTP streaming (`#EXT-X-TWITCH-PREFETCH`): call `push(_:)` as each
// network chunk arrives and frames are emitted immediately as soon as the next PES header
// arrives (and `flushSegment()` emits the final PES packet when a segment finishes).
//
// Handles:
// - 188-byte packet framing and sync recovery (`0x47`)
// - PAT (PID 0) and PMT parsing (`0x1B` H.264 video, `0x0F` ADTS AAC audio)
// - H.264 Annex-B -> 4-byte length-prefixed AVCC conversion + SPS/PPS extraction
// - ADTS AAC parsing (7- and 9-byte headers, multi-frame PES, 2-byte AudioSpecificConfig)
// - 33-bit 90 kHz PTS/DTS unwrapping and seamless timeline rebasing across `#EXT-X-DISCONTINUITY`

public struct DemuxedVideoFrame: Sendable, Equatable {
    /// 4-byte length-prefixed AVCC NALU payload (VCL slices only; SPS/PPS/AUD stripped).
    public let avccData: Data
    /// Continuous presentation timestamp in 90 kHz ticks.
    public let pts90k: Int64
    /// Continuous decode timestamp in 90 kHz ticks (may be earlier than `pts90k` when B-frames are present).
    public let dts90k: Int64
    /// True when this access unit contains an IDR slice (NALU type 5).
    public let isKeyframe: Bool
    /// Current H.264 SPS bytes (present whenever known).
    public let sps: Data?
    /// Current H.264 PPS bytes (present whenever known).
    public let pps: Data?

    public init(avccData: Data, pts90k: Int64, dts90k: Int64, isKeyframe: Bool, sps: Data?, pps: Data?) {
        self.avccData = avccData
        self.pts90k = pts90k
        self.dts90k = dts90k
        self.isKeyframe = isKeyframe
        self.sps = sps
        self.pps = pps
    }
}

public struct DemuxedAudioFrame: Sendable, Equatable {
    /// Raw AAC frame payload (ADTS header stripped).
    public let aacData: Data
    /// Continuous presentation timestamp in 90 kHz ticks.
    public let pts90k: Int64
    /// Sample rate in Hz (e.g. 48000).
    public let sampleRate: Int
    /// Channel count (e.g. 2).
    public let channels: Int
    /// MPEG-4 Audio Object Type (e.g. 2 = AAC-LC).
    public let audioObjectType: Int
    /// 2-byte MPEG-4 AudioSpecificConfig (`esds` / `kAudioFormatMPEG4AAC` magic cookie).
    public let audioSpecificConfig: Data

    public init(
        aacData: Data, pts90k: Int64, sampleRate: Int, channels: Int,
        audioObjectType: Int, audioSpecificConfig: Data
    ) {
        self.aacData = aacData
        self.pts90k = pts90k
        self.sampleRate = sampleRate
        self.channels = channels
        self.audioObjectType = audioObjectType
        self.audioSpecificConfig = audioSpecificConfig
    }
}

public enum DemuxedSample: Sendable, Equatable {
    case video(DemuxedVideoFrame)
    case audio(DemuxedAudioFrame)
}

public struct MPEGTSDemuxer: Sendable {
    public static let packetSize = 188
    public static let syncByte: UInt8 = 0x47
    public static let timescale: Int32 = 90_000

    private static let wrapPeriod: Int64 = 1 << 33
    private static let halfWrap: Int64 = 1 << 32
    /// Jumps larger than 30 s (in 90 kHz ticks) without a wrap indicate an unannounced discontinuity.
    private static let maxContinuousJump: Int64 = 30 * 90_000
    /// Gap inserted after a discontinuity rebase (~33 ms at 90 kHz).
    private static let discontinuityStep: Int64 = 3_000

    private static let sampleRates: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// Set when the PMT advertises a video codec this demuxer does not decode (e.g. HEVC `0x24`).
    public private(set) var unsupportedVideoCodec: String?
    public private(set) var pmtPID: UInt16?
    public private(set) var videoPID: UInt16?
    public private(set) var audioPID: UInt16?
    public private(set) var latestSPS: Data?
    public private(set) var latestPPS: Data?
    public private(set) var highestContinuousPTS: Int64 = 0

    private var buffer = Data()
    private var videoPES = Data()
    private var audioPES = Data()
    private var hasVideoPES = false
    private var hasAudioPES = false

    // Shared 90 kHz timeline state (keeps video and audio locked across wraps and discontinuities).
    private var wrapOffset: Int64 = 0
    private var lastUnwrappedPTS: Int64?
    private var timelineOffset: Int64 = 0
    private var hasTimeline = false
    private var needsRebase = false

    public init() {}

    /// Resets the entire demuxer (e.g. switching channel or quality variant).
    public mutating func reset() {
        self = MPEGTSDemuxer()
    }

    /// Signals an HLS `#EXT-X-DISCONTINUITY` (such as an ad splice or encoder restart):
    /// flushes pending PES packets and rebases the next incoming raw timestamps onto the continuous timeline.
    public mutating func beginDiscontinuity() -> [DemuxedSample] {
        let flushed = flushSegment()
        buffer.removeAll(keepingCapacity: true)
        lastUnwrappedPTS = nil
        wrapOffset = 0
        needsRebase = hasTimeline
        return flushed
    }

    /// Feeds raw MPEG-TS bytes (may be any chunk size) and returns any completed video/audio samples.
    public mutating func push(_ chunk: Data) -> [DemuxedSample] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var samples: [DemuxedSample] = []
        var offset = 0
        let total = buffer.count

        buffer.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while offset + Self.packetSize <= total {
                if ptr[offset] != Self.syncByte {
                    // Resync to the next valid 0x47 boundary.
                    var found = false
                    var scan = offset + 1
                    while scan + Self.packetSize <= total {
                        if ptr[scan] == Self.syncByte {
                            if scan + Self.packetSize < total {
                                if ptr[scan + Self.packetSize] == Self.syncByte {
                                    offset = scan
                                    found = true
                                    break
                                }
                            } else {
                                offset = scan
                                found = true
                                break
                            }
                        }
                        scan += 1
                    }
                    if !found {
                        offset = max(offset, total - Self.packetSize + 1)
                        break
                    }
                }

                parsePacket(ptr + offset, into: &samples)
                offset += Self.packetSize
            }
        }

        if offset > 0 {
            if offset >= total {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.removeSubrange(0..<offset)
            }
        }
        return samples
    }

    /// Flushes any remaining in-progress video and audio PES packets at the end of a segment.
    public mutating func flushSegment() -> [DemuxedSample] {
        var out: [DemuxedSample] = []
        if hasVideoPES, !videoPES.isEmpty {
            emitVideoPES(videoPES, into: &out)
        }
        videoPES.removeAll(keepingCapacity: true)
        hasVideoPES = false

        if hasAudioPES, !audioPES.isEmpty {
            emitAudioPES(audioPES, into: &out)
        }
        audioPES.removeAll(keepingCapacity: true)
        hasAudioPES = false
        return out
    }

    // MARK: - TS packet parsing

    private mutating func parsePacket(_ pkt: UnsafePointer<UInt8>, into out: inout [DemuxedSample]) {
        let b1 = pkt[1]
        // Transport Error Indicator: corrupt packet.
        if (b1 & 0x80) != 0 { return }
        let pusi = (b1 & 0x40) != 0
        let pid = (UInt16(b1 & 0x1F) << 8) | UInt16(pkt[2])
        let afc = (pkt[3] >> 4) & 0x03

        // Payload present only when afc == 1 or afc == 3.
        guard afc == 1 || afc == 3 else { return }
        var payloadOffset = 4
        if afc == 3 {
            let afLen = Int(pkt[4])
            payloadOffset = 5 + afLen
            guard payloadOffset < Self.packetSize else { return }
        }
        let payloadLen = Self.packetSize - payloadOffset
        let payloadPtr = pkt + payloadOffset

        if pid == 0x0000 {
            if pusi { parsePAT(payloadPtr, length: payloadLen) }
            return
        }
        if let pmtPID, pid == pmtPID {
            if pusi { parsePMT(payloadPtr, length: payloadLen) }
            return
        }
        if let videoPID, pid == videoPID {
            if pusi {
                if hasVideoPES, !videoPES.isEmpty {
                    emitVideoPES(videoPES, into: &out)
                }
                videoPES.removeAll(keepingCapacity: true)
                hasVideoPES = true
            }
            if hasVideoPES {
                videoPES.append(payloadPtr, count: payloadLen)
            }
            return
        }
        if let audioPID, pid == audioPID {
            if pusi {
                if hasAudioPES, !audioPES.isEmpty {
                    emitAudioPES(audioPES, into: &out)
                }
                audioPES.removeAll(keepingCapacity: true)
                hasAudioPES = true
            }
            if hasAudioPES {
                audioPES.append(payloadPtr, count: payloadLen)
            }
        }
    }

    private mutating func parsePAT(_ payload: UnsafePointer<UInt8>, length: Int) {
        guard length > 1 else { return }
        let pointer = Int(payload[0])
        let start = 1 + pointer
        guard start + 12 <= length else { return }
        let sec = payload + start
        let avail = length - start
        guard sec[0] == 0x00 else { return } // table_id == PAT
        let sectionLen = (Int(sec[1] & 0x0F) << 8) | Int(sec[2])
        let end = min(avail, 3 + sectionLen - 4) // exclude 4-byte CRC
        var pos = 8
        while pos + 4 <= end {
            let programNum = (UInt16(sec[pos]) << 8) | UInt16(sec[pos + 1])
            let pid = (UInt16(sec[pos + 2] & 0x1F) << 8) | UInt16(sec[pos + 3])
            if programNum != 0 {
                pmtPID = pid
                return
            }
            pos += 4
        }
    }

    private mutating func parsePMT(_ payload: UnsafePointer<UInt8>, length: Int) {
        guard length > 1 else { return }
        let pointer = Int(payload[0])
        let start = 1 + pointer
        guard start + 12 <= length else { return }
        let sec = payload + start
        let avail = length - start
        guard sec[0] == 0x02 else { return } // table_id == PMT
        let sectionLen = (Int(sec[1] & 0x0F) << 8) | Int(sec[2])
        let programInfoLen = (Int(sec[10] & 0x0F) << 8) | Int(sec[11])
        let end = min(avail, 3 + sectionLen - 4)
        var pos = 12 + programInfoLen

        var foundVideo: UInt16?
        var foundAudio: UInt16?
        var foundUnsupported: String?

        while pos + 5 <= end {
            let streamType = sec[pos]
            let elemPID = (UInt16(sec[pos + 1] & 0x1F) << 8) | UInt16(sec[pos + 2])
            let esInfoLen = (Int(sec[pos + 3] & 0x0F) << 8) | Int(sec[pos + 4])
            switch streamType {
            case 0x1B: // H.264 / AVC
                foundVideo = elemPID
            case 0x0F: // ADTS AAC
                foundAudio = elemPID
            case 0x24: // H.265 / HEVC
                if foundUnsupported == nil { foundUnsupported = "hevc" }
            default:
                break
            }
            pos += 5 + esInfoLen
        }

        if let foundVideo {
            videoPID = foundVideo
            unsupportedVideoCodec = nil
        } else if let foundUnsupported {
            unsupportedVideoCodec = foundUnsupported
        }
        if let foundAudio {
            audioPID = foundAudio
        }
    }

    // MARK: - PES parsing & timeline

    private struct PESHeader {
        let pts90k: Int64
        let dts90k: Int64
        let payloadOffset: Int
    }

    private mutating func parsePESHeader(_ pes: Data) -> PESHeader? {
        guard pes.count >= 9 else { return nil }
        return pes.withUnsafeBytes { raw -> PESHeader? in
            guard let b = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            guard b[0] == 0x00, b[1] == 0x00, b[2] == 0x01 else { return nil }
            let ptsDtsFlags = (b[7] >> 6) & 0x03
            let headerDataLen = Int(b[8])
            let payloadOffset = 9 + headerDataLen
            guard payloadOffset <= pes.count else { return nil }

            let rawPTS: Int64
            let rawDTS: Int64
            if ptsDtsFlags == 0x02, pes.count >= 14 {
                rawPTS = Self.readTimestamp33(b + 9)
                rawDTS = rawPTS
            } else if ptsDtsFlags == 0x03, pes.count >= 19 {
                rawPTS = Self.readTimestamp33(b + 9)
                rawDTS = Self.readTimestamp33(b + 14)
            } else {
                return nil
            }
            let (pts, dts) = mapTimestamps(rawPTS: rawPTS, rawDTS: rawDTS)
            return PESHeader(pts90k: pts, dts90k: dts, payloadOffset: payloadOffset)
        }
    }

    private static func readTimestamp33(_ p: UnsafePointer<UInt8>) -> Int64 {
        let b0 = Int64(p[0] & 0x0E) << 29
        let b1 = Int64(p[1]) << 22
        let b2 = Int64(p[2] & 0xFE) << 14
        let b3 = Int64(p[3]) << 7
        let b4 = Int64(p[4] >> 1)
        return b0 | b1 | b2 | b3 | b4
    }

    private mutating func mapTimestamps(rawPTS: Int64, rawDTS: Int64) -> (Int64, Int64) {
        // Compute signed (dts - pts) in 33-bit modular arithmetic so B-frame offsets survive wraparound.
        var dtsOffset = rawDTS - rawPTS
        if dtsOffset > Self.halfWrap { dtsOffset -= Self.wrapPeriod }
        if dtsOffset < -Self.halfWrap { dtsOffset += Self.wrapPeriod }

        if !hasTimeline {
            hasTimeline = true
            wrapOffset = 0
            lastUnwrappedPTS = rawPTS
            let base = rawPTS + dtsOffset // start decode timeline cleanly at 0
            timelineOffset = -base
            let cPTS = rawPTS + timelineOffset
            let cDTS = cPTS + dtsOffset
            highestContinuousPTS = max(highestContinuousPTS, cPTS)
            return (cPTS, cDTS)
        }

        if needsRebase {
            needsRebase = false
            wrapOffset = 0
            lastUnwrappedPTS = rawPTS
            let targetStart = highestContinuousPTS + Self.discontinuityStep
            timelineOffset = targetStart - (rawPTS + dtsOffset)
            let cPTS = rawPTS + timelineOffset
            let cDTS = cPTS + dtsOffset
            highestContinuousPTS = max(highestContinuousPTS, cPTS)
            return (cPTS, cDTS)
        }

        var unwrapped = rawPTS + wrapOffset
        if let prev = lastUnwrappedPTS {
            let diff = unwrapped - prev
            if diff < -Self.halfWrap {
                wrapOffset += Self.wrapPeriod
                unwrapped += Self.wrapPeriod
            } else if diff > Self.halfWrap {
                // Reordered frame straddling the 33-bit wrap boundary.
                unwrapped -= Self.wrapPeriod
            } else if abs(diff) > Self.maxContinuousJump {
                // Unannounced timeline jump (e.g. encoder reset without #EXT-X-DISCONTINUITY).
                let targetStart = highestContinuousPTS + Self.discontinuityStep
                timelineOffset = targetStart - (unwrapped + dtsOffset)
            }
        }
        lastUnwrappedPTS = unwrapped
        let cPTS = unwrapped + timelineOffset
        let cDTS = cPTS + dtsOffset
        highestContinuousPTS = max(highestContinuousPTS, cPTS)
        return (cPTS, cDTS)
    }

    // MARK: - H.264 Annex-B -> AVCC

    private mutating func emitVideoPES(_ pes: Data, into out: inout [DemuxedSample]) {
        guard let header = parsePESHeader(pes), header.payloadOffset < pes.count else { return }
        let es = pes.subdata(in: header.payloadOffset..<pes.count)

        var avcc = Data()
        avcc.reserveCapacity(es.count + 16)
        var isKeyframe = false

        Self.forEachAnnexBNALU(in: es) { naluBytes in
            guard !naluBytes.isEmpty else { return }
            let nalType = naluBytes[0] & 0x1F
            switch nalType {
            case 7: // SPS
                latestSPS = Data(naluBytes)
            case 8: // PPS
                latestPPS = Data(naluBytes)
            case 5: // IDR slice
                isKeyframe = true
                Self.appendAVCCNALU(naluBytes, to: &avcc)
            case 1, 2, 3, 4: // Non-IDR VCL slices
                Self.appendAVCCNALU(naluBytes, to: &avcc)
            default:
                // Skip AUD (9), SEI (6), filler (12), etc.
                break
            }
        }

        guard !avcc.isEmpty else { return }
        out.append(.video(DemuxedVideoFrame(
            avccData: avcc,
            pts90k: header.pts90k,
            dts90k: header.dts90k,
            isKeyframe: isKeyframe,
            sps: latestSPS,
            pps: latestPPS
        )))
    }

    /// Iterates Annex-B NALUs separated by `00 00 01` or `00 00 00 01` start codes and strips Annex-B trailing zero padding.
    static func forEachAnnexBNALU(in data: Data, body: (UnsafeBufferPointer<UInt8>) -> Void) {
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = data.count
            var i = 0
            var naluStart: Int?

            func emit(_ start: Int, _ rawEnd: Int) {
                var end = rawEnd
                while end > start && ptr[end - 1] == 0x00 { end -= 1 }
                guard end > start else { return }
                body(UnsafeBufferPointer(start: ptr + start, count: end - start))
            }

            while i + 2 < count {
                if ptr[i] == 0x00 && ptr[i + 1] == 0x00 {
                    if ptr[i + 2] == 0x01 {
                        if let s = naluStart { emit(s, i) }
                        i += 3
                        naluStart = i
                        continue
                    } else if i + 3 < count && ptr[i + 2] == 0x00 && ptr[i + 3] == 0x01 {
                        if let s = naluStart { emit(s, i) }
                        i += 4
                        naluStart = i
                        continue
                    }
                }
                i += 1
            }
            if let s = naluStart { emit(s, count) }
        }
    }

    private static func appendAVCCNALU(_ nalu: UnsafeBufferPointer<UInt8>, to out: inout Data) {
        var len = UInt32(nalu.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        if let base = nalu.baseAddress {
            out.append(base, count: nalu.count)
        }
    }

    // MARK: - ADTS AAC

    private mutating func emitAudioPES(_ pes: Data, into out: inout [DemuxedSample]) {
        guard let header = parsePESHeader(pes), header.payloadOffset < pes.count else { return }
        let es = pes.subdata(in: header.payloadOffset..<pes.count)

        es.withUnsafeBytes { raw in
            guard let b = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = es.count
            var pos = 0
            var frameIndex: Int64 = 0

            while pos + 7 <= count {
                // Scan for 12-bit ADTS syncword 0xFFF.
                if b[pos] != 0xFF || (b[pos + 1] & 0xF0) != 0xF0 {
                    pos += 1
                    continue
                }
                let protectionAbsent = (b[pos + 1] & 0x01) != 0
                let headerSize = protectionAbsent ? 7 : 9
                let frameLength = (Int(b[pos + 3] & 0x03) << 11)
                    | (Int(b[pos + 4]) << 3)
                    | (Int(b[pos + 5]) >> 5)
                guard frameLength >= headerSize, pos + frameLength <= count else { break }

                let audioObjectType = Int((b[pos + 2] >> 6) & 0x03) + 1
                let srIdx = Int((b[pos + 2] >> 2) & 0x0F)
                let channels = Int(((b[pos + 2] & 0x01) << 2) | (b[pos + 3] >> 6))

                if srIdx < Self.sampleRates.count, channels > 0 {
                    let sampleRate = Self.sampleRates[srIdx]
                    let asc = Data([
                        UInt8((audioObjectType << 3) | (srIdx >> 1)),
                        UInt8(((srIdx & 0x01) << 7) | (channels << 3)),
                    ])
                    let payloadLen = frameLength - headerSize
                    let aac = Data(bytes: b + pos + headerSize, count: payloadLen)
                    let ticksPerFrame = Int64((1024.0 * 90_000.0 / Double(sampleRate)).rounded())
                    let pts = header.pts90k + frameIndex * ticksPerFrame
                    out.append(.audio(DemuxedAudioFrame(
                        aacData: aac,
                        pts90k: pts,
                        sampleRate: sampleRate,
                        channels: channels,
                        audioObjectType: audioObjectType,
                        audioSpecificConfig: asc
                    )))
                    frameIndex += 1
                }
                pos += frameLength
            }
        }
    }
}
