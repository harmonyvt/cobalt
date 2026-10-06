import Foundation
import Synchronization

// The visible folder (CONTRACT-OFFLINE.md): where kept files live, how a file is recognised as cobalt's
// after the owner renames or moves it in Files, how the root is re-read, and how a file gets into it.
//
// Everything here is plain `nonisolated` file work: the store calls it from `@concurrent` hops behind the
// `OfflineFolderGate`, never from the main actor.

/// Where an add came from (CONTRACT-OFFLINE.md section 5). `PhotosSync` and `FolderSync` act only on `.save`.
public enum AddOrigin: Sendable, Equatable { case save, keepOffline, adopted, migrated }

/// What is on the device, in the two tiers (decision 4). `offline`: kept files, wherever they wait (the
/// visible folder, or `files/` until they can move). `cache`: files nobody asked to keep, plus the posters
/// and flipbooks of media that have nothing kept (the limit, `bytesToFree` and the progress bar use this).
public struct OfflineUsage: Sendable, Equatable {
    public var offline: StorageUsage
    public var cache: StorageUsage

    public init(offline: StorageUsage, cache: StorageUsage) {
        self.offline = offline
        self.cache = cache
    }
}

/// What one pass over the visible root found (decision 6's table, one counter per row).
public struct OfflineScanReport: Sendable, Equatable {
    /// A kept file turned up at a new path (renamed, moved into a subfolder): the record follows.
    public var followed: Int
    /// A kept file is gone (deleted, moved out): the record is "not offline" now.
    public var unkept: Int
    /// A record took a file it did not point at (restored from recently deleted, a copy after the original went).
    public var adopted: Int
    /// A tagged file with no record (the index was lost or rolled back): a minimal record was made.
    public var rebuilt: Int
    /// Files with no cobalt tag: the owner's own, never touched.
    public var untracked: Int
    /// The root could not be read: nothing was changed (a missing root is never "every file deleted").
    public var rootMissing: Bool

    public init(followed: Int = 0, unkept: Int = 0, adopted: Int = 0, rebuilt: Int = 0, untracked: Int = 0, rootMissing: Bool = false) {
        self.followed = followed
        self.unkept = unkept
        self.adopted = adopted
        self.rebuilt = rebuilt
        self.untracked = untracked
        self.rootMissing = rootMissing
    }

    /// Something in the index changed.
    var changedIndex: Bool { followed + unkept + adopted + rebuilt > 0 }
}

// MARK: - The identity tag (decision 6)

/// The extended attribute `com.capybaraharmony.cobalt.item`: a small JSON, written BEFORE a file enters the
/// visible root, so a file in the root without it is never cobalt's. `rename(2)` keeps attributes, so a rename
/// or a move inside the root is followed by id. The payload also lets a lost index rebuild a minimal record.
struct OfflineTag: Codable, Equatable, Sendable {
    static let attribute = "com.capybaraharmony.cobalt.item"
    /// The attribute must stay under this many bytes.
    static let maxBytes = 512

    var v: Int = 1
    var id: String
    var media: String
    var kind: StoredVideo.Kind
    var session: String?
    var remote: String?
    var link: String?
    /// Seconds since 1970 (the record's `createdAt`).
    var created: Double
    /// The owner's custom title of the media, when there is one.
    var title: String?

    /// The JSON, under `maxBytes`: the title goes first when it does not fit, then the link, then the remote URL.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var t = self
        func data() -> Data { (try? encoder.encode(t)) ?? Data() }
        if data().count > Self.maxBytes { t.title = nil }
        if data().count > Self.maxBytes { t.link = nil }
        if data().count > Self.maxBytes { t.remote = nil }
        return data()
    }

    static func decode(_ data: Data) -> OfflineTag? {
        guard let tag = try? JSONDecoder().decode(OfflineTag.self, from: data), tag.v >= 1, !tag.id.isEmpty else { return nil }
        return tag
    }

    static func read(at url: URL) -> OfflineTag? {
        XAttr.get(attribute, at: url).flatMap(decode)
    }
}

enum XAttr {
    static func set(_ name: String, _ data: Data, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func get(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size <= 64 * 1024 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { return nil }
            return buffer
        }
    }

