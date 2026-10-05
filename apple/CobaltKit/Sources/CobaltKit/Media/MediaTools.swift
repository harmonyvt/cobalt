import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Where the filmstrip reads its frames from.
enum FrameInput: Sendable, Equatable {
    case remote(URL)      // `GET /studio/<sid>/source` (Range)
    case local(URL)
}

/// Everything the pipeline and the stores need from AVFoundation / ImageIO, behind one seam so
/// previews and tests can run without decoding a real video.
protocol MediaTools: Sendable {
    /// Duration and pixel size of a local video; nil when it is not a video.
    func probe(file: URL) async -> MediaInfo?
    /// Pixel size (and, when animated, the total duration) of a local image file; nil when it is
    /// not an image ImageIO can read.
    func imageInfo(file: URL) -> MediaInfo?
    /// `count` frames spread over the clip, each yielded as it is developed, in index order.
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error>
    /// The same with the frames' long edge capped at `maxEdge` pixels (the share extension asks for
    /// small ones: it has ~120 MB). The default ignores the cap.
    func frames(of input: FrameInput, duration: Double?, count: Int, maxEdge: CGFloat) -> AsyncThrowingStream<Frame, Error>
    /// A JPEG (360 px long edge) written to `destination`; false when none could be made.
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool
    /// Up to `count` small frames (long edge <= `maxEdge`) spread evenly over a local video, or over
    /// the decoded frames of an animated image when `animatedImage`; in order. Empty when the file
    /// has no such frames (a still image, an unreadable file).
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage]
    /// AVFoundation cannot open a GIF, so every player and frame reader in the app would fail on one:
    /// writes an mp4 of its frames to `destination` and returns true. False when `file` is not a GIF
    /// (nothing is written) or the conversion failed; the caller then keeps the file it has.
    func playableCopy(of file: URL, to destination: URL) async -> Bool
}

extension MediaTools {
    func playableCopy(of file: URL, to destination: URL) async -> Bool { false }
    func frames(of input: FrameInput, duration: Double?, count: Int, maxEdge: CGFloat) -> AsyncThrowingStream<Frame, Error> {
        frames(of: input, duration: duration, count: count)
    }
    func imageInfo(file: URL) -> MediaInfo? { nil }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] { [] }
}

enum PosterSize { static let longEdge: CGFloat = 360 }

/// The orbit's flipbook: how many frames, how small, how compressed.
enum PreviewSize {
    static let frameCount = 12
    static let longEdge: CGFloat = 160
    static let quality = 0.6

    /// JPEG bytes of a flipbook frame, scaled down first when its long edge is above `longEdge`.
    static func jpeg(_ image: CGImage) -> Data? {
        var image = image
        let longest = CGFloat(max(image.width, image.height))
        if longest > longEdge, let small = scaled(image, by: longEdge / longest) { image = small }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * factor).rounded(.down)))
        let h = max(1, Int((CGFloat(image.height) * factor).rounded(.down)))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

enum MediaError: Error, Sendable {
    case unreadable, noFrames
    /// The remote file is a GIF: AVFoundation will never open it, so retrying is pointless.
    case animatedImage
}

/// The real implementation. Memory-conscious on purpose (the share extension has ~120 MB):
/// frames come from `AVAssetImageGenerator` capped at 360 pt, never a whole-video decode.
struct SystemMediaTools: MediaTools {
    // MARK: Opening assets

    /// MIME types tried, in order, when AVFoundation cannot tell what an extension-less URL is
    /// (`GET /studio/<sid>/source` has no file extension; the server's `content-type` normally
    /// settles it, the override is the fallback of CONTRACT section 10).
    static let mimeFallbacks: [String?] = [nil, "video/mp4", "video/quicktime"]

    /// Seconds waited before each further round of `openAsset` (a first request right after "ready"
    /// can meet an object that is not servable yet, or a cold edge; the second round usually works).
    static let openRetryDelays: [Double] = [0.6, 1.8]

    /// An asset that has a playable video track, or the error that stopped the last round.
    /// A failed round is repeated after a short wait (`openRetryDelays`): only cancellation and a
    /// local file's failure are final.
    static func openAsset(_ url: URL) async throws -> AVURLAsset {
        var lastError: Error = MediaError.unreadable
        for delay in [0.0] + (url.isFileURL ? [] : openRetryDelays) {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            do { return try await openAssetOnce(url) }
            catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
            // A GIF stored as a video (an old server labelled one `video/mp4`) never opens: say so at once
            // instead of retrying it.
            if delay == 0, url.isFileURL ? MediaSniff.isGIF(file: url) : await MediaSniff.isGIF(remote: url) {
                throw MediaError.animatedImage
            }
        }
        throw lastError
    }

