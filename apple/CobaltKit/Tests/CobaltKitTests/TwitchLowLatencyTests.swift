import CoreMedia
import Foundation
import Testing
@testable import CobaltKit

// Low-latency Twitch HLS parser, MPEG-TS demuxer, CoreMedia sample-buffer factory, and GQL/Usher resolver tests.

struct TwitchHLSParserTests {
    @Test func masterPlaylistParsesVariantsAndCompatibility() throws {
        let master = """
        #EXTM3U
        #EXT-X-TWITCH-INFO:NODE="video-edge",MANIFEST-NODE-TYPE="weaver_cluster",LOW-LATENCY="true"
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.000
        https://video-weaver.example.net/v1/playlist/chunked.m3u8
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="720p60",NAME="720p60",AUTOSELECT=YES,DEFAULT=NO
        #EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1280x720,CODECS="avc1.4D401F,mp4a.40.2",VIDEO="720p60",FRAME-RATE=59.940
        https://video-weaver.example.net/v1/playlist/720p60.m3u8
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="1440p60",NAME="1440p60 (HEVC)",AUTOSELECT=NO,DEFAULT=NO
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=2560x1440,CODECS="hev1.1.6.L123.B0,mp4a.40.2",VIDEO="1440p60",FRAME-RATE=60.000
        https://video-weaver.example.net/v1/playlist/1440p60.m3u8
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="audio_only",NAME="audio_only",AUTOSELECT=NO,DEFAULT=NO
        #EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",VIDEO="audio_only"
        https://video-weaver.example.net/v1/playlist/audio.m3u8
        """

        let variants = TwitchHLSParser.parseMaster(master)
        #expect(variants.count == 4)

        let source = try #require(variants.first(where: { $0.id == "chunked" }))
        #expect(source.isSource)
        #expect(!source.isAudioOnly)
        #expect(source.isNativeCompatible)
        #expect(source.width == 1920 && source.height == 1080)
        #expect(source.shortLabel == "1080p60 · source")

        let mid = try #require(variants.first(where: { $0.id == "720p60" }))
        #expect(!mid.isSource)
        #expect(mid.isNativeCompatible)
        #expect(mid.shortLabel == "720p60")

        let hevc = try #require(variants.first(where: { $0.id == "1440p60" }))
        #expect(!hevc.isNativeCompatible)

        let audio = try #require(variants.first(where: { $0.id == "audio_only" }))
        #expect(audio.isAudioOnly)
        #expect(audio.isNativeCompatible)
        #expect(audio.shortLabel == "audio only")
    }

