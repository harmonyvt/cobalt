import CoreMedia
import Foundation
import Testing
@testable import CobaltKit

// Unit & integration tests for Twitch CMAF / fragmented MP4 (fMP4) low-latency playback:
// - `#EXT-X-MAP` parsing (URI, relative URLs, optional BYTERANGE, `#EXT-X-DISCONTINUITY` scoping, prefetch inheritance)
// - Pure-Swift incremental `FMP4Demuxer` (timescales, B-frames, audio_only, nalLenSize conversion, keyframe detection,
//   unsupported codecs, 64-bit largesize boxes, discontinuities, MPEG-TS <-> fMP4 timeline handoff)
// - End-to-end `TwitchNativeEngine` CMAF streaming, init-segment caching, container splice, idempotent `selectVariant`,
//   and non-PII diagnostic metadata.

// MARK: - Synthetic ISO BMFF / CMAF Builder

enum CMAFFixtureBuilder {
    static let sampleSPS = MPEGTSDemuxerTests.sampleSPS
    static let samplePPS = MPEGTSDemuxerTests.samplePPS

    static func box(_ fourCC: String, payload: Data, useLargeSize: Bool = false) -> Data {
        precondition(fourCC.utf8.count == 4)
        var out = Data()
        if useLargeSize {
            let total = UInt64(16 + payload.count)
            appendUInt32BE(&out, 1)
            out.append(contentsOf: fourCC.utf8)
            appendUInt64BE(&out, total)
        } else {
            let total = UInt32(8 + payload.count)
            appendUInt32BE(&out, total)
            out.append(contentsOf: fourCC.utf8)
        }
        out.append(payload)
        return out
    }

    static func fullBox(_ fourCC: String, version: UInt8, flags: UInt32, body: Data) -> Data {
        var payload = Data()
        payload.append(version)
        payload.append(UInt8((flags >> 16) & 0xFF))
        payload.append(UInt8((flags >> 8) & 0xFF))
        payload.append(UInt8(flags & 0xFF))
        payload.append(body)
        return box(fourCC, payload: payload)
    }

    static func ftypBox() -> Data {
        var body = Data()
        body.append(contentsOf: "isom".utf8)
        appendUInt32BE(&body, 512)
        body.append(contentsOf: "iso6".utf8)
        body.append(contentsOf: "cmfc".utf8)
        return box("ftyp", payload: body)
    }

    static func emsgBox(scheme: String = "urn:twitch:emsg", payload: Data = Data([0x01, 0x02, 0x03])) -> Data {
        var body = Data()
        body.append(contentsOf: scheme.utf8)
        body.append(0)
        body.append(0) // value
        appendUInt32BE(&body, 1000)
        appendUInt32BE(&body, 0)
        appendUInt32BE(&body, 0)
        appendUInt32BE(&body, 1)
        body.append(payload)
        return fullBox("emsg", version: 0, flags: 0, body: body)
    }

    static func avcCBox(sps: Data = sampleSPS, pps: Data = samplePPS, nalLengthSize: Int = 4) -> Data {
        var payload = Data()
        payload.append(1) // configurationVersion
        payload.append(sps.count > 1 ? sps[1] : 0x42)
        payload.append(sps.count > 2 ? sps[2] : 0xC0)
        payload.append(sps.count > 3 ? sps[3] : 0x1E)
        payload.append(0xFC | UInt8((nalLengthSize - 1) & 0x03))
        payload.append(0xE0 | 1) // 1 SPS
        appendUInt16BE(&payload, UInt16(sps.count))
        payload.append(sps)
        payload.append(1) // 1 PPS
        appendUInt16BE(&payload, UInt16(pps.count))
        payload.append(pps)
        return box("avcC", payload: payload)
    }

    /// Minimal ISO 14496-1 `esds` box carrying a 2-byte `AudioSpecificConfig` (default: AAC-LC 48 kHz stereo = `0x11 0x90`).
    static func esdsBox(audioSpecificConfig: Data = Data([0x11, 0x90])) -> Data {
        // DecoderSpecificInfo (tag 0x05)
        var dsi = Data([0x05, UInt8(audioSpecificConfig.count)])
        dsi.append(audioSpecificConfig)

        // DecoderConfigDescriptor (tag 0x04)
        var dcdBody = Data()
        dcdBody.append(0x40) // MPEG-4 audio
        dcdBody.append(0x15) // streamType audio
        dcdBody.append(contentsOf: [0x00, 0x00, 0x00]) // bufferSizeDB
        appendUInt32BE(&dcdBody, 160_000)
        appendUInt32BE(&dcdBody, 128_000)
        dcdBody.append(dsi)
        var dcd = Data([0x04, UInt8(dcdBody.count)])
        dcd.append(dcdBody)

        // ES_Descriptor (tag 0x03)
        var esdBody = Data()
        appendUInt16BE(&esdBody, 1) // ES_ID
        esdBody.append(0x00) // flags
        esdBody.append(dcd)
        var esd = Data([0x03, UInt8(esdBody.count)])
        esd.append(esdBody)

        return fullBox("esds", version: 0, flags: 0, body: esd)
    }

    static func videoTrackBox(
        trackID: UInt32 = 2,
        timescale: UInt32 = 1_000_000,
        codecFourCC: String = "avc1",
        nalLengthSize: Int = 4,
        includeAvcC: Bool = true
    ) -> Data {
        var tkhdBody = Data()
        appendUInt32BE(&tkhdBody, 0) // creation
        appendUInt32BE(&tkhdBody, 0) // modification
        appendUInt32BE(&tkhdBody, trackID)
        appendUInt32BE(&tkhdBody, 0) // reserved
        appendUInt32BE(&tkhdBody, 0) // duration
        let tkhd = fullBox("tkhd", version: 0, flags: 3, body: tkhdBody)

        var mdhdBody = Data()
        appendUInt32BE(&mdhdBody, 0)
        appendUInt32BE(&mdhdBody, 0)
        appendUInt32BE(&mdhdBody, timescale)
        appendUInt32BE(&mdhdBody, 0)
        let mdhd = fullBox("mdhd", version: 0, flags: 0, body: mdhdBody)

        var hdlrBody = Data()
        appendUInt32BE(&hdlrBody, 0)
        hdlrBody.append(contentsOf: "vide".utf8)
        hdlrBody.append(Data(count: 12))
        hdlrBody.append(contentsOf: "VideoHandler\0".utf8)
        let hdlr = fullBox("hdlr", version: 0, flags: 0, body: hdlrBody)

        var entryBody = Data(count: 78) // VisualSampleEntry fixed fields
        entryBody[24] = 0x07; entryBody[25] = 0x80 // width 1920
        entryBody[26] = 0x04; entryBody[27] = 0x38 // height 1080
        if includeAvcC && (codecFourCC == "avc1" || codecFourCC == "avc3") {
            entryBody.append(avcCBox(nalLengthSize: nalLengthSize))
        }
        let sampleEntry = box(codecFourCC, payload: entryBody)

        var stsdBody = Data()
        appendUInt32BE(&stsdBody, 1) // entry count
        stsdBody.append(sampleEntry)
        let stsd = fullBox("stsd", version: 0, flags: 0, body: stsdBody)

        let stbl = box("stbl", payload: stsd)
        let minf = box("minf", payload: stbl)
        let mdia = box("mdia", payload: mdhd + hdlr + minf)
        return box("trak", payload: tkhd + mdia)
    }

