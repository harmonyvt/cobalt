import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Makes Lock Screen wallpapers from a `WallpaperSource`: the frames of the chosen range (at most 3 s), drawn with the
/// depth look, written as a Live Photo that ends on its last frame (the still the Lock Screen holds). A picture makes a
/// still. A Duo pair cuts every frame into a left and a right half with the hinge's width taken out of the middle.
public final class WallpaperMaker: @unchecked Sendable {
    public let source: WallpaperSource
    private let renderer = WallpaperRenderer()
    private let folder: URL

    public init(source: WallpaperSource, folder: URL = FileManager.default.temporaryDirectory) {
        self.source = source
        self.folder = folder
    }

    /// The range a make uses: `start` clamped into the source, `length` into 1...3 s and the source's end.
    public func range(start: Double, length: Double) -> (start: Double, length: Double) {
        guard source.kind != .picture else { return (0, 0) }
        let len = min(max(length, min(WallpaperLimits.minClip, source.duration)), WallpaperLimits.maxClip, source.duration)
        let s = min(max(0, start), max(0, source.duration - len))
        return (s, len)
    }

    /// The frame times of a range at `fps`, ending exactly on the range's last frame.
    public static func times(start: Double, length: Double, fps: Double = WallpaperLimits.fps) -> [Double] {
        guard length > 0 else { return [start] }
        let n = max(2, Int((length * fps).rounded()))
        return (0..<n).map { start + Double($0) * length / Double(n - 1) }
    }

    // MARK: preview

    /// What the editor shows for one frame: the picture with the look, and its depth map.
    public struct Preview: @unchecked Sendable {
        public let picture: CGImage
        public let depth: CGImage
        public let size: CGSize
    }

    /// One frame the editor works on, with Vision's subject mask for it (nil: no subject found).
    public struct Frame: @unchecked Sendable {
        public let image: CGImage
        public let found: CIImage?
        public var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    /// The frame at `time`, scaled for the screen, and its subject mask.
    public func previewFrame(at time: Double, maxSide: CGFloat = 1200) async throws -> Frame {
        let image = try await source.image(at: time, maxSide: maxSide)
        return Frame(image: image, found: renderer.subjectMask(image))
    }

    public func preview(_ frame: Frame, look: WallpaperLook, phase: Double = 0) -> Preview? {
        let base = CIImage(cgImage: frame.image)
        let mask = renderer.finalMask(found: frame.found, look: look, extent: base.extent)
        let picture = renderer.compose(base, mask: mask, look: look, phase: phase)
        guard let p = renderer.cgImage(picture), let d = renderer.cgImage(renderer.depthMap(mask: mask, extent: base.extent))
        else { return nil }
        return Preview(picture: p, depth: d, size: base.extent.size)
    }

    // MARK: make

    /// Writes the wallpaper's files: one for the Lock Screen, two (left, right) for a Duo pair. `progress` runs 0...1.
    public func make(
        start: Double, length: Double, look: WallpaperLook, target: WallpaperTarget,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [WallpaperFiles] {
        let halves: [Half] = target == .duoPair ? [.left, .right] : [.whole]
        if source.kind == .picture {
            let image = try await source.image(at: 0)
            let base = CIImage(cgImage: image)
            let mask = renderer.finalMask(found: look.findsSubject ? renderer.subjectMask(image) : nil, look: look,
                                          extent: base.extent)
            let drawn = renderer.compose(base, mask: mask, look: look, phase: 0)
            var out: [WallpaperFiles] = []
            for half in halves {
                let cut = half.crop(drawn)
                guard let still = renderer.cgImage(cut) else { throw WallpaperError.writeFailed }
                let url = folder.appendingPathComponent("wallpaper-\(UUID().uuidString).heic")
                try LivePhotoWriter.writeStill(still, identifier: nil, to: url)
                out.append(WallpaperFiles(still: url, video: nil))
            }
            progress(1)
            return out
        }

        let r = range(start: start, length: length)
        let times = Self.times(start: r.start, length: r.length)
        let needsMask = !look.isPlain
        var movies: [(half: Half, movie: LivePhotoMovie, files: WallpaperFiles, identifier: String)] = []
        var last: CIImage?
        do {
            for (i, time) in times.enumerated() {
                try Task.checkCancellation()
                let image = try await source.image(at: time)
                let base = CIImage(cgImage: image)
                var frame = base
                if needsMask {
                    // the subject moves: Vision runs on every frame
                    let found = look.findsSubject ? renderer.subjectMask(image) : nil
                    let mask = renderer.finalMask(found: found, look: look, extent: base.extent)
                    frame = renderer.compose(base, mask: mask, look: look, phase: Double(i) / Double(max(1, times.count - 1)))
                }
                if movies.isEmpty {
                    for half in halves {
                        let identifier = UUID().uuidString
                        let size = Self.even(half.crop(frame).extent.size)
                        let files = WallpaperFiles(
                            still: folder.appendingPathComponent("wallpaper-\(identifier).heic"),
                            video: folder.appendingPathComponent("wallpaper-\(identifier).mov"))
                        let movie = try await LivePhotoMovie(
                            url: files.video!, size: size, fps: WallpaperLimits.fps, stillIndex: times.count - 1,
                            identifier: identifier)
                        movies.append((half, movie, files, identifier))
                    }
                }
                for entry in movies {
                    let cut = entry.half.crop(frame)
                    let placed = cut.transformed(by: CGAffineTransform(translationX: -cut.extent.minX, y: -cut.extent.minY))
                        .cropped(to: CGRect(origin: .zero, size: entry.movie.size))
                    try await entry.movie.append { renderer.render(placed, into: $0) }
                }
                last = frame
                progress(0.95 * Double(i + 1) / Double(times.count))
            }
            var out: [WallpaperFiles] = []
            for entry in movies {
                try await entry.movie.finish()
                guard let last, let still = renderer.cgImage(entry.half.crop(last)) else { throw WallpaperError.writeFailed }
                try LivePhotoWriter.writeStill(still, identifier: entry.identifier, to: entry.files.still)
                out.append(entry.files)
            }
            progress(1)
            return out
        } catch {
            for entry in movies {
                entry.movie.cancel()
                entry.files.remove()
            }
            throw error
        }
    }

    /// Video encoders want even sides.
    static func even(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, floor(size.width / 2) * 2), height: max(2, floor(size.height / 2) * 2))
    }

    /// Which part of the frame a file holds.
    enum Half {
        case whole, left, right

        func crop(_ image: CIImage) -> CIImage {
            let e = image.extent
            switch self {
            case .whole: return image
            case .left, .right:
                let gap = e.width * WallpaperLimits.hingeShare
                let w = (e.width - gap) / 2
                let x = self == .left ? e.minX : e.maxX - w
                return image.cropped(to: CGRect(x: x, y: e.minY, width: w, height: e.height).integral)
            }
        }
    }
}
