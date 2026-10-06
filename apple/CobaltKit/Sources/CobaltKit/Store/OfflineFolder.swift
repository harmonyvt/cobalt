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
    /// The root could not be read (or a file's tag could not): nothing was changed (a missing root is never
    /// "every file deleted", and an unreadable tag is never "no tag").
    public var rootMissing: Bool
    /// The index exists but this build cannot decode it (a later build's records, a torn write): nothing was
    /// changed, and the index was not written over (review fix S1).
    public var indexUnreadable: Bool

    public init(
        followed: Int = 0, unkept: Int = 0, adopted: Int = 0, rebuilt: Int = 0, untracked: Int = 0,
        rootMissing: Bool = false, indexUnreadable: Bool = false
    ) {
        self.followed = followed
        self.unkept = unkept
        self.adopted = adopted
        self.rebuilt = rebuilt
        self.untracked = untracked
        self.rootMissing = rootMissing
        self.indexUnreadable = indexUnreadable
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
    /// Gallery fields (apple/CONTRACT-GALLERY.md 4), so a lost index can rebuild an item or a made file as what it is.
    @LenientRole var role: GalleryRole?
    var item: Int?
    var lib: String?

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

    /// What a file's attribute says. Only a missing attribute means "not cobalt's": any other failure to read
    /// it (data protection, a permission) is `unreadable`, and a caller that would act on "untagged" stops.
    enum Probe: Equatable {
        case tag(OfflineTag)
        case untagged
        case unreadable
    }

    static func probe(at url: URL) -> Probe {
        switch XAttr.read(attribute, at: url) {
        case .absent: return .untagged
        case .failed: return .unreadable
        case .data(let data): return decode(data).map(Probe.tag) ?? .untagged       // present but not ours: untagged
        }
    }

    /// The tag, or nil for an untagged file and for one that cannot be read (use `probe` to tell them apart).
    static func read(at url: URL) -> OfflineTag? {
        if case .tag(let tag) = probe(at: url) { return tag }
        return nil
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

    enum Value: Equatable {
        case data(Data)
        /// ENOATTR: the file has no such attribute.
        case absent
        /// any other error (errno): the answer is unknown
        case failed(Int32)
    }

    /// Reads an attribute, telling "there is none" (ENOATTR) from every other failure.
    static func read(_ name: String, at url: URL) -> Value {
        url.withUnsafeFileSystemRepresentation { path -> Value in
            guard let path else { return .failed(EINVAL) }
            let size = getxattr(path, name, nil, 0, 0, 0)
            if size < 0 { return errno == ENOATTR ? .absent : .failed(errno) }
            guard size > 0, size <= 64 * 1024 else { return .data(Data()) }          // present, but not a tag of ours
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            if read < 0 { return errno == ENOATTR ? .absent : .failed(errno) }
            guard read == size else { return .failed(EIO) }
            return .data(buffer)
        }
    }

    static func get(_ name: String, at url: URL) -> Data? {
        if case .data(let data) = read(name, at: url), !data.isEmpty { return data }
        return nil
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

    /// In an extension: whether its store is the one the app reads (the app group), so the app can promote what the
    /// extension keeps. False in the app itself (it has a visible root, or it is the Mac until wave M, where
    /// `FolderSync` copies and the hidden copy is cache) and in an extension with no app group (the owner's phone).
    static func storeIsSharedWithApp() -> Bool {
        #if os(iOS)
        return Bundle.main.bundleURL.pathExtension == "appex" && AppGroup.location.kind == .appGroup
        #else
        return false
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
        var unreadable = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            let tag: OfflineTag?
            switch OfflineTag.probe(at: url) {
            case .tag(let found): tag = found
            case .untagged: tag = nil
            case .unreadable: unreadable += 1; tag = nil
            }
            out.append(VisibleEntry(
                path: relative, size: Int64(values.fileSize ?? 0), tag: tag,
                excludedFromBackup: values.isExcludedFromBackup ?? false))
        }
        // A tag that cannot be read (data protection, a permission) is not "no tag": the answer is unknown, so
        // nothing may be concluded from this pass (review fix S4).
        if unreadable > 0 {
            Telemetry.log(.warn, .store, "offline scan tag unreadable", data: ["files": .int(unreadable)])
            return nil
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

    /// Deletes one file of the visible root (the caller has checked it is cobalt's). On failure the tag is taken
    /// off so the file is the owner's from then on (a tagged file with no record would be adopted again by the
    /// next scan). False: still there.
    static func deleteFile(_ url: URL, ops: any OfflineFileOps) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try ops.remove(url)
            removeEmptyGalleryFolder(url.deletingLastPathComponent())
            return true
        } catch {
            XAttr.remove(OfflineTag.attribute, at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// The last file of a gallery's folder went: the folder goes too, when it is one cobalt made (it carries the folder
    /// tag) and holds nothing else. A folder the owner made, or one with their files in it, is never touched.
    static func removeEmptyGalleryFolder(_ folder: URL) {
        guard XAttr.get(folderAttribute, at: folder) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              names.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The same file (device and inode), not just the same name: a case-insensitive volume answers one file for
    /// `rome.mp4` and `Rome.mp4`, a case-sensitive one two.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var x = stat(), y = stat()
        let first = a.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &x) } ?? -1 }
        let second = b.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &y) } ?? -1 }
        return first == 0 && second == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
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
        /// A gallery's folder (apple/CONTRACT-GALLERY.md 1.8): the folder the file goes into, named by `FolderNaming`;
        /// nil = the root. One folder per media: a folder that already carries this media's tag is reused.
        var folder: String?
        var media: String = ""
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
        var folders: [String: String] = [:]
        var results: [(id: String, outcome: MoveOutcome)] = []
        for request in requests {
            guard ops.size(of: request.source) != nil else {
                results.append((request.id, .missing))
                continue
            }
            do {
                let path = try moveOne(request, root: root, taken: &taken, folders: &folders, ops: ops)
                let destination = root.appendingPathComponent(path)
                if request.excludeFromBackup { excludeFromBackup(destination) }
                results.append((request.id, .moved(
                    path: path, name: (path as NSString).lastPathComponent, bytes: ops.size(of: destination) ?? 0)))
            } catch let interrupted as OfflineInterrupted {
                throw interrupted
            } catch {
                results.append((request.id, .failed(String(describing: error))))
            }
        }
        return results
    }

    /// The extended attribute on a gallery's folder: the media it holds. `rename(2)` keeps it, so the owner may rename
    /// the folder in Files and the next file of the media still goes into it.
    static let folderAttribute = "com.capybaraharmony.cobalt.folder"

    /// The folder of a gallery media: one already carrying its tag, else a new one named `preferred` (a clash gets
    /// ` (2)`), tagged. `taken` holds the root's names, lowercased; `folders` what this pass already chose.
    static func galleryFolder(
        media: String, preferred: String, root: URL, taken: inout Set<String>, folders: inout [String: String]
    ) throws -> String {
        let fm = FileManager.default
        if let known = folders[media], fm.fileExists(atPath: root.appendingPathComponent(known).path) { return known }
        if !media.isEmpty, let names = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in names.sorted() {
                let url = root.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      let data = XAttr.get(folderAttribute, at: url), String(decoding: data, as: UTF8.self) == media else { continue }
                folders[media] = name
                return name
            }
        }
        let name = FolderNaming.unique(preferred, among: taken)
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try? XAttr.set(folderAttribute, Data(media.utf8), at: url)
        taken.insert(name.lowercased())
        folders[media] = name
        return name
    }

    private static func moveOne(
        _ request: MoveRequest, root: URL, taken: inout Set<String>, folders: inout [String: String], ops: any OfflineFileOps
    ) throws -> String {
        try ops.setTag(request.tag, at: request.source)                                  // step 1
        try ops.checkpoint(.tagged)
        var lastError: (any Error)?
        for _ in 0..<6 {
            var directory = root
            var prefix = ""
            var inDirectory = taken
            if let folder = request.folder {
                let chosen = try galleryFolder(media: request.media, preferred: folder, root: root, taken: &taken, folders: &folders)
                directory = root.appendingPathComponent(chosen, isDirectory: true)
                prefix = chosen + "/"
                inDirectory = names(in: directory)
            }
            let name = FolderNaming.unique(request.preferredName, among: inDirectory)         // step 2
            let destination = directory.appendingPathComponent(name)
            do {
                try place(request, at: destination, root: root, ops: ops)               // step 3
                if request.folder == nil { taken.insert(name.lowercased()) }
                return prefix + name
            } catch let error as POSIXError where error.code == .EEXIST {
                if request.folder == nil { taken.insert(name.lowercased()) }              // someone took it meanwhile
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
    ///
    /// `tombstones` are the ids cobalt itself removed (`OfflineTombstones`): a tagged file with one of them that no
    /// record points at is a copy the owner made, so it is the owner's own file (never adopted or rebuilt).
    static func reconcile(
        _ records: inout [OfflineStore.Record], entries: [VisibleEntry], hiddenRoot: URL, now: Date,
        tombstones: Set<String> = []
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
            var found = byID[record.id] ?? []
            if record.visiblePath == nil, tombstones.contains(record.id), !found.isEmpty {
                out.report.untracked += found.count                  // copies of a file cobalt removed: the owner's
                found = []
            }
            guard !found.isEmpty else {
                if record.visiblePath != nil {                       // deleted, or moved out
                    records[i].visiblePath = nil
                    records[i].givenName = nil
                    records[i].keep = false
                    out.report.unkept += 1
                }
                continue
            }
            // the recorded path wins (a duplicate is the owner's); else the first in sorted order
            let chosen = found.first { $0.path == record.visiblePath } ?? found[0]
            if let cache = record.fileName {
                // A copy that crashed after its rename: the same file is in both places. The cache one goes only
                // when the visible one is whole (same size); unsure, both stay and the record keeps the cache one.
                // A cache file that is not there any more leaves the visible copy as the file.
                if let cacheSize = fileSize(hiddenRoot.appendingPathComponent("files/\(cache)")) {
                    guard cacheSize == chosen.size else { continue }
                    out.dropCache.append(cache)
                }
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
            if tombstones.contains(id) {
                out.report.untracked += matches.count                // a copy of media cobalt removed: the owner's file
                continue
            }
            guard let tag = matches[0].tag else { continue }
            let entry = matches[0]
            let stem = ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let explicit = tag.media
            var media = explicit
            if records.contains(where: { $0.media == explicit }) {
                let hasOriginal = records.contains { $0.media == explicit && $0.isPlainOriginal }
                if tag.kind == .original && tag.role == nil && hasOriginal { media = id }
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
                keep: true, visiblePath: entry.path, givenName: nil,
                role: tag.role, itemIndex: tag.item, libraryID: tag.lib)
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
        // An index this build cannot decode is not "lost": reading nothing from it and writing a rebuilt one over it
        // would erase every record the tags cannot bring back (review fix S1).
        let before: [OfflineStore.Record]
        do { before = try OfflineStore.readRecordsChecked(root: hiddenRoot) } catch {
            return ScanResult(records: [], report: OfflineScanReport(indexUnreadable: true), rebuilt: [], wrote: false)
        }
        purgeStaleParts(root: visibleRoot, now: now)
        guard let entries = enumerate(root: visibleRoot) else {
            // never "every file deleted": nothing changes
            return ScanResult(records: before, report: OfflineScanReport(rootMissing: true), rebuilt: [], wrote: false)
        }
        let tombstones = OfflineTombstones.ids(root: hiddenRoot)
        var probe = before
        var reconciled = reconcile(&probe, entries: entries, hiddenRoot: hiddenRoot, now: now, tombstones: tombstones)
        var records = before
        var wrote = false
        if probe != before {
            // something changed: apply it to the index as it is right now, in one coordinated write
            var again = Reconciled()
            if let written = try? OfflineStore.mutate(root: hiddenRoot, { current in
                again = reconcile(&current, entries: entries, hiddenRoot: hiddenRoot, now: now, tombstones: tombstones)
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

    enum RemoveResult: Sendable, Equatable {
        /// the record's file was cobalt's (its tag said so) and is deleted
        case removed
        /// the record has no file in the root (or it is gone, and the scan found it nowhere): nothing to delete
        case absent
        /// a file is there that is not provably the record's (the owner's own, another media's, a tag that cannot be
        /// read), or the root or index could not be read: nothing was deleted
        case refused
    }

    /// Deletes the visible file of record `id`, by identity and not by remembered name (review fix B1). Inside the
    /// gate (the caller's). The path is re-read from the index, and the file at it must carry `id` as its tag;
    /// when it does not (the owner renamed or swapped files in Files since the last scan), one scan settles the
    /// paths and it is tried once more, and when the file at the path still is not the record's it is left alone.
    /// A deleted file's id goes on the tombstones, so a duplicate the owner made is not taken for the original.
    @concurrent
    static func removeVisibleChecked(
        hiddenRoot: URL, visibleRoot: URL, id: String, ops: any OfflineFileOps, now: Date
    ) async -> RemoveResult {
        for attempt in 0..<2 {
            let index: [OfflineStore.Record]
            do { index = try OfflineStore.readRecordsChecked(root: hiddenRoot) } catch { return .refused }
            guard let path = index.first(where: { $0.id == id })?.visiblePath else { return .absent }
            let url = visibleRoot.appendingPathComponent(path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                switch OfflineTag.probe(at: url) {
                case .tag(let tag) where tag.id == id:
                    guard deleteFile(url, ops: ops) else { return .refused }
                    OfflineTombstones.add([id], root: hiddenRoot, now: now)
                    return .removed
                case .unreadable:
                    return .refused
                default:
                    break                                          // the owner's file, or another media's
                }
            }
            if attempt == 1 { return exists ? .refused : .absent }
            let settled = await scan(hiddenRoot: hiddenRoot, visibleRoot: visibleRoot, now: now, ops: ops)
            if settled.report.rootMissing || settled.report.indexUnreadable { return .refused }
        }
        return .refused
    }

    /// `removeVisibleChecked` for several records (a media's, "delete everything"): the ids that were refused.
    @concurrent
    static func purge(
        ids: [String], hiddenRoot: URL, visibleRoot: URL, ops: any OfflineFileOps, now: Date
    ) async -> Set<String> {
        var refused: Set<String> = []
        for id in ids
        where await removeVisibleChecked(hiddenRoot: hiddenRoot, visibleRoot: visibleRoot, id: id, ops: ops, now: now) == .refused {
            refused.insert(id)
        }
        return refused
    }

    struct RemoveCopyOutcome: Sendable {
        var records: [OfflineStore.Record]?
        /// a file was dropped
        var had = false
        /// the file could not be proved the record's, or the index or root could not be read: nothing changed
        var refused = false
    }

    /// "remove offline copy" (decision 10), inside the gate in both tiers, so it never lands between a
    /// promotion's move and its index write (review fix S5). The visible file goes first (by identity), then the
    /// index (`keep = false`, no path, no file name), then the cache file.
    @concurrent
    static func removeCopy(
        id: String, hiddenRoot: URL, visibleRoot: URL?, ops: any OfflineFileOps, now: Date
    ) async -> RemoveCopyOutcome {
        var out = RemoveCopyOutcome()
        let index: [OfflineStore.Record]
        do { index = try OfflineStore.readRecordsChecked(root: hiddenRoot) } catch { out.refused = true; return out }
        guard let current = index.first(where: { $0.id == id }) else { return out }
        if current.visiblePath != nil {
            // an extension never touches the visible folder
            guard let visibleRoot else { out.refused = true; return out }
            // The file goes first: a record without a path but with a tagged file still in the root would be
            // "restored" by the next scan.
            switch await removeVisibleChecked(hiddenRoot: hiddenRoot, visibleRoot: visibleRoot, id: id, ops: ops, now: now) {
            case .refused:
                out.refused = true
                out.records = try? OfflineStore.readRecordsChecked(root: hiddenRoot)     // the scan may have moved paths
                return out
            case .removed, .absent: break
            }
        }
        var name: String?
        out.records = try? OfflineStore.mutate(root: hiddenRoot) { records in
            guard let i = records.firstIndex(where: { $0.id == id }) else { return }
            name = records[i].fileName
            records[i].fileName = nil
            records[i].visiblePath = nil
            records[i].givenName = nil
            records[i].keep = false
        }
        guard out.records != nil else { out.refused = true; return out }
        // The index is written first; only then does the cache file go (a reader never sees a record
        // pointing at a deleted file).
        if let name { OfflineStore.delete(OfflineStore.Eviction(files: [name]), root: hiddenRoot) }
        out.had = current.visiblePath != nil || name != nil               // as before: a record that had a file
        return out
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
        // never move a file into an index that cannot be written (it would be adopted, but only once it can be read)
        guard (try? OfflineStore.readRecordsChecked(root: hiddenRoot)) != nil else {
            outcome.failed = requests.count
            return outcome
        }
        // keeping these again is the owner's new wish: a copy left from an earlier removal counts as theirs no more
        OfflineTombstones.remove(Set(requests.map(\.id)), root: hiddenRoot)
        let sources = Dictionary(requests.map { ($0.id, $0.source.lastPathComponent) }, uniquingKeysWith: { first, _ in first })
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
            var strays: [(id: String, url: URL)] = []
            let written = try? OfflineStore.mutate(root: hiddenRoot) { records in
                for result in results {
                    guard case .moved(let path, let name, let bytes) = result.outcome else { continue }
                    // The record must still be what was moved: present, still kept, still pointing at the file that
                    // moved. Else the owner (or another writer) changed their mind while it moved, and the index
                    // does not put the record back (review fix S5): the file that landed goes out again.
                    guard let i = records.firstIndex(where: { $0.id == result.id }),
                          records[i].keep == true, records[i].fileName == sources[result.id]
                    else {
                        strays.append((result.id, visibleRoot.appendingPathComponent(path)))
                        continue
                    }
                    records[i].fileName = nil
                    records[i].visiblePath = path
                    records[i].givenName = name
                    records[i].keep = true
                    if bytes > 0 { records[i].bytes = bytes }
                }
            }
            for stray in strays {                                              // only a file that is provably the record's
                if case .tag(let tag) = OfflineTag.probe(at: stray.url), tag.id == stray.id { try? ops.remove(stray.url) }
            }
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
        // The plan was made on the main actor from the index in memory: the owner may have renamed or replaced
        // files in Files since. Every item is checked again here, against the index and the file's own tag
        // (review fix B1): only a file that is provably the record's, still under the name cobalt gave it, moves.
        guard let index = try? OfflineStore.readRecordsChecked(root: hiddenRoot) else { return nil }
        var done: [(id: String, from: String, to: String)] = []
        for item in plan {
            let folderPath = (item.path as NSString).deletingLastPathComponent
            let folder = folderPath.isEmpty ? visibleRoot : visibleRoot.appendingPathComponent(folderPath, isDirectory: true)
            let current = (item.path as NSString).lastPathComponent
            guard let record = index.first(where: { $0.id == item.id }), record.visiblePath == item.path,
                  record.givenName == current else { continue }
            let from = visibleRoot.appendingPathComponent(item.path)
            guard ops.size(of: from) != nil, case .tag(let tag) = OfflineTag.probe(at: from), tag.id == item.id else { continue }
            // The folder's names, lowercased (the clash check is case-insensitive). Our own name is not a clash,
            // unless a distinct file shares its lowercase form (a case-sensitive volume): `listing` says which.
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var taken = Set(listing.map { $0.lowercased() })
            if listing.filter({ $0.lowercased() == current.lowercased() }) == [current] { taken.remove(current.lowercased()) }
            let name = FolderNaming.unique(item.preferredName, among: taken)
            guard name != current else { continue }
            let destination = folder.appendingPathComponent(name)
            do {
                // Never over an existing file: exclusive, always. A change of case only reads as "exists" on a
                // case-insensitive volume, where it is the same file: that one, and only that one, is renamed plainly.
                do { try ops.rename(from, to: destination, exclusive: true) } catch let error as POSIXError where error.code == .EEXIST {
                    guard name.lowercased() == current.lowercased(), sameFile(from, destination) else { throw error }
                    try ops.rename(from, to: destination, exclusive: false)
                }
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