    static func audioTrackBox(
        trackID: UInt32 = 1,
        timescale: UInt32 = 48_000,
        channels: UInt16 = 2,
        audioSpecificConfig: Data = Data([0x11, 0x90])
    ) -> Data {
        var tkhdBody = Data()
        appendUInt32BE(&tkhdBody, 0)
        appendUInt32BE(&tkhdBody, 0)
        appendUInt32BE(&tkhdBody, trackID)
        appendUInt32BE(&tkhdBody, 0)
        appendUInt32BE(&tkhdBody, 0)
        let tkhd = fullBox("tkhd", version: 0, flags: 3, body: tkhdBody)

        var mdhdBody = Data()
        appendUInt32BE(&mdhdBody, 0)
        appendUInt32BE(&mdhdBody, 0)
        appendUInt32BE(&mdhdBody, timescale)
        appendUInt32BE(&mdhdBody, 0)
        let mdhd = fullBox("mdhd", version: 0, flags: 0, body: mdhdBody)

        var hdlrBody = Data()
        appendUInt32BE(&hdlrBody, 0)
        hdlrBody.append(contentsOf: "soun".utf8)
        hdlrBody.append(Data(count: 12))
        hdlrBody.append(contentsOf: "SoundHandler\0".utf8)
        let hdlr = fullBox("hdlr", version: 0, flags: 0, body: hdlrBody)

        var entryBody = Data(count: 28) // AudioSampleEntry fixed fields
        entryBody[16] = UInt8((channels >> 8) & 0xFF)
        entryBody[17] = UInt8(channels & 0xFF)
        entryBody[24] = UInt8((timescale >> 8) & 0xFF)
        entryBody[25] = UInt8(timescale & 0xFF)
        entryBody.append(esdsBox(audioSpecificConfig: audioSpecificConfig))
        let sampleEntry = box("mp4a", payload: entryBody)

        var stsdBody = Data()
        appendUInt32BE(&stsdBody, 1)
        stsdBody.append(sampleEntry)
        let stsd = fullBox("stsd", version: 0, flags: 0, body: stsdBody)

        let stbl = box("stbl", payload: stsd)
        let minf = box("minf", payload: stbl)
        let mdia = box("mdia", payload: mdhd + hdlr + minf)
        return box("trak", payload: tkhd + mdia)
    }

    static func trexBox(
        trackID: UInt32,
        defaultDuration: UInt32,
        defaultSize: UInt32 = 0,
        defaultFlags: UInt32 = 0
    ) -> Data {
        var body = Data()
        appendUInt32BE(&body, trackID)
        appendUInt32BE(&body, 1) // default_sample_description_index
        appendUInt32BE(&body, defaultDuration)
        appendUInt32BE(&body, defaultSize)
        appendUInt32BE(&body, defaultFlags)
        return fullBox("trex", version: 0, flags: 0, body: body)
    }

    /// Builds a Twitch-like CMAF init segment (`ftyp` + `moov` with `soun` @ 48 kHz + `vide` @ 1 MHz + `mvex`/`trex`).
    static func makeInitSegment(
        includeVideo: Bool = true,
        includeAudio: Bool = true,
        videoCodec: String = "avc1",
        videoTimescale: UInt32 = 1_000_000,
        audioTimescale: UInt32 = 48_000,
        nalLengthSize: Int = 4,
        includeAvcC: Bool = true,
        videoTrexFlags: UInt32 = 0x0240_0000 // Matches live Twitch `trex` flags!
    ) -> Data {
        var moovPayload = Data()
        var mvexPayload = Data()
        if includeAudio {
            moovPayload.append(audioTrackBox(trackID: 1, timescale: audioTimescale))
            mvexPayload.append(trexBox(trackID: 1, defaultDuration: 1024, defaultFlags: 0x0280_0000))
        }
        if includeVideo {
            moovPayload.append(videoTrackBox(
                trackID: 2,
                timescale: videoTimescale,
                codecFourCC: videoCodec,
                nalLengthSize: nalLengthSize,
                includeAvcC: includeAvcC
            ))
            mvexPayload.append(trexBox(trackID: 2, defaultDuration: 33_333, defaultFlags: videoTrexFlags))
        }
        moovPayload.append(box("mvex", payload: mvexPayload))
        return ftypBox() + box("moov", payload: moovPayload)
    }

    struct SampleSpec {
        let data: Data
        let duration: UInt32?
        let flags: UInt32?
        let cto: Int32?

        init(data: Data, duration: UInt32? = nil, flags: UInt32? = nil, cto: Int32? = nil) {
            self.data = data
            self.duration = duration
            self.flags = flags
            self.cto = cto
        }
    }

    struct TrackFragmentSpec {
        let trackID: UInt32
        let baseDecodeTime: UInt64
        let tfdtVersion: UInt8
        let trunVersion: UInt8
        let defaultDuration: UInt32?
        let defaultFlags: UInt32?
        let samples: [SampleSpec]

        init(
            trackID: UInt32,
            baseDecodeTime: UInt64,
            tfdtVersion: UInt8 = 1,
            trunVersion: UInt8 = 1,
            defaultDuration: UInt32? = nil,
            defaultFlags: UInt32? = nil,
            samples: [SampleSpec]
        ) {
            self.trackID = trackID
            self.baseDecodeTime = baseDecodeTime
            self.tfdtVersion = tfdtVersion
            self.trunVersion = trunVersion
            self.defaultDuration = defaultDuration
            self.defaultFlags = defaultFlags
            self.samples = samples
        }
    }

