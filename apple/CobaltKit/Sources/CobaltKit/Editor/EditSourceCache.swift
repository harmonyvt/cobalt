import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

// Sources on the device (apple/CONTRACT-EDITOR.md 3.4): the preview plays local files, so every library file a timeline names
// is fetched once into Caches/editor/<id>.<ext> (or taken from the offline store's copy when it is kept on this device) and kept
// there; the least recently used files go past 2 GB. A GIF is decoded once with ImageIO, a photo once with its orientation applied.

public actor EditSourceCache {
    /// The most the cache keeps on disk.
    public static let limitBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    private let directory: URL
    private let client: @Sendable @MainActor () -> any CobaltClient
    private let provider: (@Sendable @MainActor (String) async -> URL?)?
    private var local: [String: URL] = [:]
    private var progresses: [String: Double] = [:]
    private var fetching: [String: Task<URL, Error>] = [:]
    private var decoded: [String: EditSourceAsset] = [:]
    /// Library file id -> the decoded video's length in seconds (what `measure` answers; kept when `dropDecoded` drops the rest).
    private var lengths: [String: Double] = [:]
    private var shifting: [EditPitchKey: Task<URL, Error>] = [:]

    /// - Parameters:
    ///   - directory: where the downloads live (`Caches/editor` in the app; a temp folder in tests).
    ///   - client: the app's current client, read on every download.
    ///   - provider: a file already on the device for a library file id (previews and tests; the app registers kept originals with
    ///     `register(local:for:)` instead).
    public init(
        directory: URL, client: @escaping @Sendable @MainActor () -> any CobaltClient,
        provider: (@Sendable @MainActor (String) async -> URL?)? = nil
    ) {
        self.directory = directory
        self.client = client
        self.provider = provider
    }

    /// The default place for the downloads: `Caches/editor`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("editor", isDirectory: true)
    }

    /// The offline store keeps this library file on the device: use that copy, download nothing.
    public func register(local url: URL, for id: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        local[id] = url
    }

    /// 0...1 while the file downloads; nil when it is not downloading.
    public func progress(for id: String) -> Double? { progresses[id] }

    /// Stops every download in flight.
    public func cancelAll() {
        for task in fetching.values { task.cancel() }
        fetching = [:]
        progresses = [:]
        for task in shifting.values { task.cancel() }
        shifting = [:]
    }

    /// The decoded file for a library file: a local copy first, else a download. Throws `EditError` (`.offline` with no network,
    /// `.notFound` for a file the server no longer has, `.other` for a file that cannot be read).
    public func asset(for source: EditSource) async throws -> EditSourceAsset {
        guard source.available, source.kind != .unsupported else { throw EditError.other("unsupported") }
        if let cached = decoded[source.id] { return cached }
        let url = try await file(for: source)
        let (asset, length) = try await Self.decode(url, source: source)
        decoded[source.id] = asset
        if let length { lengths[source.id] = length }
        return asset
    }

    /// A library video whose length (or size) the server does not know: uploads have none in `media_items`, a few saves too.
    /// The file is fetched as `asset(for:)` fetches it (the device's copy first: a registered local file or the provider; else
    /// the download into this folder, kept for the preview), decoded once, and read: its length in seconds and its display size
    /// (the track's natural size with its preferred transform applied; `source.display` when the source already has one).
    /// Throws `EditError` as `asset(for:)` does, and `.other("source:<id>")` for a file with no readable length.
    public func measure(_ source: EditSource) async throws -> (duration: Double, display: PixelSize?) {
        guard source.kind == .video else { throw EditError.other("unsupported") }
        let read = try await self.asset(for: source)
        guard let seconds = lengths[source.id], seconds > 0 else { throw EditError.other("source:\(source.id)") }
        let display = read.display
        return (seconds, display.w > 0 && display.h > 0 ? display : nil)
    }

    /// The decoded video's length in seconds; nil before it is decoded, or when it has none.
    func length(of id: String) -> Double? { lengths[id] }

    /// Forgets the decoded copies (memory), keeping the files.
    public func dropDecoded() { decoded = [:] }

    // MARK: pitch (31.16)

    /// The pre-shifted copy of `key`'s source range (`EditPitchShifter`), made once and kept in this folder under `key.fileName`
    /// (trimmed with the downloads). Fetches the source first if it is not here. The work runs off this actor in a detached task;
    /// two callers for one key share it. Throws `EditError` (`.other("no audio")` for a range with no sound).
    public func shiftedAudio(for source: EditSource, key: EditPitchKey) async throws -> URL {
        let dest = directory.appendingPathComponent(key.fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }
        if let running = shifting[key] { return try await running.value }
        let folder = directory
        let task = Task.detached(priority: .utility) { [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            let file = try await self.file(for: source)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await EditPitchShifter.render(
                source: file, in: key.inSeconds, out: key.outSeconds, semitones: key.semitones, to: dest)
            return dest
        }
        shifting[key] = task
        defer { if shifting[key] == task { shifting[key] = nil } }
        do {
            let url = try await task.value
            trim(keeping: [url])
            return url
        } catch let e as EditError {
            throw e
        } catch is CancellationError {
            throw EditError.other("cancelled")
        } catch {
            throw EditError.other("pitch:\(key.item)")
        }
    }

    // MARK: the file

    private func file(for source: EditSource) async throws -> URL {
        if let url = local[source.id], FileManager.default.fileExists(atPath: url.path) { return url }
        if let provider, let url = await provider(source.id), FileManager.default.fileExists(atPath: url.path) { return url }
        let dest = directory.appendingPathComponent("\(source.id).\(Self.fileExtension(of: source))")
        if FileManager.default.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }
        if let running = fetching[source.id] { return try await running.value }
        let id = source.id
        let provide = client
        let task = Task<URL, Error> { [directory] in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let part = directory.appendingPathComponent("\(id).part")
            let c = await provide()
            do {
                _ = try await c.download(.libraryItem(id: id), to: part) { [weak self] p in
                    guard let total = p.total, total > 0 else { return }
                    let fraction = min(1, max(0, Double(p.bytes) / Double(total)))
                    Task { await self?.setProgress(id, fraction) }
                }
                if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: part, to: dest)
                return dest
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw EditError.from(error)
            }
        }
        fetching[id] = task
        defer {
            fetching[id] = nil
            progresses[id] = nil
        }
        let url = try await task.value
        trim(keeping: [url])
        return url
    }

    private func setProgress(_ id: String, _ fraction: Double) {
        guard fetching[id] != nil else { return }
        progresses[id] = fraction
    }

    static func fileExtension(of source: EditSource) -> String {
        let ext = (source.name as NSString).pathExtension.lowercased()
        if (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return ext }
        switch source.kind {
        case .gif: return "gif"
        case .photo:
            let type = source.contentType?.lowercased() ?? ""
            if type.contains("webp") { return "webp" }
            return type.contains("png") ? "png" : "jpg"
        case .video, .unsupported: return source.contentType?.lowercased().contains("quicktime") == true ? "mov" : "mp4"
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes the least recently used downloads until the folder fits `limitBytes`.
    func trim(keeping keep: Set<URL> = [], limit: Int64 = EditSourceCache.limitBytes) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = urls.compactMap { url in
            guard url.pathExtension != "part", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        let held = Set(local.values).union(keep)
        for entry in entries where total > limit {
            if held.contains(entry.url) { continue }
            if (try? fm.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    // MARK: decoding

    /// The decoded file, and a video's length in seconds (nil when it cannot be read).
    private static func decode(_ url: URL, source: EditSource) async throws -> (EditSourceAsset, Double?) {
        switch source.kind {
        case .video:
            let asset = AVURLAsset(url: url)
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw EditError.other("source:\(source.id)")
                }
                let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
                var display = source.display
                if display == nil {
                    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    display = PixelSize(w: Int(abs(rect.width).rounded()), h: Int(abs(rect.height).rounded()))
                }
                var length: Double?
                if let time = try? await asset.load(.duration), time.isNumeric {
                    let seconds = time.seconds
                    if seconds.isFinite, seconds > 0 { length = seconds }
                }
                return (.video(asset, display: display ?? PixelSize(w: 0, h: 0), hasAudio: hasAudio), length)
            } catch let e as EditError {
                throw e
            } catch {
                throw EditError.other("source:\(source.id)")
            }
        case .gif:
            guard let timeline = GIFTimeline(file: url) else { throw EditError.other("source:\(source.id)") }
            let frames = (0..<timeline.count).compactMap { CGImageSourceCreateImageAtIndex(timeline.source, $0, nil) }
            guard frames.count == timeline.count, !frames.isEmpty else { throw EditError.other("source:\(source.id)") }
            return (.gif(frames: frames, delays: timeline.delays, display: PixelSize(w: frames[0].width, h: frames[0].height)), nil)
        case .photo:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw EditError.other("source:\(source.id)") }
            // an animated webp (a 7TV emote) or APNG loops like a GIF (APP-API-CONTRACT 39.2)
            if CGImageSourceGetCount(src) > 1, let animated = animatedFrames(src) {
                return (.gif(frames: animated.frames, delays: animated.delays, display: animated.display), nil)
            }
            // the thumbnail call applies the EXIF orientation; the size cap is above any size the render uses
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                throw EditError.other("source:\(source.id)")
            }
            return (.photo(image, display: PixelSize(w: image.width, h: image.height)), nil)
        case .unsupported:
            throw EditError.other("unsupported")
        }
    }

    /// The composed frames of an animated webp or APNG and how long each shows. A delay of 10 ms or less is 100 ms, as browsers
    /// and the render (39.2) do. Nil when a frame cannot be read; at most 2000 frames, as the render.
    static func animatedFrames(_ src: CGImageSource) -> (frames: [CGImage], delays: [Double], display: PixelSize)? {
        let n = CGImageSourceGetCount(src)
        guard n > 1, n <= 2_000 else { return nil }
        var frames: [CGImage] = [], delays: [Double] = []
        for i in 0..<n {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
            let props = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]) ?? [:]
            frames.append(image)
            delays.append(frameDelay(props))
        }
        return (frames, delays, PixelSize(w: frames[0].width, h: frames[0].height))
    }

    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        ]
        for (dictKey, unclamped, clamped) in pairs {
            guard let dict = props[dictKey] as? [CFString: Any] else { continue }
            let raw = (dict[unclamped] as? NSNumber)?.doubleValue ?? (dict[clamped] as? NSNumber)?.doubleValue ?? 0
            return raw <= 0.01 ? 0.1 : raw
        }
        return 0.1
    }
}
