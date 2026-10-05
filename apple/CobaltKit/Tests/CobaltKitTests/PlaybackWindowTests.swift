import AVFoundation
import Foundation
import Testing
@testable import CobaltKit

/// The detail's hero must play the WHOLE clip. The owner's report (1.8 build 9): a 64.6 s clip looped about 5 s in
/// the detail. Cause: the detail took the orbit's player, whose `AVPlayerLooper` loops only the first seconds
/// (`PlaybackWindow.orbitSeconds`), and played the clip on it. These tests hold the two rules that fix it.
@Suite("Playback window") struct PlaybackWindowTests {
    // MARK: the orbit's window

    @Test func orbitWindowIsTheFirstSecondsOfALongClip() {
        #expect(PlaybackWindow.orbitLoopSeconds(duration: 64.6) == 3)
        #expect(PlaybackWindow.orbitLoopSeconds(duration: nil) == 3)
        #expect(PlaybackWindow.orbitLoopSeconds(duration: 1.2) == 1.2)
        #expect(PlaybackWindow.orbitLoopSeconds(duration: 0.1) == 0.5)
    }

    @Test func aLongClipOnTheOrbitDoesNotLoopWhole() {
        // the detail must not play on such a player
        #expect(!PlaybackWindow.orbitLoopsWholeClip(duration: 64.6))
        #expect(!PlaybackWindow.orbitLoopsWholeClip(duration: 3.5))
        #expect(!PlaybackWindow.orbitLoopsWholeClip(duration: nil))
        #expect(!PlaybackWindow.orbitLoopsWholeClip(duration: 0))
    }

    @Test func aShortClipOnTheOrbitLoopsWhole() {
        #expect(PlaybackWindow.orbitLoopsWholeClip(duration: 3))
        #expect(PlaybackWindow.orbitLoopsWholeClip(duration: 2.1))
        #expect(PlaybackWindow.orbitLoopsWholeClip(duration: 3.04))
    }

    // MARK: the picture-only item

    @MainActor @Test func pictureOnlyItemSpansTheWholeClip() async throws {
        let url = try await Self.clipWithSound(seconds: 64.6)
        let source = AVURLAsset(url: url)
        let full = try await source.load(.duration).seconds
        #expect(abs(full - 64.6) < 0.5)
        // the file has sound, so the item is the composition holding only the picture
        let item = await HeroItems.pictureOnly(url)
        let composition = try #require(item.asset as? AVComposition)
        #expect(composition.tracks(withMediaType: .audio).isEmpty)
        #expect(composition.tracks(withMediaType: .video).count == 1)
        let length = try await composition.load(.duration).seconds
        #expect(abs(length - full) < 0.5, "picture-only item is \(length) s, the clip is \(full) s")
        // nothing caps the item's playback either
        #expect(!item.forwardPlaybackEndTime.isNumeric)
        let track = try #require(composition.tracks(withMediaType: .video).first)
        let span = try await track.load(.timeRange)
        #expect(abs(span.duration.seconds - full) < 0.5)
    }

    @MainActor @Test func aClipWithoutSoundPlaysAsItIs() async throws {
        let url = try await TestVideo.clip(seconds: 6)
        let item = await HeroItems.pictureOnly(url)
        #expect(item.asset is AVURLAsset)
    }

    // MARK: fixture

    private static func clipWithSound(seconds: Double) async throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("long-with-sound.mp4")
        try await writeClip(at: url, seconds: seconds)
        return url
    }

    /// A small H.264 + AAC (silence) mp4 `seconds` long.
    private static func writeClip(at url: URL, seconds: Double) async throws {
        let fps = 5, width = 96, height = 160, rate = 44100.0
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate, AVEncoderBitRateKey: 64000,
        ], sourceFormatHint: formatDescription)
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? TestVideo.Failure(message: "startWriting") }
        writer.startSession(atSourceTime: .zero)

        // Feed whichever input is ready (a writer holds each back until the other keeps pace).
        let frames = Int(seconds * Double(fps))
        let seconds = Int(seconds.rounded(.up))
        let perSecond = Int(rate)
        let bytes = perSecond * 2
        var frame = 0, chunk = 0
        while frame < frames || chunk < seconds {
            var fed = false
            if frame < frames, video.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                guard let buffer else { throw TestVideo.Failure(message: "pixel buffer") }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                    throw writer.error ?? TestVideo.Failure(message: "append \(frame)")
                }
                frame += 1
                fed = true
            }
            if chunk < seconds, audio.isReadyForMoreMediaData {
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard let block, let formatDescription else { throw TestVideo.Failure(message: "audio block") }
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription, sampleCount: perSecond,
                    presentationTimeStamp: CMTime(value: Int64(chunk), timescale: 1), packetDescriptions: nil, sampleBufferOut: &sample)
                guard let sample, audio.append(sample) else { throw writer.error ?? TestVideo.Failure(message: "audio append") }
                chunk += 1
                fed = true
            }
            if writer.status == .failed { throw writer.error ?? TestVideo.Failure(message: "writer failed") }
            if !fed { try await Task.sleep(for: .milliseconds(2)) }
        }
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestVideo.Failure(message: "finish") }
    }
}