    static func remove(_ name: String, at url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return removexattr(path, name, 0)
        }
    }
}

// MARK: - The file operations the move is made of (the crash-injection seam)

/// The points of one move, in order (section 2.2). A test's `checkpoint` throws `OfflineInterrupted` at one of
/// them to stand in for a crash: nothing after it runs, and nothing is cleaned up.
enum OfflineMoveStep: Sendable, Equatable {
    /// the identity tag is on the source file
    case tagged
    /// copy path: the whole copy sits as `.cobalt-<id>.part`, the source is untouched
    case copied
    /// copy path: the copy has its final name, the source still exists
    case copyRenamed
    /// the file is at its final name and the source is gone
    case renamed
    /// the index names the file
    case indexed
}

/// What a test throws from `checkpoint` to stop a run where a crash would.
struct OfflineInterrupted: Error, Equatable { var step: OfflineMoveStep }

protocol OfflineFileOps: Sendable {
    func setTag(_ tag: OfflineTag, at url: URL) throws
    /// `rename(2)`. With `exclusive`, an existing destination is an error (EEXIST) instead of being replaced.
    func rename(_ from: URL, to: URL, exclusive: Bool) throws
    func copy(_ from: URL, to: URL) throws
    func fullSync(_ url: URL) throws
    func size(of url: URL) -> Int64?
    func remove(_ url: URL) throws
    func checkpoint(_ step: OfflineMoveStep) throws
}

struct SystemFileOps: OfflineFileOps {
    func setTag(_ tag: OfflineTag, at url: URL) throws {
        try XAttr.set(OfflineTag.attribute, tag.encoded(), at: url)
    }

