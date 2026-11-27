import Foundation

// Pure-Swift incremental CMAF / fragmented MP4 (ISO BMFF) demuxer for Twitch low-latency HLS segments.
//
// Designed for chunked HTTP streaming (`#EXT-X-TWITCH-PREFETCH` + `#EXT-X-MAP`):
// - Load the `#EXT-X-MAP` initialization segment (`ftyp` + `moov`) once via `loadInitSegment(_:)` (or inline in `push(_:)`)
// - Feed incoming chunked `.mp4` bytes via `push(_:)` in arbitrary chunk sizes (including mid-box splits)
// - Emits `[DemuxedSample]` (the exact same `DemuxedVideoFrame` / `DemuxedAudioFrame` types on a continuous 90 kHz timeline)
//   immediately as each `moof` + `mdat` CMAF chunk finishes (~100–200 ms glass-to-glass latency)
//
// Handles:
// - `ftyp` + `moov` (`tkhd`, `mdhd`, `hdlr`, `stsd` [`avc1`/`avc3` -> `avcC`, `mp4a` -> `esds`, unsupported `hvc1`/`hev1`/`av01`/`vp09`], `mvex`/`trex`)
// - `moof` (`mfhd`, multiple `traf`s, `tfhd`, `tfdt` v0/v1, multiple `trun`s with v0 unsigned & v1 signed composition offsets) + `mdat`
// - `emsg`, `styp`, `sidx`, `free`, `skip`, `prft`, `udta`, and 64-bit `largesize` boxes
// - Audio-only CMAF variants (`soun`-only `moov` and single-`traf` `moof`)
// - Keyframe detection via both explicit `sample_flags` (`sample_depends_on == 2 && is_non_sync == 0`) and AVCC IDR NALU scan (type 5)
// - Non-4-byte `nalLengthSize` -> 4-byte AVCC conversion and inline SPS/PPS extraction (`avc3` or inline parameter sets)
// - Overflow-free exact rescaling of arbitrary track timescales (e.g. 48 kHz audio + 1 MHz video) onto a shared 90 kHz timeline
// - Seamless timeline rebasing across `#EXT-X-DISCONTINUITY` and MPEG-TS <-> fMP4 container switches (`rebaseTimeline(after:)`)

public struct FMP4Demuxer: Sendable {
    public static let timescale: Int32 = 90_000

    /// Jumps larger than 30 s (in 90 kHz ticks) without an explicit discontinuity trigger automatic rebasing.
    private static let maxContinuousJump: Int64 = 30 * 90_000
    /// Gap inserted after a discontinuity rebase (~33 ms at 90 kHz, matching `MPEGTSDemuxer`).
    private static let discontinuityStep: Int64 = 3_000
    /// Safety cap on a single top-level box to prevent runaway buffering on corrupt input (64 MB).
    private static let maxBoxSize: UInt64 = 64 * 1024 * 1024

    private static let sampleRates: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    // FourCC constants (big-endian UInt32).
    private static let boxFtyp: UInt32 = 0x6674_7970 // "ftyp"
    private static let boxStyp: UInt32 = 0x7374_7970 // "styp"
    private static let boxMoov: UInt32 = 0x6D6F_6F76 // "moov"
    private static let boxTrak: UInt32 = 0x7472_616B // "trak"
    private static let boxTkhd: UInt32 = 0x746B_6864 // "tkhd"
    private static let boxMdia: UInt32 = 0x6D64_6961 // "mdia"
    private static let boxMdhd: UInt32 = 0x6D64_6864 // "mdhd"
    private static let boxHdlr: UInt32 = 0x6864_6C72 // "hdlr"
    private static let boxMinf: UInt32 = 0x6D69_6E66 // "minf"
    private static let boxStbl: UInt32 = 0x7374_626C // "stbl"
    private static let boxStsd: UInt32 = 0x7374_7364 // "stsd"
    private static let boxMvex: UInt32 = 0x6D76_6578 // "mvex"
    private static let boxTrex: UInt32 = 0x7472_6578 // "trex"
    private static let boxMoof: UInt32 = 0x6D6F_6F66 // "moof"
    private static let boxTraf: UInt32 = 0x7472_6166 // "traf"
    private static let boxTfhd: UInt32 = 0x7466_6864 // "tfhd"
    private static let boxTfdt: UInt32 = 0x7466_6474 // "tfdt"
    private static let boxTrun: UInt32 = 0x7472_756E // "trun"
    private static let boxMdat: UInt32 = 0x6D64_6174 // "mdat"
    private static let boxEmsg: UInt32 = 0x656D_7367 // "emsg"
    private static let boxSidx: UInt32 = 0x7369_6478 // "sidx"
    private static let boxFree: UInt32 = 0x6672_6565 // "free"
    private static let boxPrft: UInt32 = 0x7072_6674 // "prft"
    private static let boxAvc1: UInt32 = 0x6176_6331 // "avc1"
    private static let boxAvc3: UInt32 = 0x6176_6333 // "avc3"
    private static let boxAvcC: UInt32 = 0x6176_6343 // "avcC"
    private static let boxHvc1: UInt32 = 0x6876_6331 // "hvc1"
    private static let boxHev1: UInt32 = 0x6865_7631 // "hev1"
    private static let boxHvcC: UInt32 = 0x6876_6343 // "hvcC"
    private static let boxAv01: UInt32 = 0x6176_3031 // "av01"
    private static let boxVp09: UInt32 = 0x7670_3039 // "vp09"
    private static let boxMp4a: UInt32 = 0x6D70_3461 // "mp4a"
    private static let boxEsds: UInt32 = 0x6573_6473 // "esds"
    private static let boxWave: UInt32 = 0x7761_7665 // "wave"
    private static let handlerVide: UInt32 = 0x7669_6465 // "vide"
    private static let handlerSoun: UInt32 = 0x736F_756E // "soun"

    // MARK: - Track models

    public struct AudioConfig: Sendable, Equatable {
        public let sampleRate: Int
        public let channels: Int
        public let audioObjectType: Int
        public let audioSpecificConfig: Data