    private static func openAssetOnce(_ url: URL) async throws -> AVURLAsset {
        var lastError: Error = MediaError.unreadable
        for mime in mimeFallbacks {
            try Task.checkCancellation()
            let asset: AVURLAsset
            if let mime {
                asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
            } else {
                asset = AVURLAsset(url: url)
            }
            do {
                guard try await asset.load(.isPlayable) else { continue }
                if try await asset.loadTracks(withMediaType: .video).isEmpty { continue }
                return asset
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func generator(for asset: AVAsset, tolerance: CMTime, maxEdge: CGFloat = PosterSize.longEdge) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    // MARK: Probing

    func probe(file: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize)
        else { return Self.probeGIF(file) }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let size = natural.applying(transform)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        return MediaInfo(
            name: file.deletingPathExtension().lastPathComponent, duration: duration.seconds,
            width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()),
            bytes: bytes, isImage: false)
    }

    /// A GIF is a clip, not a still: its length is the sum of its frame delays, `isImage` stays false.
    static func probeGIF(_ file: URL) -> MediaInfo? {
        guard let timeline = GIFTimeline(file: file), timeline.duration > 0 else { return nil }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
        return MediaInfo(
            name: file.deletingPathExtension().lastPathComponent, duration: timeline.duration,
            width: timeline.width, height: timeline.height, bytes: bytes, isImage: false)
    }

    func playableCopy(of file: URL, to destination: URL) async -> Bool {
        guard MediaSniff.isGIF(file: file) else { return false }
        do {
            try await GIFTranscoder.writeMP4(from: file, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// ImageIO: pixel size from the first frame (orientation applied), and for an animated image
    /// (gif, apng, animated webp) the sum of its frame delays as `duration`.
    func imageInfo(file: URL) -> MediaInfo? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)        // EXIF orientations 5...8 are quarter turns
        }
        var duration: Double?
        if count > 1 {
            var total = 0.0
            for i in 0..<count {
                guard let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] else { continue }
                total += Self.frameDelay(p)
            }
            duration = total > 0 ? total : nil
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
        return MediaInfo(
            name: file.deletingPathExtension().lastPathComponent, duration: duration, width: width, height: height,
            bytes: bytes, isImage: true)
    }

    /// Seconds one frame of an animated image is shown (unclamped value first, like browsers).
    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (container, unclamped, clamped) in containers {
            guard let dict = props[container] as? [CFString: Any] else { continue }
            if let v = (dict[unclamped] as? NSNumber)?.doubleValue, v > 0 { return v }
            if let v = (dict[clamped] as? NSNumber)?.doubleValue, v > 0 { return v }
        }
        return 0
    }

    // MARK: Filmstrip

