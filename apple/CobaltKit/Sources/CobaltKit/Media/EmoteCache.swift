import CryptoKit
import Foundation

/// 7TV pictures kept on this device (APP-API-CONTRACT 57.13), so a grid paints at once and works offline. This is not the
/// library: the files live in the app's caches folder (`Caches/cobalt-emotes`), capped at `limit` bytes, and the least
/// recently used go first once the cap is passed. The system may also clear them when the disk runs low; they are fetched
/// again on the next look.
///
/// - `data(for:)`: memory, then disk, then the network (one fetch per URL however many tiles ask). A failure is `nil`.
/// - `memoryData(for:)`: memory only, synchronous, for a tile's first frame (no blank flash when it scrolls back).
/// - `prefetch(_:)`: fills the disk in the background, four at a time, skipping what is already there. The live client
///   calls it with every 7TV set page and emote search answer it reads, and `SevenTvStore` pages through a channel's
///   sets once a launch, so the emotes in the owner's sets are on the device before they are looked at.
public actor EmoteCache {
    public static let shared = EmoteCache()
    /// 200 MB: a 2x 7TV preview is 5 to 100 KB, so several thousand emotes.
    public static let defaultLimit = 200 * 1024 * 1024
    /// Prefetch keeps at most this many URLs waiting; more are dropped (the next look fetches them).
    static let queueMax = 4000
    static let prefetchWidth = 4

    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let dir: URL
    private let limit: Int
    private let fetch: Fetch
    /// Thread-safe on its own; read synchronously by `memoryData(for:)`.
    nonisolated(unsafe) private let memory: NSCache<NSURL, NSData>

    private var flights: [URL: Task<Data?, Never>] = [:]
    /// Bytes on disk; measured on first need.
    private var total: Int?
    private var queue: [URL] = []
    private var queued: Set<URL> = []
    private var workers = 0
    /// Prefetch fetches that failed in a row; at `prefetchGiveUp` the waiting queue is dropped (offline, or 7TV's CDN down),
    /// so a dead network is not tried four thousand times. The next look queues them again.
    private var failuresInARow = 0
    static let prefetchGiveUp = 8

    public init(directory: URL? = nil, limit: Int = EmoteCache.defaultLimit, fetch: Fetch? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        dir = directory ?? caches.appendingPathComponent("cobalt-emotes", isDirectory: true)
        self.limit = limit
        self.fetch = fetch ?? EmoteCache.networkFetch
        let memory = NSCache<NSURL, NSData>()
        memory.totalCostLimit = 32 * 1024 * 1024
        memory.countLimit = 600
        self.memory = memory
    }

    /// Plain HTTPS, no `URLCache` (this cache is the copy on disk), 20 s a request; anything but a 2xx is a failure.
    static let networkFetch: Fetch = { url in
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: reading

    nonisolated public func memoryData(for url: URL) -> Data? {
        memory.object(forKey: url as NSURL) as Data?
    }

    /// The picture's bytes: memory, disk, else one network fetch shared by every caller. `nil` when it cannot be had.
    public func data(for url: URL) async -> Data? {
        if let hit = memoryData(for: url) { return hit }
        if let hit = readDisk(url) {
            remember(hit, url)
            return hit
        }
        return await download(url)
    }

    /// The picture is on this device (memory or disk).
    public func has(_ url: URL) -> Bool {
        memoryData(for: url) != nil || FileManager.default.fileExists(atPath: path(url).path)
    }

    private func download(_ url: URL) async -> Data? {
        if let flight = flights[url] { return await flight.value }
        let fetch = self.fetch
        // an empty body is a failure for every caller waiting on it, not only the one that writes
        let flight = Task<Data?, Never> {
            guard let data = try? await fetch(url), !data.isEmpty else { return nil }
            return data
        }
        flights[url] = flight
        let data = await flight.value
        flights[url] = nil
        guard let data else { return nil }
        remember(data, url)
        writeDisk(data, url)
        return data
    }

    private func remember(_ data: Data, _ url: URL) {
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
    }

    // MARK: prefetch

    /// Fetches these onto the disk in the background (what is already there is skipped). Never throws, never blocks.
    /// The shared cache does nothing here under test, so a test of the client never reaches 7TV's CDN.
    public func prefetch(_ urls: [URL]) {
        if self === EmoteCache.shared, RunningTests.now { return }
        for url in urls where !queued.contains(url) && queue.count < Self.queueMax {
            queued.insert(url)
            queue.append(url)
        }
        while workers < Self.prefetchWidth, !queue.isEmpty {
            workers += 1
            Task(priority: .utility) { await self.drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            queued.remove(url)
            if has(url) { continue }
            if await download(url) == nil {
                failuresInARow += 1
                if failuresInARow >= Self.prefetchGiveUp {
                    queue.removeAll()
                    queued.removeAll()
                }
            } else {
                failuresInARow = 0
            }
        }
        workers -= 1
    }

    /// The prefetch queue is empty and nothing is fetching (tests).
    public var isIdle: Bool { queue.isEmpty && workers == 0 && flights.isEmpty }

    // MARK: disk

    func path(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(digest + ".emote")
    }

    private func readDisk(_ url: URL) -> Data? {
        let file = path(url)
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        // used now: the trim keeps it over older ones
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    private func writeDisk(_ data: Data, _ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = path(url)
        // measured before this write, so a file already there is replaced in the sum, not added to it
        let before = total ?? measure()
        let replaced = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        let now = max(0, before - replaced) + data.count
        total = now
        if now > limit { trim() }
    }

    private func entries() -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { file in
            // the atomic write's temporary files are not entries
            guard file.pathExtension == "emote", let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func measure() -> Int { entries().reduce(0) { $0 + $1.size } }

    /// Deletes the least recently used files until the folder is at 80% of the cap.
    private func trim() {
        var sum = 0
        let all = entries().sorted { $0.used < $1.used }
        sum = all.reduce(0) { $0 + $1.size }
        let target = limit * 4 / 5
        for entry in all where sum > target {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { sum -= entry.size }
        }
        total = sum
    }

    /// Bytes on disk now.
    public func diskBytes() -> Int {
        let sum = measure()
        total = sum
        return sum
    }

    /// Forgets everything (memory and disk).
    public func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        total = 0
    }
}

/// The last answer of each 7TV read (`GET /7tv`, a channel's sets, a set's pages), kept on disk so the 7tv tab still shows
/// the owner's account, sets and emotes when the server cannot be reached (APP-API-CONTRACT 57.13). Only a 2xx answer is
/// kept; it is read back only when the request fails for lack of network. Keyed by the full URL (server, path and query)
/// and by the key the request was signed with (`scope`), so another server or another sign-in never sees these. Forgotten
/// when the server says no account is linked and when the account is linked or unlinked. At most `maxFiles` files and
/// `maxBytes`; the least recently used go first (a set searched with many different words does not pile up).
///
/// A value, not a global: the live client holds `.standard`, which keeps nothing while tests run; a test passes its own
/// folder.
public struct SevenTvAnswerCache: Sendable {
    /// Where the answers live; nil keeps nothing.
    let directory: URL?
    static let maxFiles = 400
    static let maxBytes = 24 * 1024 * 1024

    init(directory: URL?) { self.directory = directory }

    /// `Caches/cobalt-7tv-answers`; nothing at all in a test run (so a stubbed server never reads another test's answer).
    public static let standard: SevenTvAnswerCache = {
        if RunningTests.now { return SevenTvAnswerCache(directory: nil) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return SevenTvAnswerCache(directory: caches.appendingPathComponent("cobalt-7tv-answers", isDirectory: true))
    }()

    /// The key the request was signed with, reduced to a short fingerprint (the key itself is never written anywhere).
    static func scope(of request: URLRequest) -> String {
        guard let auth = request.value(forHTTPHeaderField: "Authorization") else { return "" }
        return SHA256.hash(data: Data(auth.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func file(for url: URL, scope: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data("\(scope)\n\(url.absoluteString)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    func save(_ data: Data, for url: URL?, scope: String) {
        guard let url, let directory, let file = file(for: url, scope: scope) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        trim()
    }

    func load(for url: URL?, scope: String) -> Data? {
        guard let url, let file = file(for: url, scope: scope), let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        // used now: the trim keeps it over older ones
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Past the file or byte cap: the least recently used go until 80% of both are left.
    private func trim() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var entries: [(url: URL, size: Int, used: Date)] = files.compactMap { file in
            guard file.pathExtension == "json", let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var bytes = entries.reduce(0) { $0 + $1.size }
        guard entries.count > Self.maxFiles || bytes > Self.maxBytes else { return }
        entries.sort { $0.used < $1.used }
        var count = entries.count
        for entry in entries where count > Self.maxFiles * 4 / 5 || bytes > Self.maxBytes * 4 / 5 {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                count -= 1
                bytes -= entry.size
            }
        }
    }
}

/// This process is a test run (`swift test` or an Xcode test host).
enum RunningTests {
    static let now: Bool = {
        let info = ProcessInfo.processInfo
        return info.environment["XCTestConfigurationFilePath"] != nil || info.environment["XCTestBundlePath"] != nil
            || info.processName.lowercased().contains("xctest") || info.processName.contains("swiftpm-testing-helper") || NSClassFromString("XCTestCase") != nil
    }()
}