    func rename(_ from: URL, to: URL, exclusive: Bool) throws {
        let result = from.withUnsafeFileSystemRepresentation { f -> Int32 in
            to.withUnsafeFileSystemRepresentation { t -> Int32 in
                guard let f, let t else { return -1 }
                return exclusive ? renamex_np(f, t, UInt32(RENAME_EXCL)) : Darwin.rename(f, t)
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func copy(_ from: URL, to: URL) throws { try FileManager.default.copyItem(at: from, to: to) }

    func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func size(of url: URL) -> Int64? { OfflineFolder.fileSize(url) }

    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    func checkpoint(_ step: OfflineMoveStep) throws {}
}

// MARK: - The gate

/// Our own moves, renames and the scan never race one another: they all run through this one in-process
/// async gate (decision 7). A scan that read the folder in the middle of one of our moves could take the
/// half-moved file for an owner's deletion.
actor OfflineFolderGate {
    static let shared = OfflineFolderGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    /// Runs `body` alone: the next caller waits for it to finish.
    func exclusive<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await enter()
        let result = await body()
        leave()
        return result
    }
}

// MARK: - Watching the root

/// A `DispatchSource` on the root's descriptor (`.write`: entries of the root itself, not subfolders) with a
/// debounce. Created here, in a nonisolated type, with `@Sendable` handlers: a handler formed inside a
/// `@MainActor` method would inherit that isolation and trap when the system calls it on its own queue.
final class OfflineFolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.capybaraharmony.cobalt.offline-watch", qos: .utility)
    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private let debounce: TimeInterval

    init?(root: URL, debounce: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.onChange = onChange
        self.debounce = debounce
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { @Sendable [weak self] in self?.fire() }
        source.setCancelHandler { @Sendable in close(fd) }
        self.source = source
        source.resume()
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { @Sendable [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func stop() {
        queue.async { @Sendable [self] in
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
        }
    }

    deinit { source?.cancel() }
}

// MARK: - The visible folder

/// What the enumeration of the root found: one regular file.
struct VisibleEntry: Sendable, Equatable {
    /// Relative to the root, with the owner's subfolders.
    var path: String
    var size: Int64
    var tag: OfflineTag?
    var excludedFromBackup: Bool
}

enum OfflineFolder {
    /// A `.part` older than this is the leftover of a copy that never finished.
    static let staleParts: TimeInterval = 60 * 60

    /// `Documents` in the iOS app process (Files labels it "On My iPhone › cobalt"); nil in every extension
    /// and on the Mac until wave M (decision 12, 15).
    static func defaultVisibleRoot() -> URL? {
        #if os(iOS)
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #else
        return nil
        #endif
    }

    nonisolated static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    static func partName(for id: String) -> String { ".cobalt-\(id).part" }

    /// Every regular file under `root` (recursive; hidden entries, `.Trash` and `.cobalt-*.part` skipped) with its
    /// size and tag. Nil when the root cannot be read: the caller changes nothing then.
    static func enumerate(root: URL) -> [VisibleEntry]? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? fm.contentsOfDirectory(atPath: root.path)) != nil
        else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isExcludedFromBackupKey]
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { return nil }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var out: [VisibleEntry] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            out.append(VisibleEntry(
                path: relative, size: Int64(values.fileSize ?? 0), tag: OfflineTag.read(at: url),
                excludedFromBackup: values.isExcludedFromBackup ?? false))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Removes `.cobalt-*.part` files older than `staleParts` from the top of the root.
    static func purgeStaleParts(root: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".cobalt-") && name.hasSuffix(".part") {
            let url = root.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > staleParts { try? fm.removeItem(at: url) }
        }
    }

    /// The names in one folder, lowercased (the clash check is case-insensitive).
    static func names(in folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
    }

    /// Server-backed files are left out of the owner's backup (decision 14); set when a file lands and re-checked
    /// by the scan.
    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// Deletes a kept file from the visible root. On failure the tag is taken off so the file is the owner's
    /// from then on (a tagged file with no record would be adopted again by the next scan). False: still there.
    static func removeVisible(root: URL, path: String, ops: any OfflineFileOps) -> Bool {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try ops.remove(url)
            return true
        } catch {
            XAttr.remove(OfflineTag.attribute, at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: moving in

    /// One file to move into the root.
    struct MoveRequest: Sendable {
        var id: String
        var source: URL
        var tag: OfflineTag
        /// The name `FolderNaming` chose; a clash gets ` (2)`.
        var preferredName: String
        var excludeFromBackup: Bool
    }

    enum MoveOutcome: Sendable, Equatable {
        case moved(path: String, name: String, bytes: Int64)
        /// the source file is not there (nothing to move)
        case missing
        case failed(String)
    }

    /// Section 2.2, steps 1 to 3, for each request: tag the file (it stays where it is), rename it into `root`
    /// under a free name, or when the rename crosses a volume copy it to `.cobalt-<id>.part`, sync, compare the
    /// size, rename the copy to its final name and only then delete the source. Never deletes a source before the
    /// destination is whole. The index write (step 4) is the caller's.
    ///
    /// Throws only `OfflineInterrupted` (a test's stand-in for a crash); every other failure is per file.
    static func moveIn(
        _ requests: [MoveRequest], root: URL, ops: any OfflineFileOps, now: Date = Date()
    ) throws -> [(id: String, outcome: MoveOutcome)] {
        purgeStaleParts(root: root, now: now)
        var taken = names(in: root)
        var results: [(id: String, outcome: MoveOutcome)] = []
        for request in requests {
            guard ops.size(of: request.source) != nil else {
                results.append((request.id, .missing))
                continue
            }
            do {
                let name = try moveOne(request, root: root, taken: &taken, ops: ops)
                let destination = root.appendingPathComponent(name)
                if request.excludeFromBackup { excludeFromBackup(destination) }
                results.append((request.id, .moved(path: name, name: name, bytes: ops.size(of: destination) ?? 0)))
            } catch let interrupted as OfflineInterrupted {
                throw interrupted
            } catch {
                results.append((request.id, .failed(String(describing: error))))
            }
        }
        return results
    }

    private static func moveOne(
        _ request: MoveRequest, root: URL, taken: inout Set<String>, ops: any OfflineFileOps
    ) throws -> String {
        try ops.setTag(request.tag, at: request.source)                                  // step 1
        try ops.checkpoint(.tagged)
        var lastError: (any Error)?
        for _ in 0..<6 {
            let name = FolderNaming.unique(request.preferredName, among: taken)         // step 2
            let destination = root.appendingPathComponent(name)
            do {
                try place(request, at: destination, root: root, ops: ops)               // step 3
                taken.insert(name.lowercased())
                return name
            } catch let error as POSIXError where error.code == .EEXIST {
                taken.insert(name.lowercased())                                           // someone took it meanwhile
                lastError = error
            }
        }
        throw lastError ?? POSIXError(.EEXIST)
    }

    private static func place(_ request: MoveRequest, at destination: URL, root: URL, ops: any OfflineFileOps) throws {
        do {
            try ops.rename(request.source, to: destination, exclusive: true)
        } catch let error as POSIXError where error.code == .EXDEV {
            // another volume: copy, make it whole, rename it into place, and only then drop the source
            let part = root.appendingPathComponent(partName(for: request.id))
            try? ops.remove(part)
            do {
                try ops.copy(request.source, to: part)
                try ops.setTag(request.tag, at: part)
                try ops.fullSync(part)
                guard let want = ops.size(of: request.source), ops.size(of: part) == want else {
                    throw POSIXError(.EIO)
                }
                try ops.checkpoint(.copied)
                try ops.rename(part, to: destination, exclusive: true)
                try ops.checkpoint(.copyRenamed)
            } catch let interrupted as OfflineInterrupted {
                throw interrupted
            } catch {
                try? ops.remove(part)
                throw error
            }
            try? ops.remove(request.source)
        }
        try ops.checkpoint(.renamed)
    }

    // MARK: reconciling the scan with the index

    struct Reconciled {
        var report = OfflineScanReport()
        /// cache files (names under `files/`) to delete once the index is written: a copy that now exists in the root too
        var dropCache: [String] = []
        /// ids of records made from a tag alone
        var rebuilt: [String] = []
        /// visible files whose record has a server copy and that are not yet out of the backup
        var exclude: [String] = []
    }

    /// Decision 6's table, applied to `records`. `entries` is what the root holds now; the caller has already
    /// refused an unreadable root.
    static func reconcile(
        _ records: inout [OfflineStore.Record], entries: [VisibleEntry], hiddenRoot: URL, now: Date
    ) -> Reconciled {
        var out = Reconciled()
        var byID: [String: [VisibleEntry]] = [:]
        for entry in entries {                                       // already sorted by path
            guard let tag = entry.tag else { out.report.untracked += 1; continue }
            byID[tag.id, default: []].append(entry)
        }
        var known: Set<String> = []
        for i in records.indices {
            let record = records[i]
            known.insert(record.id)
            guard let matches = byID[record.id], !matches.isEmpty else {
                if record.visiblePath != nil {                       // deleted, or moved out
                    records[i].visiblePath = nil
                    records[i].givenName = nil
                    records[i].keep = false
                    out.report.unkept += 1
                }
                continue
            }
            // the recorded path wins (a duplicate is the owner's); else the first in sorted order
            let chosen = matches.first { $0.path == record.visiblePath } ?? matches[0]
            if let cache = record.fileName {
                // A copy that crashed after its rename: the same file is in both places. The cache one goes only
                // when the visible one is whole (same size); unsure, both stay and the record keeps the cache one.
                let cacheSize = fileSize(hiddenRoot.appendingPathComponent("files/\(cache)"))
                guard cacheSize == chosen.size else { continue }
                out.dropCache.append(cache)
                records[i].fileName = nil
            }
            if record.visiblePath == nil { out.report.adopted += 1 }
            else if record.visiblePath != chosen.path { out.report.followed += 1 }
            records[i].visiblePath = chosen.path
            records[i].keep = true
            records[i].bytes = chosen.size
            if record.hasServerCopy, !chosen.excludedFromBackup { out.exclude.append(chosen.path) }
        }
        // a tag with no record: the index was lost or rolled back
        for (id, matches) in byID.sorted(by: { $0.key < $1.key }) where !known.contains(id) {
            guard let tag = matches[0].tag else { continue }
            let entry = matches[0]
            let stem = ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let explicit = tag.media
            var media = explicit
            if records.contains(where: { $0.media == explicit }) {
                let hasOriginal = records.contains { $0.media == explicit && $0.kind == .original }
                if tag.kind == .original && hasOriginal { media = id }
            }
            let posterName = "\(id).jpg"
            let hasPoster = FileManager.default.fileExists(atPath: hiddenRoot.appendingPathComponent("posters/\(posterName)").path)
            let rebuilt = OfflineStore.Record(
                id: id, kind: tag.kind, fileName: nil, posterName: hasPoster ? posterName : nil,
                name: stem, duration: nil, width: nil, height: nil, bytes: entry.size, sessionID: tag.session,
                link: tag.link.flatMap(URL.init(string:)), remoteURL: tag.remote.flatMap(URL.init(string:)),
                createdAt: Date(timeIntervalSince1970: tag.created), addedAt: now,
                posterBytes: hasPoster ? fileSize(hiddenRoot.appendingPathComponent("posters/\(posterName)")) : nil,
                previewNames: nil, previewBytes: nil, publicURL: nil, mediaID: media, clip: nil, title: tag.title,
                keep: true, visiblePath: entry.path, givenName: nil)
            records.append(rebuilt)
            out.rebuilt.append(id)
            out.report.rebuilt += 1
            if rebuilt.hasServerCopy, !entry.excludedFromBackup { out.exclude.append(entry.path) }
        }
        return out
    }

    struct ScanResult: Sendable {
        var records: [OfflineStore.Record]
        var report: OfflineScanReport
        var rebuilt: [String]
        var wrote: Bool
    }

    /// One whole pass: enumerate the root, apply the table in one coordinated index write, delete the cache copies
    /// that are now redundant, take server-backed files out of the backup. Off the main actor.
    @concurrent
    static func scan(hiddenRoot: URL, visibleRoot: URL, now: Date, ops: any OfflineFileOps) async -> ScanResult {
        purgeStaleParts(root: visibleRoot, now: now)
        guard let entries = enumerate(root: visibleRoot) else {
            // never "every file deleted": nothing changes
            return ScanResult(
                records: OfflineStore.readRecords(root: hiddenRoot), report: OfflineScanReport(rootMissing: true),
                rebuilt: [], wrote: false)
        }
        let before = OfflineStore.readRecords(root: hiddenRoot)
        var probe = before
        var reconciled = reconcile(&probe, entries: entries, hiddenRoot: hiddenRoot, now: now)
        var records = before
        var wrote = false
        if probe != before {
            // something changed: apply it to the index as it is right now, in one coordinated write
            var again = Reconciled()
            if let written = try? OfflineStore.mutate(root: hiddenRoot, { current in
                again = reconcile(&current, entries: entries, hiddenRoot: hiddenRoot, now: now)
            }) {
                records = written
                reconciled = again
                wrote = true
            }
        }
        for name in reconciled.dropCache where wrote { try? ops.remove(hiddenRoot.appendingPathComponent("files/\(name)")) }
        for path in reconciled.exclude { excludeFromBackup(visibleRoot.appendingPathComponent(path)) }
        return ScanResult(records: records, report: reconciled.report, rebuilt: reconciled.rebuilt, wrote: wrote)
    }

    // MARK: off the main actor (the store calls these behind the gate)

    @concurrent
    static func removeVisibleOffMain(root: URL, path: String, ops: any OfflineFileOps) async -> Bool {
        removeVisible(root: root, path: path, ops: ops)
    }

    struct PromoteOutcome: Sendable {
        var records: [OfflineStore.Record]?
        var moved = 0
        var failed = 0
        var bytes: Int64 = 0
        var interrupted: OfflineInterrupted?
    }

    /// Moves `requests` into the root, 20 to a coordinated index write (section 2.2): `fileName = nil`,
    /// `visiblePath`, `givenName`, `keep = true`. A test's `OfflineInterrupted` stops everything where it stands.
    @concurrent
    static func promote(
        _ requests: [MoveRequest], hiddenRoot: URL, visibleRoot: URL, ops: any OfflineFileOps, now: Date
    ) async -> PromoteOutcome {
        var outcome = PromoteOutcome()
        var start = 0
        while start < requests.count {
            let batch = Array(requests[start..<min(start + 20, requests.count)])
            start += 20
            let results: [(id: String, outcome: MoveOutcome)]
            do {
                results = try moveIn(batch, root: visibleRoot, ops: ops, now: now)
            } catch let interrupted as OfflineInterrupted {
                outcome.interrupted = interrupted
                return outcome
            } catch {
                outcome.failed += batch.count
                continue
            }
            var strays: [URL] = []
            let written = try? OfflineStore.mutate(root: hiddenRoot) { records in
                for result in results {
                    guard case .moved(let path, let name, let bytes) = result.outcome else { continue }
                    guard let i = records.firstIndex(where: { $0.id == result.id }) else {
                        strays.append(visibleRoot.appendingPathComponent(path))      // removed while it moved
                        continue
                    }
                    records[i].fileName = nil
                    records[i].visiblePath = path
                    records[i].givenName = name
                    records[i].keep = true
                    if bytes > 0 { records[i].bytes = bytes }
                }
            }
            for stray in strays { try? ops.remove(stray) }
            if let written { outcome.records = written }
            for result in results {
                switch result.outcome {
                case .moved(_, _, let bytes): outcome.moved += 1; outcome.bytes += bytes
                case .failed(let reason):
                    outcome.failed += 1
                    Telemetry.log(.warn, .store, "offline move failed", data: ["reason": .string(String(reason.prefix(120)))])
                case .missing: break
                }
            }
            do { try ops.checkpoint(.indexed) } catch let interrupted as OfflineInterrupted {
                outcome.interrupted = interrupted
                return outcome
            } catch {}
        }
        return outcome
    }

    /// The migration's first step: every legacy record (`keep == nil`) whose file is there becomes kept.
    @concurrent
    static func flagLegacy(hiddenRoot: URL, ids: Set<String>) async -> (records: [OfflineStore.Record]?, flagged: Set<String>) {
        var flagged: Set<String> = []
        let written = try? OfflineStore.mutate(root: hiddenRoot) { records in
            for i in records.indices where ids.contains(records[i].id) && records[i].keep == nil {
                guard let name = records[i].fileName,
                      FileManager.default.fileExists(atPath: hiddenRoot.appendingPathComponent("files/\(name)").path)
                else { continue }
                records[i].keep = true
                flagged.insert(records[i].id)
            }
        }
        return (written, flagged)
    }

    struct Rename: Sendable {
        var id: String
        var path: String
        var preferredName: String
    }

    /// Renames kept files in place (decision 8), each inside its own folder, then one index write. Returns the
    /// records when it wrote.
    @concurrent
    static func rename(_ plan: [Rename], hiddenRoot: URL, visibleRoot: URL, ops: any OfflineFileOps) async -> [OfflineStore.Record]? {
        var done: [(id: String, from: String, to: String)] = []
        for item in plan {
            let folderPath = (item.path as NSString).deletingLastPathComponent
            let folder = folderPath.isEmpty ? visibleRoot : visibleRoot.appendingPathComponent(folderPath, isDirectory: true)
            let current = (item.path as NSString).lastPathComponent
            var taken = names(in: folder)
            taken.remove(current.lowercased())
            let name = FolderNaming.unique(item.preferredName, among: taken)
            guard name != current else { continue }
            let from = visibleRoot.appendingPathComponent(item.path)
            guard ops.size(of: from) != nil else { continue }
            do {
                // a change of case only is the same name to a case-insensitive volume: not exclusive then
                try ops.rename(from, to: folder.appendingPathComponent(name), exclusive: name.lowercased() != current.lowercased())
                done.append((item.id, item.path, folderPath.isEmpty ? name : "\(folderPath)/\(name)"))
            } catch {
                Telemetry.log(.warn, .store, "offline rename failed", data: ["reason": .string(String(describing: error).prefix(120).description)])
            }
        }
        guard !done.isEmpty else { return nil }
        return try? OfflineStore.mutate(root: hiddenRoot) { records in
            for change in done {
                guard let i = records.firstIndex(where: { $0.id == change.id }), records[i].visiblePath == change.from else { continue }
                records[i].visiblePath = change.to
                records[i].givenName = (change.to as NSString).lastPathComponent
            }
        }
    }

    /// `Sync/offline.json {migratedAt, version: 1}`: telemetry and the Settings footnote only; the migration
    /// itself has no flag that could lie. Written once.
    static func writeMigrationMarker(in directory: URL, now: Date) {
        let url = directory.appendingPathComponent("offline.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let body: [String: Any] = ["migratedAt": ISO8601DateFormatter().string(from: now), "version": 1]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func readMigrationMarker(in directory: URL) -> Date? {
        let url = directory.appendingPathComponent("offline.json")
        guard let data = try? Data(contentsOf: url),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = body["migratedAt"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