    @Test func mediaPlaylistParsesPrefetchServerTimeDiscontinuityAndAds() throws {
        let media = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:100
        #EXT-X-TWITCH-LIVE-SEQUENCE:102
        #EXT-X-DATERANGE:ID="source-100",CLASS="twitch-stream-source",START-DATE="2026-11-25T12:00:00.000Z",X-SERVER-TIME="2026-11-25T12:00:06.500Z"
        #EXT-X-PROGRAM-DATE-TIME:2026-11-25T12:00:00.000Z
        #EXTINF:2.000,live
        https://edge.example.net/seg/100.ts?dna=abc123
        #EXT-X-DISCONTINUITY
        #EXT-X-PROGRAM-DATE-TIME:2026-11-25T12:00:02.000Z
        #EXTINF:2.000,Amazon|stitched-ad
        https://edge.example.net/seg/101.ts?dna=def456
        #EXT-X-TWITCH-PREFETCH:https://edge.example.net/prefetch/102.ts?dna=p1
        #EXT-X-TWITCH-PREFETCH:https://edge.example.net/prefetch/103.ts?dna=p2
        """

        let pl = TwitchHLSParser.parseMedia(media)
        #expect(pl.targetDuration == 2)
        #expect(pl.mediaSequence == 100)
        #expect(pl.liveSequence == 102)
        #expect(pl.isLowLatency)
        #expect(!pl.isEndList)
        #expect(pl.segments.count == 2)
        #expect(pl.prefetchSegments.count == 2)
        #expect(pl.allSegments.count == 4)

        let serverTime = try #require(pl.serverTime)
        let firstPDT = try #require(pl.segments[0].programDateTime)
        #expect(abs(serverTime.timeIntervalSince(firstPDT) - 6.5) < 0.01)

        #expect(!pl.segments[0].isDiscontinuity)
        #expect(!pl.segments[0].isAd)
        #expect(pl.segments[1].isDiscontinuity)
        #expect(pl.segments[1].isAd)

        // Prefetch segments get sequential indices after completed segments and extrapolated PDTs.
        #expect(pl.prefetchSegments[0].sequence == 102)
        #expect(pl.prefetchSegments[1].sequence == 103)
        #expect(pl.prefetchSegments[0].isPrefetch)
        let pf0PDT = try #require(pl.prefetchSegments[0].programDateTime)
        #expect(abs(pf0PDT.timeIntervalSince(firstPDT) - 4.0) < 0.01)

        // Query parameters are stripped from dedupKey.
        let copyWithDifferentQuery = TwitchSegment(
            sequence: 100,
            url: URL(string: "https://edge.example.net/seg/100.ts?dna=different")!,
            duration: 2.0,
            programDateTime: nil,
            isPrefetch: false,
            isDiscontinuity: false,
            isAd: false
        )
        #expect(pl.segments[0].dedupKey == copyWithDifferentQuery.dedupKey)
    }

    @Test func attributeParserHandlesQuotedCommas() {
        let attrs = TwitchHLSParser.parseAttributes(#"CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080,NAME="1080p60 (source)""#)
        #expect(attrs["CODECS"] == "avc1.64002A,mp4a.40.2")
        #expect(attrs["RESOLUTION"] == "1920x1080")
        #expect(attrs["NAME"] == "1080p60 (source)")
    }
}

struct MPEGTSDemuxerTests {
    // Valid H.264 High/Baseline SPS & PPS (16x16 minimal valid bitstreams accepted by VideoToolbox / CoreMedia).
    static let sampleSPS = Data([
        0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x00, 0xA0, 0x47,
        0xFE, 0xC8, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00,
        0x00, 0x03, 0x01, 0xE0, 0x78, 0xB1, 0x75,
    ])
    static let samplePPS = Data([0x68, 0xCE, 0x3C, 0x80])

    @Test func demuxesIncrementalChunksWithSyncRecoveryH264AndADTS() throws {
        let sps = Self.sampleSPS
        let pps = Self.samplePPS
        let idrSlice = Data([0x65, 0x88, 0x84, 0x21, 0xA0])
        let pSlice = Data([0x41, 0x9A, 0x22, 0x33])

        // Annex-B access unit 1: AUD + SPS + PPS + IDR (with both 4-byte and 3-byte start codes)
        var au1 = Data()
        au1.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0x10]) // AUD (stripped)
        au1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        au1.append(sps)
        au1.append(contentsOf: [0x00, 0x00, 0x01])
        au1.append(pps)
        au1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        au1.append(idrSlice)

        // Annex-B access unit 2: non-IDR P-slice
        var au2 = Data([0x00, 0x00, 0x00, 0x01])
        au2.append(pSlice)

        // Two ADTS AAC frames in one PES (48 kHz, stereo, AAC-LC) — first 7-byte header, second 9-byte CRC header.
        let aac1 = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C])
        let aac2 = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1D, 0xEE])
        var adtsPayload = makeADTSFrame(payload: aac1, sampleRateIndex: 3, channels: 2, hasCRC: false)
        adtsPayload.append(makeADTSFrame(payload: aac2, sampleRateIndex: 3, channels: 2, hasCRC: true))

        var stream = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]) // leading garbage to test 0x47 sync recovery
        stream.append(makePAT(pmtPID: 0x0100))
        stream.append(makePMT(pmtPID: 0x0100, videoPID: 0x0101, videoStreamType: 0x1B, audioPID: 0x0102))
        stream.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 90_000, dts: 87_000, payload: au1))
        stream.append(makePESPackets(pid: 0x0102, streamID: 0xC0, pts: 90_000, dts: nil, payload: adtsPayload))
        stream.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 93_000, dts: 90_000, payload: au2))

        // Feed in awkward 13-byte chunks to verify incremental framing.
        var demuxer = MPEGTSDemuxer()
        var samples: [DemuxedSample] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 13, stream.count)
            samples.append(contentsOf: demuxer.push(stream[offset..<end]))
            offset = end
        }
        samples.append(contentsOf: demuxer.flushSegment())

        #expect(demuxer.unsupportedVideoCodec == nil)
        #expect(demuxer.videoPID == 0x0101)
        #expect(demuxer.audioPID == 0x0102)
        #expect(demuxer.latestSPS == sps)
        #expect(demuxer.latestPPS == pps)

        let videoFrames = samples.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        let audioFrames = samples.compactMap { if case .audio(let a) = $0 { return a } else { return nil } }

        #expect(videoFrames.count == 2)
        #expect(videoFrames[0].isKeyframe)
        // Initial timeline is rebased so the first timestamp starts at 0 while preserving B-frame PTS-DTS (+3000) and deltas.
        #expect(videoFrames[0].dts90k == 0)
        #expect(videoFrames[0].pts90k == 3_000)
        // AVCC length prefix (4 bytes) + IDR payload only (AUD/SPS/PPS stripped).
        #expect(videoFrames[0].avccData == Data([0x00, 0x00, 0x00, UInt8(idrSlice.count)]) + idrSlice)

        #expect(!videoFrames[1].isKeyframe)
        #expect(videoFrames[1].dts90k == 3_000)
        #expect(videoFrames[1].pts90k == 6_000)
        #expect(videoFrames[1].avccData == Data([0x00, 0x00, 0x00, UInt8(pSlice.count)]) + pSlice)

        #expect(audioFrames.count == 2)
        #expect(audioFrames[0].aacData == aac1)
        #expect(audioFrames[0].sampleRate == 48_000)
        #expect(audioFrames[0].channels == 2)
        #expect(audioFrames[0].audioObjectType == 2)
        #expect(audioFrames[0].pts90k == 3_000)
        // 48 kHz AAC-LC stereo AudioSpecificConfig: (2 << 11) | (3 << 7) | (2 << 3) = 0x1190
        #expect(audioFrames[0].audioSpecificConfig == Data([0x11, 0x90]))

        #expect(audioFrames[1].aacData == aac2)
        // Second frame PTS advances by 1024 / 48000 * 90000 = 1920 ticks.
        #expect(audioFrames[1].pts90k == 4_920)
    }

    @Test func unwraps33BitPTSWrapAndRebasesDiscontinuity() throws {
        let max33: Int64 = (1 << 33)
        let beforeWrap = max33 - 1_500 // ~16.7 ms before 33-bit rollover
        let afterWrap: Int64 = 1_500   // ~16.7 ms after rollover (delta = +3000 ticks)

        let idr = Data([0x00, 0x00, 0x00, 0x01]) + Self.sampleSPS
            + Data([0x00, 0x00, 0x00, 0x01]) + Self.samplePPS
            + Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84])

        var seg1 = Data()
        seg1.append(makePAT(pmtPID: 0x0100))
        seg1.append(makePMT(pmtPID: 0x0100, videoPID: 0x0101, videoStreamType: 0x1B, audioPID: nil))
        seg1.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: beforeWrap, dts: nil, payload: idr))
        seg1.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: afterWrap, dts: nil, payload: idr))

        var demuxer = MPEGTSDemuxer()
        var out = demuxer.push(seg1)
        out.append(contentsOf: demuxer.flushSegment())

        // Now signal #EXT-X-DISCONTINUITY where the next segment restarts timestamps at 0.
        out.append(contentsOf: demuxer.beginDiscontinuity())
        var seg2 = Data()
        seg2.append(makePAT(pmtPID: 0x0100))
        seg2.append(makePMT(pmtPID: 0x0100, videoPID: 0x0101, videoStreamType: 0x1B, audioPID: nil))
        seg2.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 0, dts: nil, payload: idr))
        seg2.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 3_000, dts: nil, payload: idr))
        out.append(contentsOf: demuxer.push(seg2))
        out.append(contentsOf: demuxer.flushSegment())

        let ptsValues = out.compactMap { if case .video(let v) = $0 { return v.pts90k } else { return nil } }
        #expect(ptsValues.count == 4)
        // Wrap delta is exactly +3000 ticks.
        #expect(ptsValues[1] - ptsValues[0] == 3_000)
        // Discontinuity rebased strictly forward and preserved intra-segment delta (+3000).
        #expect(ptsValues[2] > ptsValues[1])
        #expect(ptsValues[3] - ptsValues[2] == 3_000)
    }

    @Test func detectsUnsupportedHEVCVideoCodecInPMT() {
        var stream = Data()
        stream.append(makePAT(pmtPID: 0x0100))
        stream.append(makePMT(pmtPID: 0x0100, videoPID: 0x0101, videoStreamType: 0x24, audioPID: 0x0102))

        var demuxer = MPEGTSDemuxer()
        _ = demuxer.push(stream)
        #expect(demuxer.unsupportedVideoCodec == "hevc")
    }

    @Test func reassemblesUnalignedPESVideoAccessUnitsAcrossBoundaries() {
        var stream = Data()
        stream.append(makePAT(pmtPID: 0x0100))
        stream.append(makePMT(pmtPID: 0x0100, videoPID: 0x0101, videoStreamType: 0x1B, audioPID: nil))

        // Build 3 Access Units matching Twitch's live TS muxer:
        // - PES 0 carries AUD + SPS + PPS + head of IDR slice (missing its last 139 bytes).
        // - PES 1 begins with those 139 tail bytes of frame 0's IDR slice, then AUD + P-slice 1 + first two 0x00 bytes of next start code.
        // - PES 2 begins with `00 01 09 F0` (completing the straddling start code + AUD) + P-slice 2.
        let idrHead = Data([0x65, 0xB8]) + Data(repeating: 0xAA, count: 198)
        let idrTail = Data(repeating: 0xBB, count: 138) + Data([0xC0])
        let fullIDR = idrHead + idrTail

        let pSlice1 = Data([0x41, 0x9A]) + Data(repeating: 0xCC, count: 60) + Data([0x80])
        let pSlice2 = Data([0x41, 0x9A]) + Data(repeating: 0xDD, count: 40) + Data([0x80])

        var pes0 = Data([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
        pes0.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        pes0.append(Self.sampleSPS)
        pes0.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        pes0.append(Self.samplePPS)
        pes0.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        pes0.append(idrHead)

        var pes1 = Data()
        pes1.append(idrTail)
        pes1.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
        pes1.append(contentsOf: [0x00, 0x00, 0x01])
        pes1.append(pSlice1)
        pes1.append(contentsOf: [0x00, 0x00]) // first half of straddling 4-byte start code

        var pes2 = Data([0x00, 0x01, 0x09, 0xF0]) // second half of straddling start code + AUD
        pes2.append(contentsOf: [0x00, 0x00, 0x01])
        pes2.append(pSlice2)

        stream.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 92_970, dts: 90_000, payload: pes0))
        stream.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 97_470, dts: 91_530, payload: pes1))
        stream.append(makePESPackets(pid: 0x0101, streamID: 0xE0, pts: 94_500, dts: 93_060, payload: pes2))

        // Feed in small irregular 53-byte chunks to simulate incremental HTTP prefetch streaming.
        var demuxer = MPEGTSDemuxer()
        var samples: [DemuxedSample] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 53, stream.count)
            samples.append(contentsOf: demuxer.push(stream.subdata(in: offset..<end)))
            offset = end
        }
        samples.append(contentsOf: demuxer.flushSegment())

        let videos = samples.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        #expect(videos.count == 3)
        #expect(videos[0].isKeyframe)
        #expect(videos[0].pts90k == 2_970)
        #expect(videos[0].dts90k == 0)
        #expect(videos[0].avccData.count == 4 + fullIDR.count)
        #expect(videos[0].avccData.dropFirst(4) == fullIDR)

        #expect(!videos[1].isKeyframe)
        #expect(videos[1].pts90k == 7_470)
        #expect(videos[1].dts90k == 1_530)
        #expect(videos[1].avccData.dropFirst(4) == pSlice1)

        #expect(!videos[2].isKeyframe)
        #expect(videos[2].pts90k == 4_500)
        #expect(videos[2].dts90k == 3_060)
        #expect(videos[2].avccData.dropFirst(4) == pSlice2)
    }

    // MARK: - Synthetic TS helpers

    private func makePAT(pmtPID: UInt16) -> Data {
        var sec = Data([
            0x00, // pointer_field
            0x00, // table_id (PAT)
            0xB0, 0x0D, // section_syntax_indicator + section_length = 13
            0x00, 0x01, // transport_stream_id
            0xC1,       // version 0, current_next = 1
            0x00, 0x00, // section_number, last_section_number
            0x00, 0x01, // program_number = 1
            UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)), UInt8(pmtPID & 0xFF),
            0x00, 0x00, 0x00, 0x00, // CRC32 placeholder
        ])
        return wrapTSPacket(pid: 0x0000, pusi: true, payload: &sec)
    }

    private func makePMT(pmtPID: UInt16, videoPID: UInt16?, videoStreamType: UInt8, audioPID: UInt16?) -> Data {
        var entries = Data()
        if let vpid = videoPID {
            entries.append(contentsOf: [
                videoStreamType,
                UInt8(0xE0 | ((vpid >> 8) & 0x1F)), UInt8(vpid & 0xFF),
                0xF0, 0x00, // es_info_length = 0
            ])
        }
        if let apid = audioPID {
            entries.append(contentsOf: [
                0x0F, // ADTS AAC
                UInt8(0xE0 | ((apid >> 8) & 0x1F)), UInt8(apid & 0xFF),
                0xF0, 0x00,
            ])
        }
        let sectionLen = 9 + entries.count + 4
        var sec = Data([
            0x00, // pointer_field
            0x02, // table_id (PMT)
            UInt8(0xB0 | ((sectionLen >> 8) & 0x0F)), UInt8(sectionLen & 0xFF),
            0x00, 0x01, // program_number
            0xC1,
            0x00, 0x00,
            0xE1, 0x01, // PCR_PID
            0xF0, 0x00, // program_info_length = 0
        ])
        sec.append(entries)
        sec.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC32 placeholder
        return wrapTSPacket(pid: pmtPID, pusi: true, payload: &sec)
    }

    private func makePESPackets(pid: UInt16, streamID: UInt8, pts: Int64, dts: Int64?, payload: Data) -> Data {
        var pes = Data([0x00, 0x00, 0x01, streamID, 0x00, 0x00, 0x80])
        if let dts {
            pes.append(contentsOf: [0xC0, 0x0A]) // PTS + DTS (10 bytes)
            pes.append(encodeTimestamp(pts, prefix: 0x30))
            pes.append(encodeTimestamp(dts, prefix: 0x10))
        } else {
            pes.append(contentsOf: [0x80, 0x05]) // PTS only (5 bytes)
            pes.append(encodeTimestamp(pts, prefix: 0x20))
        }
        pes.append(payload)

        var out = Data()
        var offset = 0
        var first = true
        while offset < pes.count {
            let chunkLen = min(184, pes.count - offset)
            var slice = Data(pes[offset..<(offset + chunkLen)])
            out.append(wrapTSPacket(pid: pid, pusi: first, payload: &slice))
            offset += chunkLen
            first = false
        }
        return out
    }

    private func encodeTimestamp(_ ts: Int64, prefix: UInt8) -> Data {
        let v = UInt64(bitPattern: ts) & 0x1_FFFF_FFFF
        let b0 = prefix | UInt8(((v >> 30) & 0x07) << 1) | 0x01
        let b1 = UInt8((v >> 22) & 0xFF)
        let b2 = UInt8(((v >> 15) & 0x7F) << 1) | 0x01
        let b3 = UInt8((v >> 7) & 0xFF)
        let b4 = UInt8((v & 0x7F) << 1) | 0x01
        return Data([b0, b1, b2, b3, b4])
    }

    private func wrapTSPacket(pid: UInt16, pusi: Bool, payload: inout Data) -> Data {
        var pkt = Data()
        pkt.reserveCapacity(188)
        let b1 = (pusi ? UInt8(0x40) : 0x00) | UInt8((pid >> 8) & 0x1F)
        let b2 = UInt8(pid & 0xFF)
        if payload.count < 184 {
            // Use adaptation field stuffing so payload stays exact.
            let stuffLen = 184 - payload.count
            pkt.append(contentsOf: [0x47, b1, b2, 0x30]) // adaptation + payload
            pkt.append(UInt8(stuffLen - 1))
            if stuffLen > 1 {
                pkt.append(0x00) // flags
                if stuffLen > 2 {
                    pkt.append(Data(repeating: 0xFF, count: stuffLen - 2))
                }
            }
            pkt.append(payload)
        } else {
            pkt.append(contentsOf: [0x47, b1, b2, 0x10]) // payload only
            pkt.append(payload.prefix(184))
        }
        return pkt
    }

    private func makeADTSFrame(payload: Data, sampleRateIndex: Int, channels: Int, hasCRC: Bool) -> Data {
        let headerLen = hasCRC ? 9 : 7
        let frameLen = headerLen + payload.count
        let profile = 1 // AAC-LC -> audioObjectType 2
        let b0: UInt8 = 0xFF
        let b1: UInt8 = hasCRC ? 0xF0 : 0xF1
        let b2: UInt8 = UInt8((profile << 6) | ((sampleRateIndex & 0x0F) << 2) | ((channels >> 2) & 0x01))
        let b3: UInt8 = UInt8(((channels & 0x03) << 6) | ((frameLen >> 11) & 0x03))
        let b4: UInt8 = UInt8((frameLen >> 3) & 0xFF)
        let b5: UInt8 = UInt8(((frameLen & 0x07) << 5) | 0x1F)
        let b6: UInt8 = 0xFC
        var out = Data([b0, b1, b2, b3, b4, b5, b6])
        if hasCRC { out.append(contentsOf: [0x00, 0x00]) }
        out.append(payload)
        return out
    }
}

struct TwitchSampleBufferFactoryTests {
    @Test func buildsAudioAndVideoFormatDescriptionsAndSampleBuffers() throws {
        // Audio: 48 kHz stereo AAC-LC (AudioSpecificConfig 0x11 0x90)
        let asc = Data([0x11, 0x90])
        let esds = TwitchSampleBufferFactory.esdsCookie(for: asc)
        #expect(esds.first == 0x03)
        #expect(esds.suffix(3) == Data([0x06, 0x01, 0x02]))

        let audioDesc = try #require(TwitchSampleBufferFactory.audioFormatDescription(
            sampleRate: 48_000, channels: 2, audioObjectType: 2, audioSpecificConfig: asc
        ))
        let audioFrame = DemuxedAudioFrame(
            aacData: Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C]),
            pts90k: 90_000,
            sampleRate: 48_000,
            channels: 2,
            audioObjectType: 2,
            audioSpecificConfig: asc
        )
        let audioSB = try #require(TwitchSampleBufferFactory.audioSampleBuffer(frame: audioFrame, formatDescription: audioDesc))
        #expect(CMSampleBufferGetPresentationTimeStamp(audioSB) == CMTime(value: 90_000, timescale: 90_000))

        // Video: H.264 SPS + PPS -> CMVideoFormatDescription + keyframe & non-keyframe CMSampleBuffers
        let videoDesc = try #require(TwitchSampleBufferFactory.videoFormatDescription(
            sps: MPEGTSDemuxerTests.sampleSPS,
            pps: MPEGTSDemuxerTests.samplePPS
        ))
        let keyframe = DemuxedVideoFrame(
            avccData: Data([0x00, 0x00, 0x00, 0x04, 0x65, 0x88, 0x84, 0x21]),
            pts90k: 90_000,
            dts90k: 87_000,
            isKeyframe: true,
            sps: MPEGTSDemuxerTests.sampleSPS,
            pps: MPEGTSDemuxerTests.samplePPS
        )
        let videoSB = try #require(TwitchSampleBufferFactory.videoSampleBuffer(frame: keyframe, formatDescription: videoDesc))
        #expect(CMSampleBufferGetPresentationTimeStamp(videoSB) == CMTime(value: 90_000, timescale: 90_000))
        #expect(CMSampleBufferGetDecodeTimeStamp(videoSB) == CMTime(value: 87_000, timescale: 90_000))
    }
}

struct TwitchStreamResolverTests {
    private actor RequestLog {
        var requests: [URLRequest] = []
        func append(_ req: URLRequest) { requests.append(req) }
        func snapshot() -> [URLRequest] { requests }
    }

    @Test func resolvesChannelWithFastBreadAndFallsBackFromBadAuthToken() async throws {
        let log = RequestLog()
        let resolver = TwitchStreamResolver { req in
            await log.append(req)
            let url = try #require(req.url)
            if url.host() == "gql.twitch.tv" {
                // Reject authenticated attempt so we verify automatic anonymous fallback.
                if req.value(forHTTPHeaderField: "Authorization") != nil {
                    let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    return (Data(#"{"errors":[{"message":"invalid token"}]}"#.utf8), resp)
                }
                let body = Data(#"{"data":{"streamPlaybackAccessToken":{"value":"{\"channel\":\"capy\"}","signature":"sig123"}}}"#.utf8)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, resp)
            }
            // Usher master playlist
            let master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
            #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.0
            https://weaver.example.net/chunked.m3u8
            """
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(master.utf8), resp)
        }

        let variants = try await resolver.resolve(channel: "Capy!", authToken: "expired-cookie")
        #expect(variants.count == 1)
        #expect(variants[0].id == "chunked")

        let reqs = await log.snapshot()
        #expect(reqs.count == 3)
        // First call sent OAuth header; second retried anonymously with Twitch public Client-ID.
        #expect(reqs[0].value(forHTTPHeaderField: "Authorization") == "OAuth expired-cookie")
        #expect(reqs[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(reqs[1].value(forHTTPHeaderField: "Client-ID") == TwitchStreamResolver.webClientID)

        // Third call hit Usher with fast_bread=true and supported_codecs=avc1.
        let usherURL = try #require(reqs[2].url)
        #expect(usherURL.host() == "usher.ttvnw.net")
        #expect(usherURL.path() == "/api/channel/hls/capy.m3u8")
        let query = URLComponents(url: usherURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(where: { $0.name == "fast_bread" && $0.value == "true" }))
        #expect(query.contains(where: { $0.name == "supported_codecs" && $0.value == "avc1" }))
    }

    @Test func reportsOfflineAndIntegrityErrorsCleanly() async {
        let offlineResolver = TwitchStreamResolver { req in
            let url = req.url!
            if url.host() == "gql.twitch.tv" {
                let body = Data(#"{"data":{"streamPlaybackAccessToken":{"value":"v","signature":"s"}}}"#.utf8)
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }

        await #expect(throws: TwitchHLSError.offline) {
            _ = try await offlineResolver.resolve(channel: "offlinechan")
        }

        let integrityResolver = TwitchStreamResolver { req in
            let url = req.url!
            let body = Data(#"{"errors":[{"message":"failed integrity check"}]}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        await #expect(throws: TwitchHLSError.integrityRequired) {
            _ = try await integrityResolver.resolve(channel: "guardedchan")
        }
    }
}
