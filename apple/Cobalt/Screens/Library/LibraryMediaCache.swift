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
    static let memoryCapacity = 24 * 1024 * 1024

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cache = URLCache(
            memoryCapacity: LibraryMediaCache.memoryCapacity, diskCapacity: 200 * 1024 * 1024,
            directory: caches.appendingPathComponent("cobalt-library-media", isDirectory: true))
        config.urlCache = cache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        purgesMemory(of: cache)
        return URLSession(configuration: config)
    }()

    /// The app leaving the screen or a memory warning empties the cache's memory copy only: its capacity goes to zero and
    /// back (`removeAllCachedResponses` would delete the 200 MB on disk too, and every webp would be fetched again).
    private static func purgesMemory(of cache: URLCache) {
        // URLCache is thread safe; it is only resized here
        nonisolated(unsafe) let cache = cache
        Task { @MainActor in
            PurgeHook.register { _ in
                cache.memoryCapacity = 0
                cache.memoryCapacity = LibraryMediaCache.memoryCapacity
            }
        }
    }

    /// `-previewMediaDir /some/folder` (DEBUG) reads the public media from a local folder instead of the
    /// network, so the simulator evidence run shows real posters without the server. A name the folder lacks
    /// is a failing picture (the failed tile's evidence).
    static func resolve(_ url: URL) -> URL {
        #if DEBUG
        if !url.isFileURL, let dir = UserDefaults.standard.string(forKey: "previewMediaDir"), !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(url.lastPathComponent, isDirectory: false)
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

/// The library's view of the app's one picture cache (`MediaPipeline.memory`, 8.17): the same keys as every other still,
/// so a poster decoded for the orbit or a detail sheet is found here too. Thread safe, so a tile can look a picture up
/// synchronously in its first frame (no grey flash when it scrolls back).
final class LibraryPictureCache: Sendable {
    static let shared = LibraryPictureCache()

    private static func key(_ source: LibraryPictureSource, _ maxPixel: Int) -> String {
        let kind: String
        switch source {
        case .file: kind = "f"
        case .image: kind = "i"
        case .videoFrame: kind = "v"
        }
        return MediaPipeline.key(kind, source.url, maxPixel: maxPixel)
    }

    func image(_ source: LibraryPictureSource, maxPixel: Int) -> ImageBox? {
        MediaPipeline.memory.image(forKey: Self.key(source, maxPixel))
    }

    /// The first of `chain` the cache already holds.
    func first(in chain: [LibraryPictureSource], maxPixel: Int) -> ImageBox? {
        for source in chain { if let hit = image(source, maxPixel: maxPixel) { return hit } }
        return nil
    }

    /// Common decoded long-side buckets, largest first, for instant fallback before an exact-size decode finishes.
    private static let fallbackBuckets = [1024, 768, 704, 640, 576, 512, 448, 384, 320, 256, 192, 160, 128]

    /// The first of `chain` the cache already holds at `maxPixel`, else the sharpest cached size already in memory.
    /// `exact` is true only when the hit is at `maxPixel` (so a fallback still upgrades to `maxPixel` off the main thread).
    func best(in chain: [LibraryPictureSource], maxPixel: Int) -> (box: ImageBox, exact: Bool)? {
        if let hit = first(in: chain, maxPixel: maxPixel) { return (hit, true) }
        for size in Self.fallbackBuckets where size != maxPixel {
            if let hit = first(in: chain, maxPixel: size) { return (hit, false) }
        }
        return nil
    }

    func store(_ box: ImageBox, _ source: LibraryPictureSource, maxPixel: Int) {
        MediaPipeline.memory.store(box, forKey: Self.key(source, maxPixel))
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
    private var prefetches: [Key: Task<Void, Never>] = [:]
    private let gate = LoadGate(limit: 6)
    private let prefetchGate = LoadGate(limit: 2)

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

    /// Warms upcoming mosaic thumbnails at low priority without competing with visible tiles.
    /// Decodes only the first source of each chain (skipping video frames which are heavier to seek).
    func prefetch(_ requests: [(source: LibraryPictureSource, maxPixel: Int)]) {
        let cache = LibraryPictureCache.shared
        for req in requests {
            if case .videoFrame = req.source { continue }
            if cache.image(req.source, maxPixel: req.maxPixel) != nil { continue }
            let key = Key(source: req.source, maxPixel: req.maxPixel)
            guard flights[key] == nil, prefetches[key] == nil else { continue }
            // cap queued prefetch work so a rapid fling never builds a backlog
            if prefetches.count >= 12 { break }
            let gate = self.prefetchGate
            prefetches[key] = Task.detached(priority: .utility) { [weak self] in
                await gate.enter()
                let box = Task.isCancelled ? nil : await Self.decode(req.source, maxPixel: req.maxPixel)
                await gate.leave()
                if let box { cache.store(box, req.source, maxPixel: req.maxPixel) }
                await self?.finishPrefetch(key)
            }
        }
    }

    private func finishPrefetch(_ key: Key) {
        prefetches[key] = nil
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
            return MediaPipeline.still(file: url, maxPixel: maxPixel)
        case .image(let url):
            guard let data = try? await LibraryMediaCache.data(from: url), !Task.isCancelled else { return nil }
            return MediaPipeline.still(data: data, maxPixel: maxPixel)
        case .videoFrame(let url):
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: LibraryMediaCache.resolve(url)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
            // the generator's frame may still be lazily backed: draw it here, not on the first frame it is shown
            return ImageBox(MediaPipeline.shrink(image, maxPixel: maxPixel))
        }
    }
}