    /// Builds a valid `moof` + `mdat` CMAF chunk with exact `trun.data_offset` values relative to the `moof` start.
    static func makeChunk(
        sequenceNumber: UInt32,
        tracks: [TrackFragmentSpec],
        useLargeMdat: Bool = false
    ) -> Data {
        // Compute per-track payloads and offsets within mdat payload.
        var mdatPayload = Data()
        var trackMdatOffsets: [Int] = []
        for track in tracks {
            trackMdatOffsets.append(mdatPayload.count)
            for sample in track.samples {
                mdatPayload.append(sample.data)
            }
        }

        let mdatHeaderSize = useLargeMdat ? 16 : 8

        func buildMoof(moofSize: Int) -> Data {
            var mfhdBody = Data()
            appendUInt32BE(&mfhdBody, sequenceNumber)
            var moofPayload = fullBox("mfhd", version: 0, flags: 0, body: mfhdBody)

            for (idx, track) in tracks.enumerated() {
                // tfhd: default-base-is-moof (0x020000)
                var tfhdFlags: UInt32 = 0x020000
                var tfhdBody = Data()
                appendUInt32BE(&tfhdBody, track.trackID)
                if let dur = track.defaultDuration {
                    tfhdFlags |= 0x000008
                    appendUInt32BE(&tfhdBody, dur)
                }
                if let fl = track.defaultFlags {
                    tfhdFlags |= 0x000020
                    appendUInt32BE(&tfhdBody, fl)
                }
                let tfhd = fullBox("tfhd", version: 0, flags: tfhdFlags, body: tfhdBody)

                var tfdtBody = Data()
                if track.tfdtVersion == 1 {
                    appendUInt64BE(&tfdtBody, track.baseDecodeTime)
                } else {
                    appendUInt32BE(&tfdtBody, UInt32(truncatingIfNeeded: track.baseDecodeTime))
                }
                let tfdt = fullBox("tfdt", version: track.tfdtVersion, flags: 0, body: tfdtBody)

                let hasDuration = track.samples.contains { $0.duration != nil }
                let hasFlags = track.samples.contains { $0.flags != nil }
                let hasCTO = track.samples.contains { $0.cto != nil }

                var trunFlags: UInt32 = 0x000001 | 0x000200 // data-offset-present | sample-size-present
                if hasDuration { trunFlags |= 0x000100 }
                if hasFlags { trunFlags |= 0x000400 }
                if hasCTO { trunFlags |= 0x000800 }

                var trunBody = Data()
                appendUInt32BE(&trunBody, UInt32(track.samples.count))
                let dataOffset = Int32(moofSize + mdatHeaderSize + trackMdatOffsets[idx])
                appendUInt32BE(&trunBody, UInt32(bitPattern: dataOffset))
                for s in track.samples {
                    if hasDuration {
                        appendUInt32BE(&trunBody, s.duration ?? 0)
                    }
                    appendUInt32BE(&trunBody, UInt32(s.data.count))
                    if hasFlags {
                        appendUInt32BE(&trunBody, s.flags ?? 0)
                    }
                    if hasCTO {
                        appendUInt32BE(&trunBody, UInt32(bitPattern: s.cto ?? 0))
                    }
                }
                let trun = fullBox("trun", version: track.trunVersion, flags: trunFlags, body: trunBody)
                moofPayload.append(box("traf", payload: tfhd + tfdt + trun))
            }

            return box("moof", payload: moofPayload)
        }

        // First pass measures exact moof size; second pass patches data_offset accurately.
        let measured = buildMoof(moofSize: 0).count
        let moof = buildMoof(moofSize: measured)
        let mdat = box("mdat", payload: mdatPayload, useLargeSize: useLargeMdat)
        return moof + mdat
    }

    static func lengthPrefixedNALUs(_ nalus: [Data], lengthSize: Int = 4) -> Data {
        var out = Data()
        for nalu in nalus {
            switch lengthSize {
            case 1:
                out.append(UInt8(nalu.count))
            case 2:
                appendUInt16BE(&out, UInt16(nalu.count))
            default:
                appendUInt32BE(&out, UInt32(nalu.count))
            }
            out.append(nalu)
        }
        return out
    }

