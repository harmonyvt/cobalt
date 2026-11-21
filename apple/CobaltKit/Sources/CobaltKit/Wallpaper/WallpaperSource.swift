@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The frames a wallpaper is made from: a video (AVFoundation), an animated webp or gif (ImageIO), or one picture.
/// Recognised by what the file holds, never by its name (a gif can arrive as `.mp4`, see `MediaSniff`).
public final class WallpaperSource: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case video
        case animated
        case picture
    }

    public let kind: Kind
    /// Seconds; 0 for a picture.
    public let duration: Double
    /// The picture's size as shown (a video's track size after its rotation).
    public let size: CGSize

    private let asset: AVURLAsset?
    private let images: CGImageSource?
    /// For an animated picture: when each frame starts, in seconds.
    private let starts: [Double]

    private init(kind: Kind, duration: Double, size: CGSize, asset: AVURLAsset?, images: CGImageSource?, starts: [Double]) {
        self.kind = kind
        self.duration = duration
        self.size = size
        self.asset = asset
        self.images = images
        self.starts = starts
    }

    /// Opens a file on disk. Throws `WallpaperError.unreadable` for anything else.
    public static func open(_ url: URL) async throws -> WallpaperSource {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source) as String?,
           let uti = UTType(type), uti.conforms(to: .image) {
            let n = CGImageSourceGetCount(source)
            guard n > 0, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                throw WallpaperError.unreadable
            }
            let size = pictureSize(props)
            if n == 1 {
                return WallpaperSource(kind: .picture, duration: 0, size: size, asset: nil, images: source, starts: [0])
            }
            var starts: [Double] = []
            var t = 0.0
            for i in 0..<n {
                starts.append(t)
                t += frameDelay(source, i)
            }
            return WallpaperSource(kind: .animated, duration: t, size: size, asset: nil, images: source, starts: starts)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw WallpaperError.unreadable }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform).size
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw WallpaperError.unreadable }
        return WallpaperSource(kind: .video, duration: duration,
                               size: CGSize(width: abs(shown.width), height: abs(shown.height)),
                               asset: asset, images: nil, starts: [])
    }

    /// The frame shown at `time` seconds, its longest side at most `maxSide` pixels.
    public func image(at time: Double, maxSide: CGFloat = WallpaperLimits.maxSide) async throws -> CGImage {
        try await frames(at: [time], maxSide: maxSide)[0]
    }

    /// The frames shown at each of `times`, in order.
    public func frames(at times: [Double], maxSide: CGFloat = WallpaperLimits.maxSide) async throws -> [CGImage] {
        switch kind {
        case .picture, .animated:
            guard let images else { throw WallpaperError.unreadable }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
            ]
            var cache: [Int: CGImage] = [:]
            return try times.map { time in
                let index = frameIndex(at: time)
                if let hit = cache[index] { return hit }
                guard let image = CGImageSourceCreateThumbnailAtIndex(images, index, opts as CFDictionary) else {
                    throw WallpaperError.unreadable
                }
                cache[index] = image
                return image
            }
        case .video:
            guard let asset else { throw WallpaperError.unreadable }
            let maker = self.generator(asset, maxSide: maxSide)
            var out: [CGImage] = []
            out.reserveCapacity(times.count)
            for time in times {
                let at = CMTime(seconds: min(max(0, time), max(0, duration - 0.01)), preferredTimescale: 600)
                out.append(try await maker.image(at: at).image)
            }
            return out
        }
    }

    /// One generator per size, kept: a make asks for 90 frames in a row.
    private var generators: [CGFloat: AVAssetImageGenerator] = [:]
    private let lock = NSLock()

    private func generator(_ asset: AVURLAsset, maxSide: CGFloat) -> AVAssetImageGenerator {
        lock.lock()
        defer { lock.unlock() }
        if let kept = generators[maxSide] { return kept }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generators[maxSide] = generator
        return generator
    }

    private func frameIndex(at time: Double) -> Int {
        guard kind == .animated, duration > 0 else { return 0 }
        let t = time.truncatingRemainder(dividingBy: duration)
        var lo = 0
        for (i, s) in starts.enumerated() where s <= t { lo = i }
        return lo
    }

    private static func pictureSize(_ props: [CFString: Any]) -> CGSize {
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// A frame's delay from the gif or webp dictionary (unclamped first, as browsers do; under 20 ms means 100 ms).
    private static func frameDelay(_ source: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [[CFString: Any]?] = [
            props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
            props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
        ]
        for dict in dicts.compactMap({ $0 }) {
            let keys: [CFString] = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                                    kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime,
                                    kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime]
            for key in keys {
                if let d = (dict[key] as? NSNumber)?.doubleValue, d > 0 { return d < 0.02 ? 0.1 : d }
            }
        }
        return 0.1
    }
}
