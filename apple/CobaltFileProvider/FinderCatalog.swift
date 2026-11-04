import CobaltKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Walks `GET /library?v=3` for the extension and downloads one file or a poster. A snapshot younger
/// than `freshInterval` is reused so Quick Look's thumbnail and content requests do not each re-list
/// the library. Enumeration asks for a fresh walk (`maxAge: 0`); an in-flight walk is shared.
actor FinderCatalog {
    private var snapshot: FinderLibrary.Snapshot?
    private var fetchedAt: Date?
    /// One walk shared by the requests Finder makes together. Unstructured, so awaiting it suspends
    /// this actor and the walk can run; a continuation closure here would be `@Sendable` and could
    /// not touch this actor's state.
    private var inFlight: Task<FinderLibrary.Snapshot, Error>?

    /// How long a listing may answer `item` and `fetchContents` before the next walk.
    /// `nonisolated` so the extension can read it without hopping onto this actor.
    nonisolated static let freshInterval: TimeInterval = 20

    func snapshot(maxAge: TimeInterval) async throws -> FinderLibrary.Snapshot {
        if maxAge > 0, let snapshot, let fetchedAt, Date().timeIntervalSince(fetchedAt) < maxAge {
            return snapshot
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await Self.fetch() }
        inFlight = task
        do {
            let value = try await task.value
            snapshot = value
            fetchedAt = Date()
            inFlight = nil
            return value
        } catch {
            inFlight = nil
            throw error
        }
    }

    func remembered() -> FinderLibrary.Snapshot? {
        guard let container = FinderBridge.liveContainer(),
              let data = try? Data(contentsOf: FinderBridge.snapshotURL(in: container))
        else { return nil }
        return try? .decoded(data)
    }

    func remember(_ snapshot: FinderLibrary.Snapshot) {
        guard let container = FinderBridge.liveContainer() else { return }
        let url = FinderBridge.snapshotURL(in: container)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FinderLibrary.Snapshot.encoded(snapshot).write(to: url, options: .atomic)
    }

    /// The anchor the system last saw is `previous` on disk. A fresh walk is diffed against it.
    func sync(from anchor: Data?) async throws -> FinderLibrary.Sync {
        let previous = remembered()
        let current = try await snapshot(maxAge: 0)
        let result = FinderLibrary.sync(anchor: anchor, previous: previous, current: current)
        remember(current)
        return result
    }

    func currentAnchor() -> Data? { snapshot?.anchor }

    func contents(of raw: String) async throws -> (URL, FinderLibrary.Node) {
        let listing = try await snapshot(maxAge: Self.freshInterval)
        guard let node = listing.node(raw), !node.isFolder else { throw FinderLibrary.Failure.notFound }
        let client = try Self.client()
        let remote: RemoteFile
        if let url = node.contentURL {
            remote = .open(url)
        } else if let id = node.privateFileID {
            remote = .libraryItem(id: id)
        } else {
            throw FinderLibrary.Failure.notFound
        }
        var request = try client.urlRequest(for: remote)
        request.timeoutInterval = 600
        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw FinderLibrary.failure(from: error)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temp)
            throw FinderLibrary.Failure.other
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            if http.statusCode == 401 { throw FinderLibrary.Failure.unauthorized }
            if http.statusCode == 404 { throw FinderLibrary.Failure.notFound }
            throw FinderLibrary.Failure.other
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(node.name)
        try FileManager.default.moveItem(at: temp, to: destination)
        return (destination, node)
    }

    func thumbnail(of raw: String, maxPixel: Int) async throws -> Data {
        let listing = try await snapshot(maxAge: Self.freshInterval)
        guard let url = listing.node(raw)?.thumbnailURL else { throw FinderLibrary.Failure.notFound }
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw FinderLibrary.failure(from: error)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FinderLibrary.Failure.other
        }
        return try Self.jpegThumbnail(at: file, maxPixel: maxPixel)
    }

    // MARK: -

    /// Off this actor: the walk only needs the keychain and the network, and the in-flight `Task` must
    /// not have to re-enter the actor to run it.
    nonisolated private static func client() throws -> HTTPCobaltClient {
        guard let record = FinderBridge.saved(), record.enabled, let url = record.url else {
            throw FinderLibrary.Failure.unauthorized
        }
        let keychain = Keychain.shared
        guard Settings.apiKey(in: keychain, forServer: url) != nil else { throw FinderLibrary.Failure.unauthorized }
        return HTTPCobaltClient(baseURL: url, apiKey: { Settings.apiKey(in: keychain, forServer: url) })
    }

    nonisolated private static func fetch() async throws -> FinderLibrary.Snapshot {
        let client = try client()
        do {
            let posts = try await FinderLibrary.collect { cursor in
                try await client.library(cursor: cursor, limit: FinderLibrary.pageLimit, v3: true)
            }
            return FinderLibrary.make(posts: posts)
        } catch {
            throw FinderLibrary.failure(from: error)
        }
    }

    /// A JPEG no larger than `maxPixel` on the long side. ImageIO downsamples; the poster is not decoded full size.
    static func jpegThumbnail(at url: URL, maxPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FinderLibrary.Failure.other }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FinderLibrary.Failure.other
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FinderLibrary.Failure.other
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FinderLibrary.Failure.other }
        return data as Data
    }
}