    /// Builds a realistic 1-second CMAF media segment (~500 ms+ buffer so `SampleBufferPipeline` starts clock immediately).
    static func makePlayableSegment(
        baseSeconds: Double,
        includeVideo: Bool = true,
        includeAudio: Bool = true,
        chunkCount: Int = 8
    ) -> Data {
        var data = emsgBox()
        let idr = lengthPrefixedNALUs([Data([0x65, 0x88, 0x84, 0x21, 0xA0])])
        let pFrame = lengthPrefixedNALUs([Data([0x41, 0x9A, 0x22, 0x33])])
        let aacFrame = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C])

        // Each chunk is ~128 ms: 6 AAC frames (6 * 1024 / 48000 = 0.128 s) + 4 video frames (4 * 32000 / 1_000_000 = 0.128 s).
        for c in 0..<chunkCount {
            var tracks: [TrackFragmentSpec] = []
            if includeAudio {
                let audioBase = UInt64((baseSeconds * 48_000).rounded()) + UInt64(c) * 6 * 1024
                let audioSamples = (0..<6).map { _ in SampleSpec(data: aacFrame, duration: 1024) }
                tracks.append(TrackFragmentSpec(trackID: 1, baseDecodeTime: audioBase, samples: audioSamples))
            }
            if includeVideo {
                let videoBase = UInt64((baseSeconds * 1_000_000).rounded()) + UInt64(c) * 4 * 32_000
                let videoSamples = (0..<4).map { idx in
                    let isIDR = (c == 0 && idx == 0)
                    return SampleSpec(
                        data: isIDR ? idr : pFrame,
                        duration: 32_000,
                        flags: isIDR ? 0x0240_0000 : 0x0141_0000
                    )
                }
                tracks.append(TrackFragmentSpec(trackID: 2, baseDecodeTime: videoBase, samples: videoSamples))
            }
            data.append(makeChunk(sequenceNumber: UInt32(c + 1), tracks: tracks))
        }
        return data
    }

    private static func appendUInt16BE(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private static func appendUInt32BE(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private static func appendUInt64BE(_ data: inout Data, _ v: UInt64) {
        appendUInt32BE(&data, UInt32((v >> 32) & 0xFFFF_FFFF))
        appendUInt32BE(&data, UInt32(v & 0xFFFF_FFFF))
    }
}

// MARK: - 1. HLS `#EXT-X-MAP` Parser Tests

struct TwitchHLSMapParserTests {
    @Test func parsesExtXMapAbsoluteRelativeByteRangeDiscontinuityAndPrefetch() throws {
        let baseURL = URL(string: "https://video-weaver.example.net/v1/playlist/chunked.m3u8")!
        let m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:500
        #EXT-X-MAP:URI="init/stream_init.mp4?dna=m1",BYTERANGE="1125@0"
        #EXTINF:2.000,live
        seg/500.mp4?dna=s0
        #EXT-X-DISCONTINUITY
        #EXTINF:2.000,Amazon|stitched-ad
        https://ads.example.net/ad/501.ts
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init2.mp4?dna=m2",BYTERANGE="720"
        #EXTINF:2.000,live
        https://cdn.example.net/s1/v1/segment/502.mp4?dna=s2
        #EXT-X-TWITCH-PREFETCH:https://cdn.example.net/s1/v1/segment/503.mp4?dna=p3
        """

        let pl = TwitchHLSParser.parseMedia(m3u8, baseURL: baseURL)
        #expect(pl.hasInitMap)
        #expect(pl.segments.count == 3)
        #expect(pl.prefetchSegments.count == 1)

        // Segment 0 inherits relative init map with explicit @0 offset.
        #expect(pl.segments[0].initMapURL == URL(string: "https://video-weaver.example.net/v1/playlist/init/stream_init.mp4?dna=m1"))
        #expect(pl.segments[0].initMapByteRange == TwitchByteRange(length: 1125, offset: 0))
        #expect(pl.segments[0].initMapByteRange?.httpRangeHeader == "bytes=0-1124")

        // Segment 1 is after #EXT-X-DISCONTINUITY without a new #EXT-X-MAP -> TS ad splice has nil initMapURL.
        #expect(pl.segments[1].isDiscontinuity)
        #expect(pl.segments[1].isAd)
        #expect(pl.segments[1].initMapURL == nil)
        #expect(pl.segments[1].initMapByteRange == nil)

        // Segment 2 has the new absolute #EXT-X-MAP with length-only BYTERANGE.
        #expect(pl.segments[2].isDiscontinuity)
        #expect(pl.segments[2].initMapURL == URL(string: "https://cdn.example.net/s1/v1/segment/init2.mp4?dna=m2"))
        #expect(pl.segments[2].initMapByteRange == TwitchByteRange(length: 720, offset: 0))
        #expect(pl.segments[2].initMapByteRange?.httpRangeHeader == "bytes=0-719")

        // Prefetch carries the active map from the end of the playlist.
        #expect(pl.prefetchSegments[0].initMapURL == pl.segments[2].initMapURL)
        #expect(pl.prefetchSegments[0].initMapByteRange == pl.segments[2].initMapByteRange)
    }

    @Test func avc3VariantCountsAsNativeCompatible() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="1080p60",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc3.64002A,mp4a.40.2",VIDEO="1080p60",FRAME-RATE=60.000
        https://video-weaver.example.net/v1/playlist/1080p60.m3u8
        """
        let variants = TwitchHLSParser.parseMaster(master)
        let v = try #require(variants.first)
        #expect(v.isNativeCompatible)
    }
}

// MARK: - 2. Incremental FMP4Demuxer Tests

struct FMP4DemuxerTests {
    @Test func demuxesMultiChunkCMAFIncrementallyAcrossArbitrarySplitsWithExact90kAVSync() throws {
        let initSeg = CMAFFixtureBuilder.makeInitSegment()
        let idr = CMAFFixtureBuilder.lengthPrefixedNALUs([Data([0x65, 0x88, 0x84, 0x21])])
        let pSlice = CMAFFixtureBuilder.lengthPrefixedNALUs([Data([0x41, 0x9A, 0x22, 0x33])])
        let aac1 = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C])
        let aac2 = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1D])

        // Start both tracks at the exact same media time (10.0 s):
        // audio @ 48 kHz -> 480_000; video @ 1 MHz -> 10_000_000 -> both rescale to 900_000 in 90 kHz!
        let chunk1 = CMAFFixtureBuilder.makeChunk(sequenceNumber: 1, tracks: [
            .init(trackID: 1, baseDecodeTime: 480_000, samples: [
                .init(data: aac1, duration: 1024),
                .init(data: aac2, duration: 1024),
            ]),
            .init(trackID: 2, baseDecodeTime: 10_000_000, samples: [
                .init(data: idr, duration: 33_333, flags: 0x0240_0000),
                .init(data: pSlice, duration: 33_333, flags: 0x0141_0000),
            ]),
        ])
        let chunk2 = CMAFFixtureBuilder.makeChunk(sequenceNumber: 2, tracks: [
            .init(trackID: 1, baseDecodeTime: 482_048, samples: [
                .init(data: aac1, duration: 1024),
            ]),
            .init(trackID: 2, baseDecodeTime: 10_066_666, samples: [
                .init(data: pSlice, duration: 33_334, flags: 0x0141_0000),
            ]),
        ])

        var demuxer = FMP4Demuxer()
        let loaded = demuxer.loadInitSegment(initSeg)
        #expect(loaded)
        #expect(demuxer.videoTrackID == 2)
        #expect(demuxer.audioTrackID == 1)
        #expect(demuxer.videoTimescale == 1_000_000)
        #expect(demuxer.audioTimescale == 48_000)
        #expect(demuxer.latestSPS == CMAFFixtureBuilder.sampleSPS)
        #expect(demuxer.latestPPS == CMAFFixtureBuilder.samplePPS)
        #expect(demuxer.audioConfig?.sampleRate == 48_000)
        #expect(demuxer.audioConfig?.channels == 2)
        #expect(demuxer.audioConfig?.audioObjectType == 2)

        // Feed leading emsg + chunk1 in awkward 7-byte slices and verify chunk1 emits BEFORE chunk2 arrives!
        let firstPart = CMAFFixtureBuilder.emsgBox() + chunk1
        var firstPartSamples: [DemuxedSample] = []
        var offset = 0
        while offset < firstPart.count {
            let end = min(firstPart.count, offset + 7)
            firstPartSamples.append(contentsOf: demuxer.push(firstPart.subdata(in: offset..<end)))
            offset = end
        }
        #expect(firstPartSamples.count == 4) // 2 audio + 2 video emitted immediately upon chunk1 completion!

        // Feed chunk2 1 byte at a time.
        var secondPartSamples: [DemuxedSample] = []
        for i in 0..<chunk2.count {
            secondPartSamples.append(contentsOf: demuxer.push(chunk2.subdata(in: i..<(i + 1))))
        }
        secondPartSamples.append(contentsOf: demuxer.flushSegment())
        #expect(secondPartSamples.count == 2) // 1 audio + 1 video

        let all = firstPartSamples + secondPartSamples
        let videos = all.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        let audios = all.compactMap { if case .audio(let a) = $0 { return a } else { return nil } }
        #expect(videos.count == 3)
        #expect(audios.count == 3)

        // Exact A/V lock on shared zero-anchored 90 kHz timeline (raw 10.0 s in both 1 MHz video & 48 kHz audio -> 0).
        #expect(videos[0].pts90k == 0)
        #expect(audios[0].pts90k == 0)
        #expect(videos[0].isKeyframe)
        #expect(!videos[1].isKeyframe)
        #expect(!videos[2].isKeyframe)
        #expect(videos[1].pts90k == 3_000) // +33.333 ms = +3000 ticks
        #expect(videos[2].pts90k == 6_000)
        #expect(audios[1].pts90k == 1_920) // +1024/48000 s = +1920 ticks

        // Verify emitted samples produce valid CoreMedia CMSampleBuffers!
        let sps = try #require(videos[0].sps)
        let pps = try #require(videos[0].pps)
        let vDesc = try #require(TwitchSampleBufferFactory.videoFormatDescription(sps: sps, pps: pps))
        let vBuf = TwitchSampleBufferFactory.videoSampleBuffer(frame: videos[0], formatDescription: vDesc)
        let aDesc = try #require(TwitchSampleBufferFactory.audioFormatDescription(
            sampleRate: audios[0].sampleRate,
            channels: audios[0].channels,
            audioObjectType: audios[0].audioObjectType,
            audioSpecificConfig: audios[0].audioSpecificConfig
        ))
        let aBuf = TwitchSampleBufferFactory.audioSampleBuffer(frame: audios[0], formatDescription: aDesc)
        #expect(vBuf != nil)
        #expect(aBuf != nil)
    }

    @Test func handlesBFrameCompositionOffsetsV1SignedAndV0Unsigned() {
        let initSeg = CMAFFixtureBuilder.makeInitSegment(includeVideo: true, includeAudio: false, videoTimescale: 90_000)
        let idr = CMAFFixtureBuilder.lengthPrefixedNALUs([Data([0x65, 0x88, 0x84])])
        let bFrame = CMAFFixtureBuilder.lengthPrefixedNALUs([Data([0x41, 0x9A, 0x01])])

        // v1 signed: negative CTO (-3000) and positive CTO (+6000)
        let v1Chunk = CMAFFixtureBuilder.makeChunk(sequenceNumber: 1, tracks: [
            .init(trackID: 2, baseDecodeTime: 90_000, trunVersion: 1, samples: [
                .init(data: idr, duration: 3000, flags: 0x0240_0000, cto: 6000),
                .init(data: bFrame, duration: 3000, flags: 0x0141_0000, cto: -3000),
            ]),
        ])
        // v0 unsigned: positive CTO (+3000)
        let v0Chunk = CMAFFixtureBuilder.makeChunk(sequenceNumber: 2, tracks: [
            .init(trackID: 2, baseDecodeTime: 96_000, trunVersion: 0, samples: [
                .init(data: bFrame, duration: 3000, flags: 0x0141_0000, cto: 3000),
            ]),
        ])

        var demuxer = FMP4Demuxer()
        let loaded = demuxer.loadInitSegment(initSeg)
        #expect(loaded)
        let samples = demuxer.push(v1Chunk + v0Chunk) + demuxer.flushSegment()
        let videos = samples.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        #expect(videos.count == 3)

        // Anchored at minRawTime = 90_000 -> DTS/PTS deltas and signed negative CTO are preserved exactly.
        #expect(videos[0].dts90k == 0 && videos[0].pts90k == 6_000)
        #expect(videos[1].dts90k == 3_000 && videos[1].pts90k == 0)
        #expect(videos[2].dts90k == 6_000 && videos[2].pts90k == 9_000)
    }

    @Test func demuxesAudioOnlyCMAFAndConvertsNon4ByteNALLengthAndInlineParameterSets() {
        // Audio-only CMAF variant (like Twitch `audio_only`)
        let audioInit = CMAFFixtureBuilder.makeInitSegment(includeVideo: false, includeAudio: true)
        let audioChunk = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 5.0, includeVideo: false, includeAudio: true, chunkCount: 2)
        var audioDemuxer = FMP4Demuxer()
        let audioLoaded = audioDemuxer.loadInitSegment(audioInit)
        #expect(audioLoaded)
        #expect(audioDemuxer.videoTrackID == nil)
        #expect(audioDemuxer.audioTrackID == 1)
        let audioSamples = audioDemuxer.push(audioChunk) + audioDemuxer.flushSegment()
        #expect(audioSamples.count == 12)
        #expect(audioSamples.allSatisfy { if case .audio = $0 { return true } else { return false } })

        // 2-byte nalLengthSize (`avc3` with inline SPS/PPS + AUD + IDR) -> converted to 4-byte AVCC, AUD stripped
        let avc3Init = CMAFFixtureBuilder.makeInitSegment(
            includeVideo: true,
            includeAudio: false,
            videoCodec: "avc3",
            nalLengthSize: 2,
            includeAvcC: true
        )
        let aud = Data([0x09, 0x10])
        let idr = Data([0x65, 0x88, 0x84, 0x21, 0xFF])
        let pSlice = Data([0x41, 0x9A, 0x11, 0x22])
        let sample1 = CMAFFixtureBuilder.lengthPrefixedNALUs([aud, CMAFFixtureBuilder.sampleSPS, CMAFFixtureBuilder.samplePPS, idr], lengthSize: 2)
        let sample2 = CMAFFixtureBuilder.lengthPrefixedNALUs([pSlice], lengthSize: 2)

        // Note: omit per-sample flags so `trex`'s default `0x02400000` is in play — verify P-frame is NOT falsely marked keyframe!
        let chunk = CMAFFixtureBuilder.makeChunk(sequenceNumber: 1, tracks: [
            .init(trackID: 2, baseDecodeTime: 1_000_000, samples: [
                .init(data: sample1, duration: 33_333, flags: nil),
                .init(data: sample2, duration: 33_333, flags: nil),
            ]),
        ], useLargeMdat: true) // Also exercises 64-bit largesize box!

        var videoDemuxer = FMP4Demuxer()
        let videoLoaded = videoDemuxer.loadInitSegment(avc3Init)
        #expect(videoLoaded)
        #expect(videoDemuxer.nalLengthSize == 2)
        let out = videoDemuxer.push(chunk) + videoDemuxer.flushSegment()
        let videos = out.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        #expect(videos.count == 2)
        #expect(videos[0].isKeyframe)
        #expect(!videos[1].isKeyframe)
        #expect(videos[0].sps == CMAFFixtureBuilder.sampleSPS)
        #expect(videos[0].pps == CMAFFixtureBuilder.samplePPS)

        // Verify 4-byte AVCC output containing only the IDR slice (AUD/SPS/PPS stripped)
        var expectedAVCC = Data([0x00, 0x00, 0x00, UInt8(idr.count)])
        expectedAVCC.append(idr)
        #expect(videos[0].avccData == expectedAVCC)
    }

    @Test func detectsUnsupportedCodecsAndRebasesAcrossDiscontinuityAndTSHandoff() {
        // HEVC init segment reports "hevc"
        var hevcDemuxer = FMP4Demuxer()
        let hevcInit = CMAFFixtureBuilder.makeInitSegment(includeVideo: true, includeAudio: true, videoCodec: "hvc1", includeAvcC: false)
        _ = hevcDemuxer.loadInitSegment(hevcInit)
        #expect(hevcDemuxer.unsupportedVideoCodec == "hevc")

        // AV1 init segment reports "av1"
        var av1Demuxer = FMP4Demuxer()
        let av1Init = CMAFFixtureBuilder.makeInitSegment(includeVideo: true, includeAudio: false, videoCodec: "av01", includeAvcC: false)
        _ = av1Demuxer.loadInitSegment(av1Init)
        #expect(av1Demuxer.unsupportedVideoCodec == "av1")

        // Discontinuity rebasing: raw PTS jumps backward to 0, continuous timeline advances smoothly past highestContinuousPTS
        var fmp4 = FMP4Demuxer()
        let fmp4Loaded = fmp4.loadInitSegment(CMAFFixtureBuilder.makeInitSegment())
        #expect(fmp4Loaded)
        let seg1 = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 100.0, chunkCount: 2)
        _ = fmp4.push(seg1) + fmp4.flushSegment()
        let peakBefore = fmp4.highestContinuousPTS
        #expect(peakBefore >= 20_000)

        _ = fmp4.beginDiscontinuity()
        let segAfterReset = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 0.0, chunkCount: 1)
        let postSamples = fmp4.push(segAfterReset) + fmp4.flushSegment()
        let firstPostPTS = postSamples.map { sample -> Int64 in
            switch sample {
            case .video(let v): v.pts90k
            case .audio(let a): a.pts90k
            }
        }.min() ?? 0
        #expect(firstPostPTS > peakBefore)

        // Seamless fMP4 -> MPEG-TS handoff via `rebaseTimeline(after:)`
        let peakFMP4 = fmp4.highestContinuousPTS
        var ts = MPEGTSDemuxer()
        ts.rebaseTimeline(after: peakFMP4)
        let tsSeg = MPEGTSDemuxerTests.makeSyntheticSegment(basePTS: 90_000, includeKeyframe: true)
        let tsSamples = ts.push(tsSeg) + ts.flushSegment()
        #expect(!tsSamples.isEmpty)
        let firstTSPTS = tsSamples.map { sample -> Int64 in
            switch sample {
            case .video(let v): v.pts90k
            case .audio(let a): a.pts90k
            }
        }.min() ?? 0
        #expect(firstTSPTS > peakFMP4)

        // Overflow-free rescaleTo90k on huge 64-bit values (e.g. > 100 days at 1 MHz)
        let bigUS: Int64 = 10_000_000_000_000 // 10_000_000 s
        #expect(FMP4Demuxer.rescaleTo90k(bigUS, timescale: 1_000_000) == 900_000_000_000)
    }
}

