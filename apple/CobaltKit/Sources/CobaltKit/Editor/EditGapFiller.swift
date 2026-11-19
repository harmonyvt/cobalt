@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// A tiny black clip that holds the main track open where nothing real plays.
///
/// AVFoundation drops empty edits at the end of a track, and a track made only of empty edits has no length. So a missing last
/// main clip was cut off the preview, and a timeline whose main clips are all missing built a composition of 0 s, which plays
/// nothing. The tail of the main track is filled with this clip, stretched to fit. The compositor draws the "missing" checker
/// for those spans and never asks the track for their frames, so the black is not seen there.
actor EditGapFiller {
    static let shared = EditGapFiller()

    private var made: URL?

    /// The filler's file, written once per run into the temporary folder.
    func url() async throws -> URL {
        if let made, FileManager.default.fileExists(atPath: made.path) { return made }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt-edit-gap-\(UUID().uuidString).mov")
        try await Self.write(to: url)
        made = url
        return url
    }

    /// Stretches the filler over `range` of `track`.
    static func fill(_ track: AVMutableCompositionTrack, _ range: CMTimeRange) async throws {
        guard range.duration.isNumeric, range.duration.seconds > 0 else { return }
        let asset = AVURLAsset(url: try await shared.url())
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.other("gap") }
        let sourceRange = try await source.load(.timeRange)
        try track.insertTimeRange(sourceRange, of: source, at: range.start)
        track.scaleTimeRange(CMTimeRange(start: range.start, duration: sourceRange.duration), toDuration: range.duration)
    }

    private static let side = 64

    private static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        guard writer.canAdd(input) else { throw EditError.other("gap") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditError.other("gap") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? EditError.other("gap") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw EditError.other("gap") }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw EditError.other("gap")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)) else {
                throw writer.error ?? EditError.other("gap")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError.other("gap") }
    }
}
