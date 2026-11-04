import CobaltKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One library page at a time for the root, and the cached posts for everything else. A full walk
/// happens only for the working-set change path, and only when the cache is older than `freshInterval`.
actor FinderCatalog {
    private var snapshot: FinderLibrary.Snapshot?
    private var fetchedAt: Date?
    /// Root pages already handed to Finder, keyed by the API cursor (`""` is the first page).
    private var rootPages: [String: (page: FinderLibrary.ListingPage, at: Date)] = [:]
    /// One full walk shared by change enumerations. Unstructured, so awaiting it suspends this actor
    /// and the walk can run.
    private var inFlight: Task<FinderLibrary.Snapshot, Error>?

    /// How long a root page or a full catalog may be reused.
    nonisolated static let freshInterval: TimeInterval = FinderLibrary.freshInterval

    /// One `GET /library` page. The first page uses a nil cursor. Later pages pass the API cursor
    /// Finder handed back. Does not walk the rest of the library.
    func rootPage(cursor: String?) async throws -> FinderLibrary.ListingPage {
        let key = cursor ?? ""
        if let cached = rootPages[key], Date().timeIntervalSince(cached.at) < Self.freshInterval {
            return cached.page
        }
        let client = try Self.client()
        let api: LibraryPage
        do {
            api = try await client.library(cursor: cursor, limit: FinderLibrary.pageLimit, v3: true)
        } catch {
            throw FinderLibrary.failure(from: error)
        }
        var taken = Set<String>()
        if cursor != nil {
            // Names from earlier pages only. This page's own previous folders are excluded so a refetch
            // does not number "Cat" again against itself.
            let own = Set(rootPages[key]?.page.folders.map(\.raw) ?? [])
            taken = Set((snapshot?.rootChildren ?? []).filter { !own.contains($0) }.compactMap { snapshot?.nodes[$0]?.name.lowercased() })
        }
        let listing = FinderLibrary.listingPage(api, takenNames: &taken)
        absorb(listing, resetRoot: cursor == nil)
        if cursor == nil { rootPages = [:] }
        rootPages[key] = (listing, Date())
        return listing
    }

    /// A folder's files, from the pages already listed or the last full snapshot on disk. Nil when
    /// this post has not been seen. Does not walk the library.
    func children(of parent: String) -> [FinderLibrary.Node]? {
        let snap = snapshot ?? remembered()
        guard let snap, snap.nodes[parent]?.isFolder == true else { return nil }
        return snap.children(of: parent).compactMap { snap.nodes[$0] }
    }

    /// One item from the cache or the disk snapshot. Nil when it has not been listed. No network.
    func node(raw: String) -> FinderLibrary.Node? {
        if let node = snapshot?.node(raw) { return node }
        return remembered()?.node(raw)
    }

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
    /// Reuses a catalog younger than `freshInterval`.
    func sync(from anchor: Data?) async throws -> FinderLibrary.Sync {
        let previous = remembered() ?? snapshot
        let current = try await snapshot(maxAge: Self.freshInterval)
        let result = FinderLibrary.sync(anchor: anchor, previous: previous, current: current)
        remember(current)
        rootPages = [:]
        return result
    }

    func currentAnchor() -> Data? { snapshot?.anchor }

    func contents(of raw: String) async throws -> (URL, FinderLibrary.Node) {
        guard let node = node(raw: raw), !node.isFolder else { throw FinderLibrary.Failure.notFound }
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
        guard let url = node(raw: raw)?.thumbnailURL else { throw FinderLibrary.Failure.notFound }
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

    /// Folds one root page into the cache. The first page replaces the root order; a later page appends.
    private func absorb(_ listing: FinderLibrary.ListingPage, resetRoot: Bool) {
        var snap = snapshot ?? FinderLibrary.Snapshot(nodes: [:], rootChildren: [], children: [:], anchor: Data())
        if resetRoot { snap.rootChildren = [] }
        var filesByParent: [String: [String]] = [:]
        for file in listing.files {
            snap.nodes[file.raw] = file
            if let parent = file.parent?.raw {
                filesByParent[parent, default: []].append(file.raw)
            }
        }
        for folder in listing.folders {
            snap.nodes[folder.raw] = folder
            if !snap.rootChildren.contains(folder.raw) { snap.rootChildren.append(folder.raw) }
            snap.children[folder.raw] = filesByParent[folder.raw] ?? []
        }
        snapshot = snap
        fetchedAt = Date()
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
