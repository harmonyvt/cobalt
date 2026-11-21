import SwiftUI
import UIKit
import ImageIO

/// Tile pictures for the keyboard. The extension dies near 70 MB, so a tile never decodes more than its own
/// pixels: the file goes to a temp file (not into memory), ImageIO reads the first frame only at tile size,
/// and a small cache keeps the last few. `AsyncImage` decoded every frame of an animated webp at full size.
actor KeyboardThumbLoader {
    static let shared = KeyboardThumbLoader()

    /// Decoded tiles, 8 MB at most. Cost is the decoded bytes, not the file size. NSCache is thread safe,
    /// so the view controller can empty it from its memory warning without awaiting the actor.
    // NSCache is documented thread safe; it is not marked Sendable, hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// No disk cache, no cookies: the bytes are read once and dropped.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// Largest file a tile will download. A tile that points at something bigger stays a placeholder.
    private static let byteCap: Int64 = 12_000_000

    nonisolated static func purge() { cache.removeAllObjects() }

    nonisolated static func cached(_ url: URL, pixels: Int) -> UIImage? {
        cache.object(forKey: key(url, pixels))
    }

    private nonisolated static func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(url.absoluteString)#\(pixels)" as NSString
    }

    /// The first frame of `url`, at most `pixels` on its long side. Nil when it can't be read.
    func thumbnail(_ url: URL, pixels: Int) async -> UIImage? {
        if let hit = Self.cached(url, pixels: pixels) { return hit }
        do {
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            if size > Self.byteCap { return nil }
            guard let image = Self.decode(file, pixels: pixels) else { return nil }
            try Task.checkCancellation()
            let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            Self.cache.setObject(image, forKey: Self.key(url, pixels), cost: cost)
            return image
        } catch {
            return nil
        }
    }

    /// Frame 0 only, scaled while decoding, so the full-size bitmap never exists.
    private nonisolated static func decode(_ file: URL, pixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixels, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// One tile picture. `.task(id:)` cancels the load when the tile scrolls away or its url changes.
struct KeyboardThumb: View {
    let url: URL
    /// Longest tile side in points; the decode is this times the screen scale.
    var points: CGFloat = 130

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    private var pixels: Int { Int((points * scale).rounded(.up)) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: url) {
            image = KeyboardThumbLoader.cached(url, pixels: pixels)
            guard image == nil else { return }
            image = await KeyboardThumbLoader.shared.thumbnail(url, pixels: pixels)
        }
    }
}