// MARK: - 3. TwitchNativeEngine End-to-End CMAF Integration Tests

struct TwitchNativeEngineCMAFTests {
    private actor EventRecorder {
        private var events: [TwitchNativeEvent] = []
        private var waiters: [(UUID, @Sendable (TwitchNativeEvent) -> Bool, CheckedContinuation<TwitchNativeEvent?, Never>)] = []

        func record(_ event: TwitchNativeEvent) {
            events.append(event)
            var remaining: [(UUID, @Sendable (TwitchNativeEvent) -> Bool, CheckedContinuation<TwitchNativeEvent?, Never>)] = []
            for entry in waiters {
                if entry.1(event) {
                    entry.2.resume(returning: event)
                } else {
                    remaining.append(entry)
                }
            }
            waiters = remaining
        }

        func snapshot() -> [TwitchNativeEvent] { events }

        func waitFor(
            timeout: Duration,
            matching predicate: @escaping @Sendable (TwitchNativeEvent) -> Bool
        ) async -> TwitchNativeEvent? {
            if let existing = events.first(where: predicate) { return existing }
            let id = UUID()
            return await withCheckedContinuation { cont in
                waiters.append((id, predicate, cont))
                Task {
                    try? await Task.sleep(for: timeout)
                    self.expire(id: id)
                }
            }
        }

        private func expire(id: UUID) {
            if let idx = waiters.firstIndex(where: { $0.0 == id }) {
                let entry = waiters.remove(at: idx)
                entry.2.resume(returning: nil)
            }
        }
    }