    /// `count` frames at the middle of each of `count` equal slices, yielded **in index order**
    /// as they are developed. A frame that cannot be decoded is skipped; none at all is an error.
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        frames(of: input, duration: duration, count: count, maxEdge: PosterSize.longEdge)
    }

    func frames(of input: FrameInput, duration: Double?, count: Int, maxEdge: CGFloat) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url: URL
                    switch input {
                    case .remote(let u), .local(let u): url = u
                    }
                    // A GIF is read with ImageIO (a remote one is fetched whole first: it is small, and
                    // ImageIO cannot read ranges).
                    if url.isFileURL, let gif = GIFTimeline(file: url) {
                        for frame in gif.filmstrip(count: count, maxEdge: maxEdge) { continuation.yield(frame) }
                        continuation.finish()
                        return
                    }
                    let asset: AVURLAsset
                    do { asset = try await Self.openAsset(url) } catch MediaError.animatedImage {
                        let local = try await Self.fetchWhole(url)
                        defer { try? FileManager.default.removeItem(at: local) }
                        guard let gif = GIFTimeline(file: local) else { throw MediaError.noFrames }
                        let frames = gif.filmstrip(count: count, maxEdge: maxEdge)
                        if frames.isEmpty { throw MediaError.noFrames }
                        for frame in frames { continuation.yield(frame) }
                        continuation.finish()
                        return
                    }
                    // The clip's own length wins over the caller's: a stated duration longer than the
                    // media (a short gif-converted mp4) would ask for frames past the last one.
                    let total = await Self.playableDuration(of: asset, hint: duration)
                    guard total.isFinite, total > 0, count > 0 else { continuation.finish(); return }
                    // Half a slice either side: the generator may pick a nearby key frame (fast
                    // over the network) but the nine frames still come from nine places.
                    let slice = total / Double(count)
                    let generator = Self.generator(
                        for: asset, tolerance: CMTime(seconds: slice / 2, preferredTimescale: 600), maxEdge: maxEdge)
                    defer { generator.cancelAllCGImageGeneration() }
                    let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * slice, preferredTimescale: 600) }

                    var arrived: [Int: CGImage?] = [:]
                    var next = 0
                    var yielded = 0
                    for await result in generator.images(for: times) {
                        try Task.checkCancellation()
                        let index = times.firstIndex { CMTimeCompare($0, result.requestedTime) == 0 } ?? next
                        arrived[index] = try? result.image
                        while next < count, let slot = arrived[next] {
                            if let image = slot {
                                continuation.yield(Frame(index: next, image: image))
                                yielded += 1
                            }
                            arrived[next] = nil
                            next += 1
                        }
                    }
                    try Task.checkCancellation()
                    if yielded == 0 {
                        // The generator could not seek this file (fragmented, odd timescale, one
                        // frame): read it front to back instead.
                        let wanted = times.map(\.seconds)
                        let images = await Self.sequentialImages(of: asset, at: wanted, maxEdge: maxEdge)
                        for (i, image) in images.enumerated() {
                            if let image { continuation.yield(Frame(index: i, image: image)); yielded += 1 }
                        }
                    }
                    try Task.checkCancellation()
                    if yielded == 0 { throw MediaError.noFrames }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The most a remote GIF fetched for its frames may weigh.
    static let remoteGIFLimit: Int64 = 64 * 1024 * 1024

    /// A remote file saved to a temporary file (`GET /studio/<sid>/source` needs no key). Refuses a
    /// file over `remoteGIFLimit`.
    static func fetchWhole(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            throw MediaError.unreadable
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: temp.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= remoteGIFLimit else { throw MediaError.unreadable }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID().uuidString.prefix(8))")
        try FileManager.default.moveItem(at: temp, to: keep)
        return keep
    }

    // MARK: Posters

    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        if isImage || UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true || MediaSniff.isGIF(file: file) {
            guard let image = Self.thumbnail(of: file) else { return false }
            return Self.writeJPEG(image, to: destination)
        }
        return await poster(of: .local(file), to: destination)
    }

    /// A poster from a local video or from a (range-readable) remote one.
    func poster(of input: FrameInput, to destination: URL) async -> Bool {
        let url: URL
        switch input {
        case .remote(let u), .local(let u): url = u
        }
        guard let asset = try? await Self.openAsset(url), let image = await Self.posterImage(of: asset) else { return false }
        return Self.writeJPEG(image, to: destination)
    }

    /// A frame near the start of the clip. Short clips are the trap: 10 % of a 1.2 s gif is 0.12 s,
    /// which a one-frame or oddly timed file may not have, so the time is clamped inside the media,
    /// then tried again at 0, with any nearby frame allowed and then exactly, and last by reading
    /// the file from the start and taking the first frame that decodes.
    static func posterImage(of asset: AVURLAsset) async -> CGImage? {
        let total = await playableDuration(of: asset, hint: nil)
        let frame = await frameDuration(of: asset)
        var seconds: [Double] = []
        if total > 0 { seconds.append(max(0, min(min(total * 0.1, 1.0), total - frame))) }
        seconds.append(0)
        for tolerance in [CMTime.positiveInfinity, CMTime.zero] {
            let generator = generator(for: asset, tolerance: tolerance)
            defer { generator.cancelAllCGImageGeneration() }
            for t in seconds {
                if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { return image }
            }
        }
        return await sequentialImages(of: asset, at: [0], maxEdge: PosterSize.longEdge).first ?? nil
    }

    /// First frame of any ImageIO image (an animated webp or gif included), 360 px long edge.
    static func thumbnail(of file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PosterSize.longEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Flipbook frames

    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        guard count > 0 else { return [] }
        if animatedImage || MediaSniff.isGIF(file: file) { return Self.animatedFrames(of: file, count: count, maxEdge: maxEdge) }
        guard let asset = try? await Self.openAsset(file) else { return [] }
        let total = await Self.playableDuration(of: asset, hint: nil)
        guard total.isFinite, total > 0 else { return [] }
        let slice = total / Double(count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        generator.requestedTimeToleranceBefore = CMTime(seconds: slice / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: slice / 2, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * slice, preferredTimescale: 600) }
        var arrived: [Int: CGImage] = [:]
        for await result in generator.images(for: times) {
            if Task.isCancelled { return [] }
            guard let index = times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 }),
                  let image = try? result.image else { continue }
            arrived[index] = image
        }
        if arrived.count >= min(2, count) { return arrived.keys.sorted().compactMap { arrived[$0] } }
        // Too few frames to flip through: read the file front to back instead.
        let read = await Self.sequentialImages(of: asset, at: times.map(\.seconds), maxEdge: maxEdge)
        return read.compactMap { $0 }
    }

    /// `count` of the decoded frames of an animated image, evenly spaced by index (all of them
    /// when it has fewer); empty for a still image.
    static func animatedFrames(of file: URL, count: Int, maxEdge: CGFloat) -> [CGImage] {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return [] }
        let n = CGImageSourceGetCount(source)
        guard n > 1 else { return [] }
        let k = min(count, n)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        var out: [CGImage] = []
        for i in 0..<k {
            if let image = CGImageSourceCreateThumbnailAtIndex(source, i * n / k, options as CFDictionary) { out.append(image) }
        }
        return out
    }

    // MARK: Real duration and sequential reads

    /// The shortest positive length among the asset's duration, its video track's time range and the
    /// caller's hint: the time up to which a frame is certain to exist. 0 when none is known.
    static func playableDuration(of asset: AVAsset, hint: Double?) async -> Double {
        var lengths: [Double] = []
        func keep(_ v: Double?) { if let v, v.isFinite, v > 0 { lengths.append(v) } }
        keep(try? await asset.load(.duration).seconds)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let range = try? await track.load(.timeRange), range.isValid {
            keep(range.duration.seconds)
        }
        keep(hint)
        return lengths.min() ?? 0
    }

    /// One frame's length (1/30 s when the track does not say), the margin kept before the end.
    static func frameDuration(of asset: AVAsset) async -> Double {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate), rate >= 1 else { return 1.0 / 30 }
        return 1.0 / Double(rate)
    }

    /// The longest clip the front-to-back fallback will decode (it reads every sample up to the last
    /// target; the generator path is the one for long videos).
    static let sequentialLimit = 120.0

    /// For each time in `times` (ascending), the last frame at or before it (the first frame when
    /// none is), decoded by reading the video track front to back with `AVAssetReader`: no seeking, so
    /// it works where `AVAssetImageGenerator` cannot place a time. Orientation applied, long edge
    /// capped at `maxEdge`. `nil` for a time that produced nothing.
    static func sequentialImages(of asset: AVAsset, at times: [Double], maxEdge: CGFloat) async -> [CGImage?] {
        var out = [CGImage?](repeating: nil, count: times.count)
        guard !times.isEmpty,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return out }
        if let d = try? await asset.load(.duration).seconds, d.isFinite, d > sequentialLimit { return out }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return out }
        reader.add(output)
        guard reader.startReading() else { return out }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let context = CIContext()
        func render(_ sample: CMSampleBuffer) -> CGImage? {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
            let oriented = CIImage(cvPixelBuffer: buffer).oriented(orientation(of: transform))
            guard let full = context.createCGImage(oriented, from: oriented.extent) else { return nil }
            let longest = CGFloat(max(full.width, full.height))
            return longest > maxEdge ? (PreviewSize.scaled(full, by: maxEdge / longest) ?? full) : full
        }

        var previous: CMSampleBuffer?
        var next = 0
        while next < times.count, let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { return out }
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let held = previous {
                // the held frame is the last one at or before every target that lies before this one
                while next < times.count, times[next] < pts { out[next] = render(held); next += 1 }
            }
            previous = sample
        }
        if let held = previous {
            while next < times.count { out[next] = render(held); next += 1 }
        }
        return out
    }

    /// The EXIF-style orientation a track's `preferredTransform` stands for (quarter turns only).
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (Int(t.a.rounded()), Int(t.b.rounded()), Int(t.c.rounded()), Int(t.d.rounded())) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
