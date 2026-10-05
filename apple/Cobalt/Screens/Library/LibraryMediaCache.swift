import AVFoundation
import CobaltKit
import Foundation
import ImageIO

// The library's pictures (CONTRACT-LIBRARY2 decision 12): thumbnails decoded off the main thread, cached in
// memory (bounded by decoded bytes) and, for the network, on disk through a `URLCache` of 200 MB (public
// media is immutable). Nothing here touches the main actor: a view asks, awaits, and shows what comes back.

/// Where a picture can come from.
enum LibraryPictureSource: Hashable, Sendable {
    /// This device's poster: a file on disk.
    case file(URL)
    /// A still on the network, or the first frame of a public webp.
    case image(URL)
    /// A frame from the start of a hosted mp4.
    case videoFrame(URL)

    var url: URL {
        switch self {
        case .file(let url), .image(let url), .videoFrame(let url): return url
        }
    }
}

/// The library's `URLSession`: a disk cache of 200 MB (a public webp is fetched once, for its first frame and
/// again for the animation), and `-previewMediaDir` (DEBUG) to read public media from a local folder.
enum LibraryMediaCache {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        config.urlCache = URLCache(
            memoryCapacity: 24 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024,
            directory: caches.appendingPathComponent("cobalt-library-media", isDirectory: true))
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `-previewMediaDir /some/folder` (DEBUG) reads the public media from a local folder instead of the
    /// network, so the simulator evidence run shows real posters without the server. A name the folder lacks
    /// is a failing picture (the failed tile's evidence).
    static func resolve(_ url: URL) -> URL {
        #if DEBUG
        if !url.isFileURL, let dir = UserDefaults.standard.string(forKey: "previewMediaDir"), !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent)
        }
        #endif
        return url
    }

    /// The bytes of a public file (a still, a webp); throws on any HTTP error. Runs off the main actor.
    static func data(from url: URL) async throws -> Data {
        let url = resolve(url)
        if url.isFileURL { return try Data(contentsOf: url, options: .mappedIfSafe) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Decoded pictures, bounded by bytes (about 64 MB) and count (300). Thread safe, so a tile can look a
/// picture up synchronously in its first frame (no grey flash when it scrolls back).
final class LibraryPictureCache: @unchecked Sendable {
    static let shared = LibraryPictureCache()

    private final class Holder: Sendable {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    private let cache: NSCache<NSString, Holder> = {
        let c = NSCache<NSString, Holder>()
        c.countLimit = 300
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private static func key(_ source: LibraryPictureSource, _ maxPixel: Int) -> NSString {
        let kind: String
        switch source {
        case .file: kind = "f"
        case .image: kind = "i"
        case .videoFrame: kind = "v"
        }
        return "\(kind)|\(maxPixel)|\(source.url.absoluteString)" as NSString
    }

    func image(_ source: LibraryPictureSource, maxPixel: Int) -> ImageBox? {
        cache.object(forKey: Self.key(source, maxPixel))?.box
    }

    /// The first of `chain` the cache already holds.
    func first(in chain: [LibraryPictureSource], maxPixel: Int) -> ImageBox? {
        for source in chain { if let hit = image(source, maxPixel: maxPixel) { return hit } }
        return nil
    }

    func store(_ box: ImageBox, _ source: LibraryPictureSource, maxPixel: Int) {
        cache.setObject(Holder(box), forKey: Self.key(source, maxPixel), cost: max(1, box.image.bytesPerRow * box.image.height))
    }
}

/// At most `limit` pictures load at a time; the rest wait their turn.
private actor LoadGate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { free = limit }

    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Loads one picture per (source, size) at a time, off the main thread, six at once, and drops a load nobody
/// waits for any more (a tile that scrolled away before its picture came).
actor LibraryPictureLoader {
    static let shared = LibraryPictureLoader()

    private struct Key: Hashable, Sendable {
        let source: LibraryPictureSource
        let maxPixel: Int
    }

    private struct Flight {
        let id = UUID()
        let task: Task<ImageBox?, Never>
        var waiters: Int
    }

    private var flights: [Key: Flight] = [:]
    private let gate = LoadGate(limit: 6)

    /// The picture, or nil when it failed to load or the caller was cancelled.
    func picture(_ source: LibraryPictureSource, maxPixel: Int) async -> ImageBox? {
        let cache = LibraryPictureCache.shared
        if let hit = cache.image(source, maxPixel: maxPixel) { return hit }
        let key = Key(source: source, maxPixel: maxPixel)
        let flight: Flight
        if var running = flights[key] {
            running.waiters += 1
            flights[key] = running
            flight = running
        } else {
            let gate = self.gate
            let task = Task.detached(priority: .userInitiated) { () -> ImageBox? in
                await gate.enter()
                let box = Task.isCancelled ? nil : await Self.decode(source, maxPixel: maxPixel)
                await gate.leave()
                return box
            }
            flight = Flight(task: task, waiters: 1)
            flights[key] = flight
        }
        let task = flight.task
        let flightID = flight.id
        let box = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.waiterLeft(key, flight: flightID) }
        }
        if flights[key]?.id == flightID { flights[key] = nil }
        if let box { cache.store(box, source, maxPixel: maxPixel) }
        return box
    }

    private func waiterLeft(_ key: Key, flight id: UUID) {
        guard var flight = flights[key], flight.id == id else { return }
        flight.waiters -= 1
        if flight.waiters <= 0 {
            flight.task.cancel()
            flights[key] = nil
        } else {
            flights[key] = flight
        }
    }

    // MARK: decoding (off the actor)

    private static func decode(_ source: LibraryPictureSource, maxPixel: Int) async -> ImageBox? {
        switch source {
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return thumbnail(of: source, maxPixel: maxPixel)
        case .image(let url):
            guard let data = try? await LibraryMediaCache.data(from: url), !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return thumbnail(of: source, maxPixel: maxPixel)
        case .videoFrame(let url):
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: LibraryMediaCache.resolve(url)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
            return ImageBox(image)
        }
    }

    /// The first frame (an animated webp's too), at most `maxPixel` on its long side.
    private static func thumbnail(of source: CGImageSource, maxPixel: Int) -> ImageBox? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ImageBox.init)
    }
}