        public init(sampleRate: Int, channels: Int, audioObjectType: Int, audioSpecificConfig: Data) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.audioObjectType = audioObjectType
            self.audioSpecificConfig = audioSpecificConfig
        }
    }

    private struct TrexDefaults: Sendable {
        let defaultSampleDescriptionIndex: UInt32
        let defaultSampleDuration: UInt32
        let defaultSampleSize: UInt32
        let defaultSampleFlags: UInt32
    }

    private enum TrackKind: Sendable {
        case video(nalLengthSize: Int)
        case audio(AudioConfig)
    }

    private struct TrackInfo: Sendable {
        let trackID: UInt32
        let timescale: UInt32
        var kind: TrackKind
    }

    private struct ParsedTFHD: Sendable {
        let trackID: UInt32
        let baseDataOffset: UInt64?
        let sampleDescriptionIndex: UInt32?
        let defaultSampleDuration: UInt32?
        let defaultSampleSize: UInt32?
        let defaultSampleFlags: UInt32?
        let durationIsEmpty: Bool
        let defaultBaseIsMoof: Bool
    }

    private struct ParsedTrunSample: Sendable {
        let duration: UInt32?
        let size: UInt32?
        let flags: UInt32?
        let compositionTimeOffset: Int64
    }

    private struct ParsedTrun: Sendable {
        let dataOffset: Int32?
        let firstSampleFlags: UInt32?
        let samples: [ParsedTrunSample]
    }

    private struct ParsedTraf: Sendable {
        let tfhd: ParsedTFHD
        let baseMediaDecodeTime: Int64?
        let truns: [ParsedTrun]
    }

    private struct PendingMoof: Sendable {
        let moofOffset: Int64
        let trafs: [ParsedTraf]
    }

    private struct PendingRawSample {
        enum Payload {
            case video(avcc: Data, isKeyframe: Bool, sps: Data?, pps: Data?)
            case audio(aac: Data, config: AudioConfig)
        }
        let rawPTS90k: Int64
        let rawDTS90k: Int64
        let payload: Payload
    }

    // MARK: - Public read-only state

    /// Set when the init segment advertises a video codec this demuxer does not decode (e.g. `"hevc"`, `"av1"`).
    public private(set) var unsupportedVideoCodec: String?
    public private(set) var videoTrackID: UInt32?
    public private(set) var audioTrackID: UInt32?
    public private(set) var videoTimescale: UInt32?
    public private(set) var audioTimescale: UInt32?
    public private(set) var nalLengthSize: Int = 4
    public private(set) var latestSPS: Data?
    public private(set) var latestPPS: Data?
    public private(set) var audioConfig: AudioConfig?
    public private(set) var highestContinuousPTS: Int64 = 0

    /// True once a valid `moov` initialization segment with at least one playable video or audio track has been parsed.
    public var hasInitConfig: Bool {
        videoTrackID != nil || audioTrackID != nil
    }

    // MARK: - Internal state

    private var tracks: [UInt32: TrackInfo] = [:]
    private var trexByTrack: [UInt32: TrexDefaults] = [:]
    private var lastDecodeTimeByTrack: [UInt32: Int64] = [:]

    private var buffer = Data()
    private var segmentByteOffset: Int64 = 0
    private var pendingMoof: PendingMoof?

    // Shared 90 kHz timeline state (keeps video and audio locked across chunks, segments, and discontinuities).
    private var hasTimeline = false
    private var timelineOffset: Int64 = 0
    private var lastRawAnchor90k: Int64?
    private var needsRebase = false

    public init() {}

    /// Resets the entire demuxer (e.g. switching channel or quality variant).
    public mutating func reset() {
        self = FMP4Demuxer()
    }

    /// Sniffs the leading bytes of a segment to detect an ISO BMFF / CMAF box header (`ftyp`, `styp`, `moov`, `moof`, `emsg`, `sidx`, `prft`, `free`, `mdat`).
    public static func isLikelyFMP4(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let size32 = readUInt32BE(ptr, at: 0)
            guard size32 == 0 || size32 == 1 || (size32 >= 8 && UInt64(size32) <= maxBoxSize) else { return false }
            let fourCC = readUInt32BE(ptr, at: 4)
            switch fourCC {
            case boxFtyp, boxStyp, boxMoov, boxMoof, boxEmsg, boxSidx, boxPrft, boxFree, boxMdat:
                return true
            default:
                return false
            }
        }
    }

    /// Parses an `#EXT-X-MAP` initialization segment (`ftyp` + `moov`) without disturbing active timeline state.
    /// Returns `true` when at least one decodable video or audio track was configured.
    @discardableResult
    public mutating func loadInitSegment(_ data: Data) -> Bool {
        guard !data.isEmpty else { return hasInitConfig }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var pos = 0
            let total = data.count
            while pos + 8 <= total {
                guard let box = readBoxHeader(base, offset: pos, limit: total) else { break }
                if box.type == Self.boxMoov {
                    parseMoov(base, payloadStart: box.payloadStart, end: box.end)
                }
                pos = box.end
            }
        }
        return hasInitConfig
    }

    /// Signals an HLS `#EXT-X-DISCONTINUITY` (such as an ad splice or encoder restart):
    /// flushes any buffered segment state and rebases the next incoming fragment timestamps onto the continuous timeline.
    public mutating func beginDiscontinuity() -> [DemuxedSample] {
        let flushed = flushSegment()
        lastDecodeTimeByTrack.removeAll(keepingCapacity: true)
        lastRawAnchor90k = nil
        needsRebase = hasTimeline
        return flushed
    }

    /// Seeds the continuous 90 kHz timeline from another demuxer (e.g. MPEG-TS -> CMAF/fMP4 across `#EXT-X-DISCONTINUITY`)
    /// so the next incoming fragment rebases smoothly ahead of `previousHighestPTS`.
    public mutating func rebaseTimeline(after previousHighestPTS: Int64) {
        hasTimeline = true
        highestContinuousPTS = max(highestContinuousPTS, previousHighestPTS)
        lastDecodeTimeByTrack.removeAll(keepingCapacity: true)
        lastRawAnchor90k = nil
        needsRebase = true
    }

    /// Feeds raw CMAF/fMP4 bytes (any chunk size, including mid-box splits) and returns any samples from completed `moof`+`mdat` chunks.
    public mutating func push(_ chunk: Data) -> [DemuxedSample] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        return drainBuffer(eof: false)
    }

    /// Finalizes the current segment (handling any size-0 box-to-EOF) and resets per-segment byte offsets while preserving `moov` config and timeline.
    public mutating func flushSegment() -> [DemuxedSample] {
        let samples = drainBuffer(eof: true)
        buffer.removeAll(keepingCapacity: true)
        segmentByteOffset = 0
        pendingMoof = nil
        return samples
    }

    /// Overflow-free exact conversion from an arbitrary MP4 track timescale to 90 kHz ticks (rounded to nearest tick).
    public static func rescaleTo90k(_ value: Int64, timescale: UInt32) -> Int64 {
        guard timescale > 0 else { return value }
        let ts = Int64(timescale)
        if ts == 90_000 { return value }
        let negative = value < 0
        let absVal: UInt64
        if value == Int64.min {
            absVal = UInt64(Int64.max) + 1
        } else {
            absVal = UInt64(negative ? -value : value)
        }
        let tsU = UInt64(ts)
        let whole = absVal / tsU
        let rem = absVal % tsU
        let scaledRem = (rem * 90_000 + tsU / 2) / tsU
        let total = whole &* 90_000 &+ scaledRem
        let clamped = Int64(min(total, UInt64(Int64.max)))
        return negative ? -clamped : clamped
    }

    // MARK: - Incremental top-level box draining

    private mutating func drainBuffer(eof: Bool) -> [DemuxedSample] {
        var samples: [DemuxedSample] = []
        var consumed = 0
        let total = buffer.count

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var pos = 0
            while pos + 8 <= total {
                let size32 = Self.readUInt32BE(base, at: pos)
                let boxType = Self.readUInt32BE(base, at: pos + 4)
                let headerSize: Int
                let boxSize: UInt64

                if size32 == 1 {
                    guard pos + 16 <= total else { break }
                    boxSize = Self.readUInt64BE(base, at: pos + 8)
                    headerSize = 16
                    if boxSize < 16 || boxSize > Self.maxBoxSize {
                        // Corrupt box size: drop buffer to prevent stalling.
                        consumed = total
                        return
                    }
                } else if size32 == 0 {
                    // Size 0 means box extends to end of segment; wait until `flushSegment()`.
                    guard eof else { break }
                    boxSize = UInt64(total - pos)
                    headerSize = 8
                } else if size32 < 8 {
                    consumed = total
                    return
                } else {
                    boxSize = UInt64(size32)
                    headerSize = 8
                    if boxSize > Self.maxBoxSize {
                        consumed = total
                        return
                    }
                }

                let avail = UInt64(total - pos)
                guard avail >= boxSize else { break }

                let intSize = Int(boxSize)
                let boxStartOffset = segmentByteOffset + Int64(pos)
                let payloadStart = pos + headerSize
                let boxEnd = pos + intSize

                switch boxType {
                case Self.boxMoov:
                    parseMoov(base, payloadStart: payloadStart, end: boxEnd)
                case Self.boxMoof:
                    pendingMoof = parseMoof(base, payloadStart: payloadStart, end: boxEnd, moofOffset: boxStartOffset)
                case Self.boxMdat:
                    if let moof = pendingMoof {
                        let mdatPayloadOffset = boxStartOffset + Int64(headerSize)
                        extractSamples(
                            from: moof,
                            mdatBase: base + payloadStart,
                            mdatLength: boxEnd - payloadStart,
                            mdatPayloadOffset: mdatPayloadOffset,
                            into: &samples
                        )
                        pendingMoof = nil
                    }
                default:
                    // `ftyp`, `styp`, `emsg`, `sidx`, `free`, `skip`, `prft`, `udta`, `meta`, etc.
                    break
                }

                pos = boxEnd
                consumed = pos
            }
        }

        if consumed > 0 {
            segmentByteOffset += Int64(consumed)
            if consumed >= total {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.removeSubrange(0..<consumed)
            }
        }
        return samples
    }

    // MARK: - Init segment (`moov`) parsing

    private mutating func parseMoov(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) {
        var newTracks: [UInt32: TrackInfo] = [:]
        var newTrex: [UInt32: TrexDefaults] = [:]
        var foundVideoTrackID: UInt32?
        var foundAudioTrackID: UInt32?
        var foundVideoTimescale: UInt32?
        var foundAudioTimescale: UInt32?
        var foundNalLenSize = 4
        var foundSPS: Data?
        var foundPPS: Data?
        var foundAudioConfig: AudioConfig?
        var foundUnsupported: String?

        var pos = payloadStart
        while pos + 8 <= end {
            guard let box = readBoxHeader(base, offset: pos, limit: end) else { break }
            switch box.type {
            case Self.boxTrak:
                let parsed = parseTrak(base, payloadStart: box.payloadStart, end: box.end)
                if let track = parsed.track {
                    newTracks[track.trackID] = track
                    switch track.kind {
                    case .video(let nalLen):
                        foundVideoTrackID = track.trackID
                        foundVideoTimescale = track.timescale
                        foundNalLenSize = nalLen
                        if let sps = parsed.sps { foundSPS = sps }
                        if let pps = parsed.pps { foundPPS = pps }
                    case .audio(let cfg):
                        foundAudioTrackID = track.trackID
                        foundAudioTimescale = track.timescale
                        foundAudioConfig = cfg
                    }
                } else if let unsupported = parsed.unsupportedCodec, foundUnsupported == nil {
                    foundUnsupported = unsupported
                }
            case Self.boxMvex:
                parseMvex(base, payloadStart: box.payloadStart, end: box.end, into: &newTrex)
            default:
                break
            }
            pos = box.end
        }

        // Only replace active track tables when the `moov` actually described at least one track (or unsupported video).
        if !newTracks.isEmpty || foundUnsupported != nil {
            tracks = newTracks
            trexByTrack = newTrex
            videoTrackID = foundVideoTrackID
            audioTrackID = foundAudioTrackID
            videoTimescale = foundVideoTimescale
            audioTimescale = foundAudioTimescale
            nalLengthSize = foundNalLenSize
            if let foundSPS { latestSPS = foundSPS }
            if let foundPPS { latestPPS = foundPPS }
            audioConfig = foundAudioConfig
            if foundVideoTrackID != nil {
                unsupportedVideoCodec = nil
            } else {
                unsupportedVideoCodec = foundUnsupported
            }
        }
    }

    private struct ParsedTrakResult {
        var track: TrackInfo?
        var sps: Data?
        var pps: Data?
        var unsupportedCodec: String?
    }

    private func parseTrak(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> ParsedTrakResult {
        var trackID: UInt32?
        var timescale: UInt32 = 90_000
        var handlerType: UInt32 = 0
        var stsdRange: (Int, Int)?

        var pos = payloadStart
        while pos + 8 <= end {
            guard let box = readBoxHeader(base, offset: pos, limit: end) else { break }
            switch box.type {
            case Self.boxTkhd:
                trackID = parseTkhd(base, payloadStart: box.payloadStart, end: box.end)
            case Self.boxMdia:
                var mPos = box.payloadStart
                while mPos + 8 <= box.end {
                    guard let mBox = readBoxHeader(base, offset: mPos, limit: box.end) else { break }
                    switch mBox.type {
                    case Self.boxMdhd:
                        if let ts = parseMdhd(base, payloadStart: mBox.payloadStart, end: mBox.end) {
                            timescale = ts
                        }
                    case Self.boxHdlr:
                        if mBox.payloadStart + 12 <= mBox.end {
                            handlerType = Self.readUInt32BE(base, at: mBox.payloadStart + 8)
                        }
                    case Self.boxMinf:
                        var minfPos = mBox.payloadStart
                        while minfPos + 8 <= mBox.end {
                            guard let minfBox = readBoxHeader(base, offset: minfPos, limit: mBox.end) else { break }
                            if minfBox.type == Self.boxStbl {
                                var stblPos = minfBox.payloadStart
                                while stblPos + 8 <= minfBox.end {
                                    guard let stblBox = readBoxHeader(base, offset: stblPos, limit: minfBox.end) else { break }
                                    if stblBox.type == Self.boxStsd {
                                        stsdRange = (stblBox.payloadStart, stblBox.end)
                                    }
                                    stblPos = stblBox.end
                                }
                            }
                            minfPos = minfBox.end
                        }
                    default:
                        break
                    }
                    mPos = mBox.end
                }
            default:
                break
            }
            pos = box.end
        }

        guard let trackID, let (stsdStart, stsdEnd) = stsdRange else {
            return ParsedTrakResult()
        }

        if handlerType == Self.handlerVide {
            return parseVideoStsd(base, payloadStart: stsdStart, end: stsdEnd, trackID: trackID, timescale: timescale)
        } else if handlerType == Self.handlerSoun {
            return parseAudioStsd(base, payloadStart: stsdStart, end: stsdEnd, trackID: trackID, timescale: timescale)
        }
        return ParsedTrakResult()
    }

    private func parseTkhd(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> UInt32? {
        guard payloadStart + 4 <= end else { return nil }
        let version = base[payloadStart]
        if version == 1 {
            guard payloadStart + 24 <= end else { return nil }
            return Self.readUInt32BE(base, at: payloadStart + 20)
        } else {
            guard payloadStart + 16 <= end else { return nil }
            return Self.readUInt32BE(base, at: payloadStart + 12)
        }
    }

    private func parseMdhd(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> UInt32? {
        guard payloadStart + 4 <= end else { return nil }
        let version = base[payloadStart]
        if version == 1 {
            guard payloadStart + 24 <= end else { return nil }
            return Self.readUInt32BE(base, at: payloadStart + 20)
        } else {
            guard payloadStart + 16 <= end else { return nil }
            return Self.readUInt32BE(base, at: payloadStart + 12)
        }
    }

    private func parseVideoStsd(
        _ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int, trackID: UInt32, timescale: UInt32
    ) -> ParsedTrakResult {
        // FullBox (4) + entry_count (4)
        guard payloadStart + 8 <= end else { return ParsedTrakResult() }
        var pos = payloadStart + 8
        var unsupported: String?

        while pos + 8 <= end {
            guard let entry = readBoxHeader(base, offset: pos, limit: end) else { break }
            switch entry.type {
            case Self.boxAvc1, Self.boxAvc3:
                // VisualSampleEntry has 78 bytes of fixed fields before child boxes.
                let childrenStart = entry.payloadStart + 78
                var nalLen = 4
                var sps: Data?
                var pps: Data?
                if childrenStart <= entry.end {
                    var cPos = childrenStart
                    while cPos + 8 <= entry.end {
                        guard let child = readBoxHeader(base, offset: cPos, limit: entry.end) else { break }
                        if child.type == Self.boxAvcC {
                            let avcc = parseAvcC(base, payloadStart: child.payloadStart, end: child.end)
                            nalLen = avcc.nalLengthSize
                            sps = avcc.sps
                            pps = avcc.pps
                        }
                        cPos = child.end
                    }
                }
                return ParsedTrakResult(
                    track: TrackInfo(trackID: trackID, timescale: timescale, kind: .video(nalLengthSize: nalLen)),
                    sps: sps,
                    pps: pps,
                    unsupportedCodec: nil
                )
            case Self.boxHvc1, Self.boxHev1:
                // Verify hvcC if present, then report HEVC as unsupported by the H.264 native decoder.
                let childrenStart = entry.payloadStart + 78
                if childrenStart <= entry.end {
                    var cPos = childrenStart
                    while cPos + 8 <= entry.end {
                        guard let child = readBoxHeader(base, offset: cPos, limit: entry.end) else { break }
                        if child.type == Self.boxHvcC { break }
                        cPos = child.end
                    }
                }
                if unsupported == nil { unsupported = "hevc" }
            case Self.boxAv01:
                if unsupported == nil { unsupported = "av1" }
            case Self.boxVp09:
                if unsupported == nil { unsupported = "vp9" }
            default:
                break
            }
            pos = entry.end
        }
        return ParsedTrakResult(track: nil, sps: nil, pps: nil, unsupportedCodec: unsupported)
    }

    private func parseAvcC(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> (nalLengthSize: Int, sps: Data?, pps: Data?) {
        guard payloadStart + 6 <= end else { return (4, nil, nil) }
        let nalLen = Int(base[payloadStart + 4] & 0x03) + 1
        let numSPS = Int(base[payloadStart + 5] & 0x1F)
        var pos = payloadStart + 6
        var firstSPS: Data?
        for _ in 0..<numSPS {
            guard pos + 2 <= end else { return (nalLen, firstSPS, nil) }
            let len = Int(Self.readUInt16BE(base, at: pos))
            pos += 2
            guard pos + len <= end else { return (nalLen, firstSPS, nil) }
            if firstSPS == nil && len > 0 {
                firstSPS = Data(bytes: base + pos, count: len)
            }
            pos += len
        }
        guard pos < end else { return (nalLen, firstSPS, nil) }
        let numPPS = Int(base[pos])
        pos += 1
        var firstPPS: Data?
        for _ in 0..<numPPS {
            guard pos + 2 <= end else { break }
            let len = Int(Self.readUInt16BE(base, at: pos))
            pos += 2
            guard pos + len <= end else { break }
            if firstPPS == nil && len > 0 {
                firstPPS = Data(bytes: base + pos, count: len)
            }
            pos += len
        }
        return (nalLen, firstSPS, firstPPS)
    }

    private func parseAudioStsd(
        _ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int, trackID: UInt32, timescale: UInt32
    ) -> ParsedTrakResult {
        guard payloadStart + 8 <= end else { return ParsedTrakResult() }
        var pos = payloadStart + 8

        while pos + 8 <= end {
            guard let entry = readBoxHeader(base, offset: pos, limit: end) else { break }
            if entry.type == Self.boxMp4a {
                guard entry.payloadStart + 28 <= entry.end else {
                    pos = entry.end
                    continue
                }
                let qtVersion = Self.readUInt16BE(base, at: entry.payloadStart + 8)
                let fallbackChannels = Int(Self.readUInt16BE(base, at: entry.payloadStart + 16))
                let fallbackSRFixed = Self.readUInt32BE(base, at: entry.payloadStart + 24)
                let fallbackSR = Int(fallbackSRFixed >> 16)

                var childrenStart = entry.payloadStart + 28
                if qtVersion == 1 { childrenStart += 16 }
                else if qtVersion == 2 { childrenStart += 36 }

                var parsedConfig: AudioConfig?
                if childrenStart <= entry.end {
                    parsedConfig = findEsdsAudioConfig(
                        base, start: childrenStart, end: entry.end,
                        fallbackSampleRate: fallbackSR > 0 ? fallbackSR : Int(timescale),
                        fallbackChannels: fallbackChannels > 0 ? fallbackChannels : 2
                    )
                }

                let config: AudioConfig
                if let parsedConfig {
                    config = parsedConfig
                } else {
                    let sr = fallbackSR > 0 ? fallbackSR : (timescale > 0 ? Int(timescale) : 48_000)
                    let ch = fallbackChannels > 0 ? fallbackChannels : 2
                    let asc = Self.synthesizeAudioSpecificConfig(audioObjectType: 2, sampleRate: sr, channels: ch)
                    config = AudioConfig(sampleRate: sr, channels: ch, audioObjectType: 2, audioSpecificConfig: asc)
                }

                return ParsedTrakResult(
                    track: TrackInfo(trackID: trackID, timescale: timescale, kind: .audio(config)),
                    sps: nil,
                    pps: nil,
                    unsupportedCodec: nil
                )
            }
            pos = entry.end
        }
        return ParsedTrakResult()
    }

    private func findEsdsAudioConfig(
        _ base: UnsafePointer<UInt8>, start: Int, end: Int, fallbackSampleRate: Int, fallbackChannels: Int
    ) -> AudioConfig? {
        var pos = start
        while pos + 8 <= end {
            guard let box = readBoxHeader(base, offset: pos, limit: end) else { break }
            if box.type == Self.boxEsds {
                if let asc = parseEsds(base, payloadStart: box.payloadStart, end: box.end) {
                    return parseAudioSpecificConfig(
                        asc,
                        fallbackSampleRate: fallbackSampleRate,
                        fallbackChannels: fallbackChannels
                    )
                }
            } else if box.type == Self.boxWave {
                if let nested = findEsdsAudioConfig(
                    base, start: box.payloadStart, end: box.end,
                    fallbackSampleRate: fallbackSampleRate, fallbackChannels: fallbackChannels
                ) {
                    return nested
                }
            }
            pos = box.end
        }
        return nil
    }

    /// Parses an `esds` FullBox (ISO/IEC 14496-1) to extract the raw `AudioSpecificConfig` inside `DecSpecificInfoTag (0x05)`.
    private func parseEsds(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> Data? {
        // Skip FullBox version (1) + flags (3).
        let start = payloadStart + 4
        guard start < end else { return nil }
        return extractASCFromDescriptors(base, start: start, end: end)
    }

    private func extractASCFromDescriptors(_ base: UnsafePointer<UInt8>, start: Int, end: Int) -> Data? {
        var pos = start
        while pos < end {
            let tag = base[pos]
            pos += 1
            // MPEG-4 expandable descriptor size (1 to 4 bytes, MSB continuation flag).
            var descSize = 0
            var bytesRead = 0
            while pos < end && bytesRead < 4 {
                let b = base[pos]
                pos += 1
                bytesRead += 1
                descSize = (descSize << 7) | Int(b & 0x7F)
                if (b & 0x80) == 0 { break }
            }
            guard bytesRead > 0, descSize >= 0 else { return nil }
            let descEnd = min(end, pos + descSize)

            switch tag {
            case 0x03: // ES_DescrTag
                guard pos + 3 <= descEnd else { return nil }
                let flags = base[pos + 2]
                var inner = pos + 3
                if (flags & 0x80) != 0 { inner += 2 } // streamDependenceFlag
                if (flags & 0x40) != 0 {              // URL_Flag
                    guard inner < descEnd else { return nil }
                    let urlLen = Int(base[inner])
                    inner += 1 + urlLen
                }
                if (flags & 0x20) != 0 { inner += 2 } // OCRstreamFlag
                if inner < descEnd, let asc = extractASCFromDescriptors(base, start: inner, end: descEnd) {
                    return asc
                }
            case 0x04: // DecoderConfigDescrTag
                let inner = pos + 13
                if inner < descEnd, let asc = extractASCFromDescriptors(base, start: inner, end: descEnd) {
                    return asc
                }
            case 0x05: // DecSpecificInfoTag -> raw AudioSpecificConfig
                let len = descEnd - pos
                guard len >= 2 else { return nil }
                return Data(bytes: base + pos, count: len)
            default:
                break
            }
            pos = descEnd
        }
        return nil
    }

    private func parseAudioSpecificConfig(
        _ asc: Data, fallbackSampleRate: Int, fallbackChannels: Int
    ) -> AudioConfig {
        var bits = BitReader(asc)
        var aot = Int(bits.read(5) ?? 2)
        if aot == 31, let ext = bits.read(6) {
            aot = 32 + Int(ext)
        }
        let srIdx = Int(bits.read(4) ?? 3)
        let sampleRate: Int
        if srIdx == 15, let explicitSR = bits.read(24), explicitSR > 0 {
            sampleRate = Int(explicitSR)
        } else if srIdx < Self.sampleRates.count {
            sampleRate = Self.sampleRates[srIdx]
        } else {
            sampleRate = fallbackSampleRate > 0 ? fallbackSampleRate : 48_000
        }
        let chanCfg = Int(bits.read(4) ?? 0)
        let channels: Int
        switch chanCfg {
        case 1...6: channels = chanCfg
        case 7: channels = 8
        default: channels = fallbackChannels > 0 ? fallbackChannels : 2
        }
        return AudioConfig(
            sampleRate: sampleRate,
            channels: channels,
            audioObjectType: aot > 0 ? aot : 2,
            audioSpecificConfig: asc
        )
    }

    private static func synthesizeAudioSpecificConfig(audioObjectType: Int, sampleRate: Int, channels: Int) -> Data {
        let srIdx = sampleRates.firstIndex(of: sampleRate) ?? 3 // default 48 kHz
        let aot = max(1, min(31, audioObjectType))
        let ch = max(1, min(7, channels))
        return Data([
            UInt8((aot << 3) | (srIdx >> 1)),
            UInt8(((srIdx & 0x01) << 7) | (ch << 3)),
        ])
    }

    private func parseMvex(
        _ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int, into trex: inout [UInt32: TrexDefaults]
    ) {
        var pos = payloadStart
        while pos + 8 <= end {
            guard let box = readBoxHeader(base, offset: pos, limit: end) else { break }
            if box.type == Self.boxTrex, box.payloadStart + 24 <= box.end {
                let p = box.payloadStart
                let tid = Self.readUInt32BE(base, at: p + 4)
                let sdi = Self.readUInt32BE(base, at: p + 8)
                let dur = Self.readUInt32BE(base, at: p + 12)
                let sz = Self.readUInt32BE(base, at: p + 16)
                let fl = Self.readUInt32BE(base, at: p + 20)
                trex[tid] = TrexDefaults(
                    defaultSampleDescriptionIndex: sdi,
                    defaultSampleDuration: dur,
                    defaultSampleSize: sz,
                    defaultSampleFlags: fl
                )
            }
            pos = box.end
        }
    }

    // MARK: - Movie fragment (`moof`) parsing

    private func parseMoof(
        _ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int, moofOffset: Int64
    ) -> PendingMoof {
        var trafs: [ParsedTraf] = []
        var pos = payloadStart
        while pos + 8 <= end {
            guard let box = readBoxHeader(base, offset: pos, limit: end) else { break }
            if box.type == Self.boxTraf, let traf = parseTraf(base, payloadStart: box.payloadStart, end: box.end) {
                trafs.append(traf)
            }
            pos = box.end
        }
        return PendingMoof(moofOffset: moofOffset, trafs: trafs)
    }

    private func parseTraf(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> ParsedTraf? {
        var tfhd: ParsedTFHD?
        var tfdt: Int64?
        var truns: [ParsedTrun] = []

        var pos = payloadStart
        while pos + 8 <= end {
            guard let box = readBoxHeader(base, offset: pos, limit: end) else { break }
            switch box.type {
            case Self.boxTfhd:
                tfhd = parseTfhd(base, payloadStart: box.payloadStart, end: box.end)
            case Self.boxTfdt:
                tfdt = parseTfdt(base, payloadStart: box.payloadStart, end: box.end)
            case Self.boxTrun:
                if let trun = parseTrun(base, payloadStart: box.payloadStart, end: box.end) {
                    truns.append(trun)
                }
            default:
                break
            }
            pos = box.end
        }
        guard let tfhd else { return nil }
        return ParsedTraf(tfhd: tfhd, baseMediaDecodeTime: tfdt, truns: truns)
    }

    private func parseTfhd(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> ParsedTFHD? {
        guard payloadStart + 8 <= end else { return nil }
        let vf = Self.readUInt32BE(base, at: payloadStart)
        let flags = vf & 0x00FF_FFFF
        let trackID = Self.readUInt32BE(base, at: payloadStart + 4)
        var pos = payloadStart + 8

        var baseDataOffset: UInt64?
        var sampleDescriptionIndex: UInt32?
        var defaultSampleDuration: UInt32?
        var defaultSampleSize: UInt32?
        var defaultSampleFlags: UInt32?

        if (flags & 0x000001) != 0 {
            guard pos + 8 <= end else { return nil }
            baseDataOffset = Self.readUInt64BE(base, at: pos)
            pos += 8
        }
        if (flags & 0x000002) != 0 {
            guard pos + 4 <= end else { return nil }
            sampleDescriptionIndex = Self.readUInt32BE(base, at: pos)
            pos += 4
        }
        if (flags & 0x000008) != 0 {
            guard pos + 4 <= end else { return nil }
            defaultSampleDuration = Self.readUInt32BE(base, at: pos)
            pos += 4
        }
        if (flags & 0x000010) != 0 {
            guard pos + 4 <= end else { return nil }
            defaultSampleSize = Self.readUInt32BE(base, at: pos)
            pos += 4
        }
        if (flags & 0x000020) != 0 {
            guard pos + 4 <= end else { return nil }
            defaultSampleFlags = Self.readUInt32BE(base, at: pos)
            pos += 4
        }

        return ParsedTFHD(
            trackID: trackID,
            baseDataOffset: baseDataOffset,
            sampleDescriptionIndex: sampleDescriptionIndex,
            defaultSampleDuration: defaultSampleDuration,
            defaultSampleSize: defaultSampleSize,
            defaultSampleFlags: defaultSampleFlags,
            durationIsEmpty: (flags & 0x010000) != 0,
            defaultBaseIsMoof: (flags & 0x020000) != 0
        )
    }

    private func parseTfdt(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> Int64? {
        guard payloadStart + 8 <= end else { return nil }
        let version = base[payloadStart]
        if version == 1 {
            guard payloadStart + 12 <= end else { return nil }
            let raw = Self.readUInt64BE(base, at: payloadStart + 4)
            return Int64(bitPattern: raw)
        } else {
            return Int64(Self.readUInt32BE(base, at: payloadStart + 4))
        }
    }

    private func parseTrun(_ base: UnsafePointer<UInt8>, payloadStart: Int, end: Int) -> ParsedTrun? {
        guard payloadStart + 8 <= end else { return nil }
        let vf = Self.readUInt32BE(base, at: payloadStart)
        let version = UInt8((vf >> 24) & 0xFF)
        let flags = vf & 0x00FF_FFFF
        let sampleCount = Int(Self.readUInt32BE(base, at: payloadStart + 4))
        var pos = payloadStart + 8

        var dataOffset: Int32?
        var firstSampleFlags: UInt32?

        if (flags & 0x000001) != 0 {
            guard pos + 4 <= end else { return nil }
            dataOffset = Int32(bitPattern: Self.readUInt32BE(base, at: pos))
            pos += 4
        }
        if (flags & 0x000004) != 0 {
            guard pos + 4 <= end else { return nil }
            firstSampleFlags = Self.readUInt32BE(base, at: pos)
            pos += 4
        }

        let hasDuration = (flags & 0x000100) != 0
        let hasSize = (flags & 0x000200) != 0
        let hasFlags = (flags & 0x000400) != 0
        let hasCTO = (flags & 0x000800) != 0

        let entryStride = (hasDuration ? 4 : 0) + (hasSize ? 4 : 0) + (hasFlags ? 4 : 0) + (hasCTO ? 4 : 0)
        if entryStride > 0 {
            guard sampleCount >= 0, pos + sampleCount * entryStride <= end else { return nil }
        }

        var samples: [ParsedTrunSample] = []
        samples.reserveCapacity(min(sampleCount, 1024))
        for _ in 0..<sampleCount {
            var dur: UInt32?
            var sz: UInt32?
            var fl: UInt32?
            var cto: Int64 = 0
            if hasDuration {
                dur = Self.readUInt32BE(base, at: pos)
                pos += 4
            }
            if hasSize {
                sz = Self.readUInt32BE(base, at: pos)
                pos += 4
            }
            if hasFlags {
                fl = Self.readUInt32BE(base, at: pos)
                pos += 4
            }
            if hasCTO {
                let raw = Self.readUInt32BE(base, at: pos)
                cto = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
                pos += 4
            }
            samples.append(ParsedTrunSample(duration: dur, size: sz, flags: fl, compositionTimeOffset: cto))
        }

        return ParsedTrun(dataOffset: dataOffset, firstSampleFlags: firstSampleFlags, samples: samples)
    }

    // MARK: - Sample extraction (`moof` + `mdat` -> `[DemuxedSample]`)

    private mutating func extractSamples(
        from moof: PendingMoof,
        mdatBase: UnsafePointer<UInt8>,
        mdatLength: Int,
        mdatPayloadOffset: Int64,
        into out: inout [DemuxedSample]
    ) {
        var rawSamples: [PendingRawSample] = []
        var prevTrafEndOffset = mdatPayloadOffset

        for (trafIndex, traf) in moof.trafs.enumerated() {
            let tid = traf.tfhd.trackID
            guard let track = tracks[tid] else { continue }
            let trex = trexByTrack[tid]

            let defaultDuration = traf.tfhd.defaultSampleDuration ?? trex?.defaultSampleDuration ?? 0
            let defaultSize = traf.tfhd.defaultSampleSize ?? trex?.defaultSampleSize ?? 0
            let tfhdDefaultFlags = traf.tfhd.defaultSampleFlags
            let trexDefaultFlags = trex?.defaultSampleFlags ?? 0

            let baseDataOffset: Int64
            if let explicit = traf.tfhd.baseDataOffset {
                baseDataOffset = Int64(bitPattern: explicit)
            } else if traf.tfhd.defaultBaseIsMoof || trafIndex == 0 {
                baseDataOffset = moof.moofOffset
            } else {
                baseDataOffset = prevTrafEndOffset
            }

            var decodeTime: Int64
            if let tfdt = traf.baseMediaDecodeTime {
                decodeTime = tfdt
            } else {
                decodeTime = lastDecodeTimeByTrack[tid] ?? 0
            }

            var runningDataOffset = max(baseDataOffset, mdatPayloadOffset)

            for trun in traf.truns {
                var cursor: Int64
                if let dataOffset = trun.dataOffset {
                    cursor = baseDataOffset + Int64(dataOffset)
                } else {
                    cursor = runningDataOffset
                }

                for (sampleIndex, entry) in trun.samples.enumerated() {
                    let duration = entry.duration ?? defaultDuration
                    let size = Int(entry.size ?? defaultSize)
                    let sampleDTS = decodeTime
                    let samplePTS = sampleDTS + entry.compositionTimeOffset
                    decodeTime += Int64(duration)

                    let sampleStart = cursor
                    cursor += Int64(size)
                    runningDataOffset = cursor
                    prevTrafEndOffset = cursor

                    guard size > 0 else { continue }
                    let relStart = sampleStart - mdatPayloadOffset
                    guard relStart >= 0, relStart + Int64(size) <= Int64(mdatLength) else { continue }
                    let samplePtr = mdatBase + Int(relStart)

                    let rawDTS90k = Self.rescaleTo90k(sampleDTS, timescale: track.timescale)
                    let rawPTS90k = Self.rescaleTo90k(samplePTS, timescale: track.timescale)

                    switch track.kind {
                    case .video(let nalLenSize):
                        let sampleFlags: UInt32
                        let hasExplicitFlags: Bool
                        if let f = entry.flags {
                            sampleFlags = f
                            hasExplicitFlags = true
                        } else if sampleIndex == 0, let firstF = trun.firstSampleFlags {
                            sampleFlags = firstF
                            hasExplicitFlags = true
                        } else if let f = tfhdDefaultFlags {
                            sampleFlags = f
                            hasExplicitFlags = true
                        } else {
                            sampleFlags = trexDefaultFlags
                            hasExplicitFlags = false
                        }

                        let (avcc, hasIDR) = processVideoSample(samplePtr, length: size, nalLengthSize: nalLenSize)
                        guard !avcc.isEmpty else { continue }

                        let sampleDependsOn = (sampleFlags >> 24) & 0x03
                        let isNonSync = (sampleFlags >> 16) & 0x01
                        let flagsIndicateSync = hasExplicitFlags && (sampleDependsOn == 2) && (isNonSync == 0)
                        let isKeyframe = hasIDR || flagsIndicateSync

                        rawSamples.append(PendingRawSample(
                            rawPTS90k: rawPTS90k,
                            rawDTS90k: rawDTS90k,
                            payload: .video(avcc: avcc, isKeyframe: isKeyframe, sps: latestSPS, pps: latestPPS)
                        ))

                    case .audio(let cfg):
                        let aac = Data(bytes: samplePtr, count: size)
                        rawSamples.append(PendingRawSample(
                            rawPTS90k: rawPTS90k,
                            rawDTS90k: rawDTS90k,
                            payload: .audio(aac: aac, config: cfg)
                        ))
                    }
                }
            }

            lastDecodeTimeByTrack[tid] = decodeTime
        }

        guard !rawSamples.isEmpty else { return }

        // Compute one shared timeline anchor across all tracks in this `moof` so audio & video stay locked to the tick.
        var minRawTime = Int64.max
        for s in rawSamples {
            minRawTime = min(minRawTime, min(s.rawDTS90k, s.rawPTS90k))
        }

        if !hasTimeline {
            hasTimeline = true
            timelineOffset = -minRawTime
            lastRawAnchor90k = minRawTime
        } else if needsRebase {
            needsRebase = false
            let targetStart = highestContinuousPTS + Self.discontinuityStep
            timelineOffset = targetStart - minRawTime
            lastRawAnchor90k = minRawTime
        } else if let prev = lastRawAnchor90k, abs(minRawTime - prev) > Self.maxContinuousJump {
            // Unannounced timeline jump (e.g. encoder reset without `#EXT-X-DISCONTINUITY`).
            let targetStart = highestContinuousPTS + Self.discontinuityStep
            timelineOffset = targetStart - minRawTime
            lastRawAnchor90k = minRawTime
        } else {
            lastRawAnchor90k = max(lastRawAnchor90k ?? minRawTime, minRawTime)
        }

        out.reserveCapacity(out.count + rawSamples.count)
        for s in rawSamples {
            let cPTS = s.rawPTS90k + timelineOffset
            let cDTS = s.rawDTS90k + timelineOffset
            highestContinuousPTS = max(highestContinuousPTS, cPTS)

            switch s.payload {
            case .video(let avcc, let isKeyframe, let sps, let pps):
                out.append(.video(DemuxedVideoFrame(
                    avccData: avcc,
                    pts90k: cPTS,
                    dts90k: cDTS,
                    isKeyframe: isKeyframe,
                    sps: sps,
                    pps: pps
                )))
            case .audio(let aac, let cfg):
                out.append(.audio(DemuxedAudioFrame(
                    aacData: aac,
                    pts90k: cPTS,
                    sampleRate: cfg.sampleRate,
                    channels: cfg.channels,
                    audioObjectType: cfg.audioObjectType,
                    audioSpecificConfig: cfg.audioSpecificConfig
                )))
            }
        }
    }

    /// Scans length-prefixed AVCC NALUs in a video sample, extracting inline SPS/PPS, detecting IDR slices (type 5),
    /// stripping non-VCL NALUs (SPS/PPS/AUD/SEI/filler), and normalizing to 4-byte length-prefixed AVCC.
    private mutating func processVideoSample(
        _ ptr: UnsafePointer<UInt8>, length: Int, nalLengthSize: Int
    ) -> (avcc: Data, hasIDR: Bool) {
        let lenBytes = (nalLengthSize == 1 || nalLengthSize == 2 || nalLengthSize == 4) ? nalLengthSize : 4
        var out = Data()
        out.reserveCapacity(length)
        var hasIDR = false
        var pos = 0

        while pos + lenBytes <= length {
            let naluLen: Int
            switch lenBytes {
            case 1:
                naluLen = Int(ptr[pos])
            case 2:
                naluLen = Int(Self.readUInt16BE(ptr, at: pos))
            default:
                naluLen = Int(Self.readUInt32BE(ptr, at: pos))
            }
            pos += lenBytes
            guard naluLen > 0, pos + naluLen <= length else { break }

            let nalType = ptr[pos] & 0x1F
            switch nalType {
            case 7: // Inline SPS
                latestSPS = Data(bytes: ptr + pos, count: naluLen)
            case 8: // Inline PPS
                latestPPS = Data(bytes: ptr + pos, count: naluLen)
            case 5: // IDR slice
                hasIDR = true
                Self.appendAVCCNALU(ptr + pos, count: naluLen, to: &out)
            case 1, 2, 3, 4: // Non-IDR VCL slices
                Self.appendAVCCNALU(ptr + pos, count: naluLen, to: &out)
            default:
                // AUD (9), SEI (6), filler (12), etc.: stripped to match MPEGTSDemuxer's AVCC contract.
                break
            }
            pos += naluLen
        }

        return (out, hasIDR)
    }

    private static func appendAVCCNALU(_ ptr: UnsafePointer<UInt8>, count: Int, to out: inout Data) {
        var len = UInt32(count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(ptr, count: count)
    }

    // MARK: - Low-level box & bit readers

    private struct BoxHeader {
        let type: UInt32
        let payloadStart: Int
        let end: Int
    }

    private func readBoxHeader(_ base: UnsafePointer<UInt8>, offset: Int, limit: Int) -> BoxHeader? {
        guard offset + 8 <= limit else { return nil }
        let size32 = Self.readUInt32BE(base, at: offset)
        let type = Self.readUInt32BE(base, at: offset + 4)
        if size32 == 1 {
            guard offset + 16 <= limit else { return nil }
            let size64 = Self.readUInt64BE(base, at: offset + 8)
            guard size64 >= 16, size64 <= UInt64(limit - offset) else { return nil }
            return BoxHeader(type: type, payloadStart: offset + 16, end: offset + Int(size64))
        } else if size32 == 0 {
            return BoxHeader(type: type, payloadStart: offset + 8, end: limit)
        } else {
            let size = Int(size32)
            guard size >= 8, offset + size <= limit else { return nil }
            return BoxHeader(type: type, payloadStart: offset + 8, end: offset + size)
        }
    }

    private static func readUInt16BE(_ p: UnsafePointer<UInt8>, at off: Int) -> UInt16 {
        (UInt16(p[off]) << 8) | UInt16(p[off + 1])
    }

    private static func readUInt32BE(_ p: UnsafePointer<UInt8>, at off: Int) -> UInt32 {
        (UInt32(p[off]) << 24)
            | (UInt32(p[off + 1]) << 16)
            | (UInt32(p[off + 2]) << 8)
            | UInt32(p[off + 3])
    }

    private static func readUInt64BE(_ p: UnsafePointer<UInt8>, at off: Int) -> UInt64 {
        (UInt64(readUInt32BE(p, at: off)) << 32) | UInt64(readUInt32BE(p, at: off + 4))
    }

    private struct BitReader {
        private let bytes: [UInt8]
        private var bitOffset = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        mutating func read(_ count: Int) -> UInt32? {
            guard count > 0, count <= 32, bitOffset + count <= bytes.count * 8 else { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                let byteIdx = bitOffset >> 3
                let bitInByte = 7 - (bitOffset & 7)
                value = (value << 1) | UInt32((bytes[byteIdx] >> bitInByte) & 1)
                bitOffset += 1
            }
            return value
        }
    }
}