    private actor Counter {
        private var n = 0
        func increment() -> Int { n += 1; return n }
        func current() -> Int { n }
    }

    private final class NoopAudioBackend: AudioSessionBackend, @unchecked Sendable {
        func setAmbientCategory() {}
        func setPlaybackCategoryAndActivate() {}
        func deactivateToAmbient(notifyOthers: Bool) {}
    }

    private static let sampleMaster = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.000
    https://video-weaver.example.net/v1/playlist/chunked.m3u8
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="720p60",NAME="720p60",AUTOSELECT=YES,DEFAULT=NO
    #EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1280x720,CODECS="avc1.4D401F,mp4a.40.2",VIDEO="720p60",FRAME-RATE=60.000
    https://video-weaver.example.net/v1/playlist/720p60.m3u8
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="audio_only",NAME="audio_only",AUTOSELECT=NO,DEFAULT=NO
    #EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",VIDEO="audio_only"
    https://video-weaver.example.net/v1/playlist/audio_only.m3u8
    """

    private static func makeResolver(
        master: String = sampleMaster,
        mediaPlaylist: @escaping @Sendable (URL) async -> String
    ) -> TwitchStreamResolver {
        TwitchStreamResolver { req in
            let url = req.url ?? URL(string: "https://example.invalid")!
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.host() == "gql.twitch.tv" {
                let json = #"{"data":{"streamPlaybackAccessToken":{"value":"{\"channel\":\"capy\"}","signature":"sig123"}}}"#
                return (Data(json.utf8), resp)
            }
            if url.host() == "usher.ttvnw.net" {
                return (Data(master.utf8), resp)
            }
            let body = await mediaPlaylist(url)
            return (Data(body.utf8), resp)
        }
    }

    @Test func cmafLowLatencyPrefetchStreamPlaysAndCachesInitSegmentAcrossRotatingDNA() async throws {
        let recorder = EventRecorder()
        let initFetches = Counter()
        let pollCounter = Counter()
        let initSeg = CMAFFixtureBuilder.makeInitSegment()
        let coord = AudioSessionCoordinator(backend: NoopAudioBackend(), observeSystemNotifications: false)

        let resolver = Self.makeResolver { _ in
            let poll = await pollCounter.increment()
            let seq = 1000 + poll
            // Rotating `?dna=...` on the init segment URL just like live Twitch CMAF playlists!
            return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:\(seq)
            #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init_1080p.mp4?dna=rot\(poll)"
            #EXTINF:2.000,live
            https://cdn.example.net/s1/v1/segment/\(seq).mp4?dna=seg\(poll)
            #EXT-X-TWITCH-PREFETCH:https://cdn.example.net/s1/v1/segment/\(seq + 1).mp4?dna=pf\(poll)
            """
        }

        let engine = TwitchNativeEngine(
            resolver: resolver,
            startupTimeout: .seconds(5),
            segmentStreamer: { url in
                AsyncThrowingStream { cont in
                    Task {
                        if url.path().contains("init_1080p.mp4") {
                            _ = await initFetches.increment()
                            cont.yield(initSeg)
                            cont.finish()
                        } else {
                            // Stream in small chunks to simulate chunked CMAF prefetch delivery.
                            let seg = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 10.0)
                            let mid = seg.count / 2
                            cont.yield(seg.subdata(in: 0..<mid))
                            cont.yield(seg.subdata(in: mid..<seg.count))
                            cont.finish()
                        }
                    }
                }
            },
            audioSession: coord
        )

        await engine.setEventHandler { event in
            Task { await recorder.record(event) }
        }
        await engine.start(channel: "capy", authToken: nil)

        let playing = await recorder.waitFor(timeout: .seconds(3)) { $0 == .playing }
        let diag = await engine.diagnosticData(reason: nil)
        await engine.stop()

        #expect(playing == .playing)
        // Init segment was fetched only once despite rotating `?dna=...` query string.
        #expect(await initFetches.current() == 1)
        #expect(diag["container"] == .string("fmp4"))
        #expect(diag["hasMap"] == .bool(true))
        if case .int(let samples) = diag["samples"] { #expect(samples > 0) } else { Issue.record("missing samples") }
        if case .int(let kf) = diag["keyframes"] { #expect(kf >= 1) } else { Issue.record("missing keyframes") }
    }

    @Test func cmafAudioOnlyVariantPlaysWithoutVideoTrack() async {
        let recorder = EventRecorder()
        let audioInit = CMAFFixtureBuilder.makeInitSegment(includeVideo: false, includeAudio: true)
        let audioSeg = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 2.0, includeVideo: false, includeAudio: true)
        let coord = AudioSessionCoordinator(backend: NoopAudioBackend(), observeSystemNotifications: false)

        let resolver = Self.makeResolver { _ in
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:200
            #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init_audio.mp4?dna=a1"
            #EXTINF:2.000,live
            https://cdn.example.net/s1/v1/segment/200.mp4?dna=s1
            #EXT-X-TWITCH-PREFETCH:https://cdn.example.net/s1/v1/segment/201.mp4?dna=p1
            """
        }

        let engine = TwitchNativeEngine(
            resolver: resolver,
            startupTimeout: .seconds(5),
            segmentStreamer: { url in
                AsyncThrowingStream { cont in
                    cont.yield(url.path().contains("init_audio.mp4") ? audioInit : audioSeg)
                    cont.finish()
                }
            },
            audioSession: coord
        )

        await engine.setEventHandler { event in
            Task { await recorder.record(event) }
        }
        await engine.start(channel: "capy", authToken: nil, preferredVariantID: "audio_only")

        let playing = await recorder.waitFor(timeout: .seconds(3)) { $0 == .playing }
        await engine.stop()
        #expect(playing == .playing)
    }

    @Test func cmafToMpegTSDiscontinuitySpliceContinuesWithoutError() async {
        let recorder = EventRecorder()
        let initSeg = CMAFFixtureBuilder.makeInitSegment()
        let cmafSeg1 = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 20.0, chunkCount: 8)
        let tsAdSeg = MPEGTSDemuxerTests.makeSyntheticSegment(basePTS: 90_000, includeKeyframe: true)
        let cmafSeg2 = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 24.0, chunkCount: 8)
        let pollCounter = Counter()
        let tsFetched = Counter()
        let postAdCmafFetched = Counter()
        let coord = AudioSessionCoordinator(backend: NoopAudioBackend(), observeSystemNotifications: false)

        let resolver = Self.makeResolver { _ in
            let poll = await pollCounter.increment()
            if poll == 1 {
                return """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:300
                #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init.mp4"
                #EXTINF:1.000,live
                https://cdn.example.net/s1/v1/segment/300.mp4
                """
            } else if poll == 2 {
                return """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:300
                #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init.mp4"
                #EXTINF:1.000,live
                https://cdn.example.net/s1/v1/segment/300.mp4
                #EXT-X-DISCONTINUITY
                #EXTINF:1.000,Amazon|stitched-ad
                https://ads.example.net/ad/301.ts
                """
            } else {
                return """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:300
                #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init.mp4"
                #EXTINF:1.000,live
                https://cdn.example.net/s1/v1/segment/300.mp4
                #EXT-X-DISCONTINUITY
                #EXTINF:1.000,Amazon|stitched-ad
                https://ads.example.net/ad/301.ts
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init.mp4"
                #EXTINF:1.000,live
                https://cdn.example.net/s1/v1/segment/302.mp4
                """
            }
        }

        let engine = TwitchNativeEngine(
            resolver: resolver,
            startupTimeout: .seconds(5),
            segmentStreamer: { url in
                AsyncThrowingStream { cont in
                    Task {
                        if url.path().contains("init.mp4") {
                            cont.yield(initSeg)
                        } else if url.path().contains("300.mp4") {
                            cont.yield(cmafSeg1)
                        } else if url.path().contains("301.ts") {
                            _ = await tsFetched.increment()
                            cont.yield(tsAdSeg)
                        } else {
                            _ = await postAdCmafFetched.increment()
                            cont.yield(cmafSeg2)
                        }
                        cont.finish()
                    }
                }
            },
            audioSession: coord
        )

        await engine.setEventHandler { event in
            Task { await recorder.record(event) }
        }
        await engine.start(channel: "capy", authToken: nil)

        let playing = await recorder.waitFor(timeout: .seconds(3)) { $0 == .playing }
        // Wait for the playlist to step through the MPEG-TS ad and back to CMAF.
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await postAdCmafFetched.current() >= 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let tsCount = await tsFetched.current()
        let postAdCount = await postAdCmafFetched.current()
        let events = await recorder.snapshot()
        await engine.stop()

        #expect(playing == .playing)
        #expect(tsCount >= 1)
        #expect(postAdCount >= 1)
        #expect(!events.contains(where: { if case .failed = $0 { return true } else { return false } }))
    }

    @Test func selectVariantIsIdempotentWhenAlreadyActiveOrLoading() async {
        let recorder = EventRecorder()
        let playlistFetches = Counter()
        let initSeg = CMAFFixtureBuilder.makeInitSegment()
        let cmafSeg = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 1.0)
        let coord = AudioSessionCoordinator(backend: NoopAudioBackend(), observeSystemNotifications: false)

        let resolver = Self.makeResolver { _ in
            _ = await playlistFetches.increment()
            return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:400
            #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/init.mp4"
            #EXTINF:2.000,live
            https://cdn.example.net/s1/v1/segment/400.mp4
            """
        }

        let engine = TwitchNativeEngine(
            resolver: resolver,
            startupTimeout: .seconds(5),
            segmentStreamer: { url in
                AsyncThrowingStream { cont in
                    cont.yield(url.path().contains("init.mp4") ? initSeg : cmafSeg)
                    cont.finish()
                }
            },
            audioSession: coord
        )

        await engine.setEventHandler { event in
            Task { await recorder.record(event) }
        }
        await engine.start(channel: "capy", authToken: nil)
        let playing = await recorder.waitFor(timeout: .seconds(3)) { $0 == .playing }
        #expect(playing == .playing)

        let loadingBefore = (await recorder.snapshot()).filter { $0 == .loading }.count
        // Re-selecting the already-active "chunked" variant must be a no-op (no restart / no extra .loading).
        await engine.selectVariant(id: "chunked")
        try? await Task.sleep(for: .milliseconds(80))
        let loadingAfterSame = (await recorder.snapshot()).filter { $0 == .loading }.count
        #expect(loadingAfterSame == loadingBefore)

        // Selecting a *different* variant ("720p60") still triggers a real switch.
        await engine.selectVariant(id: "720p60")
        let switched = await recorder.waitFor(timeout: .seconds(1)) { event in
            if case .variants(_, let selectedID) = event { return selectedID == "720p60" }
            return false
        }
        try? await Task.sleep(for: .milliseconds(30))
        let loadingAfterSwitch = (await recorder.snapshot()).filter { $0 == .loading }.count
        #expect(switched != nil)
        #expect(loadingAfterSwitch == loadingBefore + 1)

        await engine.stop()
    }

    @Test func unsupportedHEVCCMAFFailsFastAndDiagnosticDataHasNoPII() async {
        let recorder = EventRecorder()
        let hevcInit = CMAFFixtureBuilder.makeInitSegment(includeVideo: true, includeAudio: true, videoCodec: "hvc1", includeAvcC: false)
        let seg = CMAFFixtureBuilder.makePlayableSegment(baseSeconds: 1.0)
        let coord = AudioSessionCoordinator(backend: NoopAudioBackend(), observeSystemNotifications: false)

        let resolver = Self.makeResolver { _ in
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:600
            #EXT-X-MAP:URI="https://cdn.example.net/s1/v1/segment/hevc_init.mp4"
            #EXTINF:2.000,live
            https://cdn.example.net/s1/v1/segment/600.mp4
            """
        }

        let engine = TwitchNativeEngine(
            resolver: resolver,
            startupTimeout: .seconds(5),
            segmentStreamer: { url in
                AsyncThrowingStream { cont in
                    cont.yield(url.path().contains("hevc_init.mp4") ? hevcInit : seg)
                    cont.finish()
                }
            },
            audioSession: coord
        )

        await engine.setEventHandler { event in
            Task { await recorder.record(event) }
        }
        await engine.start(channel: "secret_channel_name", authToken: "secret_token_xyz")

        let failed = await recorder.waitFor(timeout: .seconds(3)) {
            if case .failed = $0 { return true }
            return false
        }
        let diag = await engine.diagnosticData(reason: "unsupported codec: hevc")
        await engine.stop()

        #expect(failed == .failed("unsupported codec: hevc"))
        #expect(diag["hasMap"] == .bool(true))
        #expect(diag["variant"] == .string("chunked"))
        #expect(diag["reason"] == .string("unsupported codec: hevc"))

        // Verify zero PII (no channel login, auth token, or URLs) in diagnostic telemetry metadata.
        let allowedKeys: Set<String> = [
            "container", "hasMap", "samples", "keyframes", "segments", "variant", "reason",
            "slot", "phase", "playlist_polls", "init_map_ok", "init_map_ms",
            "prefetch_fallback", "low_latency", "is_prefetch", "is_ad", "elapsed_ms",
        ]
        #expect(Set(diag.keys).isSubset(of: allowedKeys))
        for (_, value) in diag {
            if case .string(let s) = value {
                #expect(!s.contains("secret_channel_name"))
                #expect(!s.contains("secret_token_xyz"))
                #expect(!s.contains("https://"))
            }
        }
    }
}
