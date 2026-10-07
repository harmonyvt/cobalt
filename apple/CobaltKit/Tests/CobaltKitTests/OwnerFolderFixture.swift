import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The Mac's folder as a fixture (CONTRACT-OFFLINE.md 13.13.1): the owner's real `~/Movies/cobalt` and store as read on
// 2026-10-07 (names, ledger keys, kinds, media ids, the gallery folder's tag, the two gallery files' leaked backup
// exclusion, the legacy / wave-1 record split, sizes scaled down), built in temp directories with `rootMode: .macFolder`.
// Nothing here ever names the real home.

// MARK: - xattrs and snapshots

enum FileAttributes {
    /// Every extended attribute of `url`: name → bytes, sorted by name.
    static func all(_ url: URL) -> [(name: String, value: Data)] {
        url.withUnsafeFileSystemRepresentation { path -> [(String, Data)] in
            guard let path else { return [] }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) >= 0 else { return [] }
            let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            return names.sorted().map { name in
                let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                var value = Data(count: max(n, 0))
                if n > 0 { _ = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, n, 0, XATTR_NOFOLLOW) } }
                return (name, value)
            }
        }
    }

    static func names(_ url: URL) -> [String] { all(url).map(\.name) }

    static func value(_ name: String, _ url: URL) -> Data? { all(url).first { $0.name == name }?.value }

    static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    static func setExcludedFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}

/// One entry of a folder walk: what "unchanged" means for the owner's files.
struct FolderEntrySnapshot: Equatable {
    var inode: UInt64
    var size: Int64
    var mtime: Date
    var isDirectory: Bool
    var attributes: [String]
    var attributeValues: [Data]
}

func snapshot(of root: URL) -> [String: FolderEntrySnapshot] {
    let fm = FileManager.default
    var out: [String: FolderEntrySnapshot] = [:]
    let prefix = root.resolvingSymlinksInPath().path + "/"
    guard let walker = fm.enumerator(atPath: root.path) else { return out }
    for case let relative as String in walker {
        let url = root.appendingPathComponent(relative)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { continue }
        let attrs = FileAttributes.all(url)
        out[relative] = FolderEntrySnapshot(
            inode: UInt64(st.st_ino), size: Int64(st.st_size),
            mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9),
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR, attributes: attrs.map(\.name), attributeValues: attrs.map(\.value))
    }
    _ = prefix
    return out
}

// MARK: - the rig

/// One seeded item: a record, its hidden copy, its file in the folder and its ledger entry. Everything optional is
/// "absent": a nil `folderFile` has no file in the folder, a nil `cacheData` is an evicted hidden copy, a nil `entry` has no
/// ledger entry.
struct SeedItem {
    var id: String
    var key: String
    var kind: StoredVideo.Kind = .original
    var session: String?
    var remote: URL?
    var link: URL?
    var role: GalleryRole?
    var itemIndex: Int?
    var media: String?
    var libraryID: String?
    var postItems: Int?
    var folderFile: String?
    var cacheData: Data?
    var folderData: Data?
    var keep: Bool?
    var entry: FolderEntry?
    var mtime = Date(timeIntervalSince1970: 1_790_000_000)
    var ext = "mp4"
    var title: String?
}

@MainActor
final class MacRig {
    /// the whole world of a test
    let base: URL
    /// the visible root: the folder in Finder
    let folder: URL
    /// the hidden store
    let hidden: URL
    /// `Sync/`: the ledgers and the adoption marker
    let sync: URL
    let ledger: FolderLedger
    let defaults: UserDefaults
    let trash = TrashBin()
    private var records: [OfflineStore.Record] = []
    private var entries: [String: FolderEntry] = [:]

    init(folderName: String = "Movies/cobalt", createFolder: Bool = true) throws {
        base = try makeTempDirectory().resolvingSymlinksInPath()
        folder = base.appendingPathComponent(folderName, isDirectory: true)
        hidden = base.appendingPathComponent("Application Support/Videos", isDirectory: true)
        sync = base.appendingPathComponent("Application Support/Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden.appendingPathComponent("files"), withIntermediateDirectories: true)
        if createFolder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        ledger = FolderLedger(directory: sync)
        let suite = "cobalt.macfolder.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: seeding

    func data(_ seed: UInt8, count: Int) -> Data {
        // distinct, non-repeating-looking bytes so a byte comparison means something
        var bytes = [UInt8](repeating: 0, count: count)
        var x = UInt32(seed) &* 2654435761 &+ 1
        for i in 0..<count { x = x &* 1664525 &+ 1013904223; bytes[i] = UInt8(truncatingIfNeeded: x >> 24) }
        return Data(bytes)
    }

    @discardableResult
    func seed(_ item: SeedItem) throws -> SeedItem {
        let fm = FileManager.default
        var item = item
        let cacheName = item.cacheData != nil ? "\(item.id).\(item.ext)" : nil
        if let cacheData = item.cacheData, let cacheName {
            let url = hidden.appendingPathComponent("files/\(cacheName)")
            try cacheData.write(to: url)
            try fm.setAttributes([.modificationDate: item.mtime], ofItemAtPath: url.path)
        }
        if let file = item.folderFile {
            let url = folder.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = item.folderData ?? item.cacheData ?? data(1, count: 100)
            try bytes.write(to: url)
            try fm.setAttributes([.modificationDate: item.mtime], ofItemAtPath: url.path)
        }
        let size = Int64(item.folderData?.count ?? item.cacheData?.count ?? 100)
        records.append(OfflineStore.Record(
            id: item.id, kind: item.kind, fileName: cacheName, posterName: nil, name: item.title ?? item.id, duration: 5, width: 720,
            height: 1280, bytes: size, sessionID: item.session, link: item.link, remoteURL: item.remote,
            createdAt: item.mtime, addedAt: item.mtime, mediaID: item.media, title: item.title, keep: item.keep,
            role: item.role, itemIndex: item.itemIndex, libraryID: item.libraryID, postItems: item.postItems))
        if let entry = item.entry { entries[item.key] = entry }
        return item
    }

    /// A ledger entry as FolderSync wrote it.
    func done(_ file: String, bytes: Int, at: Date = Date(timeIntervalSince1970: 1_790_100_000)) -> FolderEntry {
        FolderEntry(state: .done, at: at, file: file, bytes: Int64(bytes))
    }

    /// Writes the index and `folder.json` (one section for the folder, as FolderSync left it) and returns the ledger file's bytes.
    @discardableResult
    func commit() throws -> Data {
        try JSONEncoder().encode(records).write(to: OfflineStore.indexURL(root: hidden), options: .atomic)
        var state = FolderStateFile()
        state.sections[FolderLedger.defaultID] = FolderSection(path: folder.path, items: entries)
        let bytes = try JSONEncoder().encode(state)
        try bytes.write(to: ledger.url, options: .atomic)
        return bytes
    }

    func ledgerBytes() throws -> Data { try Data(contentsOf: ledger.url) }

    // MARK: the store

    func store(
        ops: TestFileOps? = nil, provider: Bool = true, root: URL? = nil, ledgerOverride: FolderLedger? = nil
    ) -> OfflineStore {
        var useOps = ops ?? TestFileOps()
        if useOps.trash == nil { useOps.trash = trash }
        let theLedger = ledgerOverride ?? ledger
        let store = OfflineStore(
            root: hidden, tools: OfflineTools(), defaults: defaults, now: { Date(timeIntervalSince1970: 1_790_200_000) },
            visibleRoot: provider ? nil : (root ?? folder), ops: useOps, syncDirectory: sync, sharedWithApp: false,
            rootMode: .macFolder, rootProvider: provider ? MacRootProvider(ledger: theLedger, defaultFolder: folder) : nil,
            folderLedger: theLedger)
        return store
    }

    func index() -> [OfflineStore.Record] { OfflineStore.readRecords(root: hidden) }
    func record(_ id: String) -> OfflineStore.Record? { index().first { $0.id == id } }
    func cacheFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: hidden.appendingPathComponent("files").path)) ?? []).sorted()
    }
    func tag(_ relative: String, in root: URL? = nil) -> OfflineTag? { OfflineTag.read(at: (root ?? folder).appendingPathComponent(relative)) }
    func exists(_ relative: String, in root: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (root ?? folder).appendingPathComponent(relative).path)
    }

    /// Every regular file under `root`, relative, sorted (hidden ones included).
    func files(in root: URL? = nil) -> [String] {
        let dir = root ?? folder
        guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        var out: [String] = []
        for case let relative as String in walker {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                out.append(relative)
            }
        }
        return out.sorted()
    }
}

// MARK: - the owner's folder

/// The owner's Mac, 2026-10-07 (CONTRACT-OFFLINE.md 13.0): 6 top-level files (5 mp4 and a webp), the gallery folder
/// `instagram · DeKlsGCGZmx/` with `01.jpg` and `02.mp4`, 8 `done` ledger entries, 8 records (6 legacy, `keep` absent; 2
/// gallery items, `keep: false`), every hidden copy at the folder file's size and mtime, the two gallery files carrying the
/// backup exclusion cobalt leaked, and the gallery folder tagged with its media id.
@MainActor
struct OwnerFolder {
    let rig: MacRig
    let items: [SeedItem]
    let ledgerBytes: Data
    /// the owner's own files, not in the ledger
    let ownerAdded = "holiday.mov"
    let renamedTo = "my clip.mp4"
    let galleryFolder = "instagram · DeKlsGCGZmx"
    let galleryMedia = "f9cb8f6f-3a1c-4e07-9d52-6b8f0a2c7e11"

    static let legacyNames = [
        "instagram · DeGGagYNxfv.mp4", "instagram · DeHC9jcpfQW.mp4", "x · 2107221792188231716.mp4",
        "x · 2105435404002562056.mp4", "tiktok · 7391234567890123456.mp4",
    ]
    static let webpName = "instagram · DeHC9jcpfQW · webp 1.webp"
    static let webpURL = URL(string: "https://media.capybaraharmony.com/RByDDgGWTN.webp")!
    static let gallerySession = "7mKytvtqJDuJtCIVxRA2jN"

    /// `renamed`: the owner renamed `x · 2107221792188231716.mp4` to `my clip.mp4` (the ledger still names the old one);
    /// `ownerFile`: the owner dropped `holiday.mov` into the folder.
    init(renamed: Bool = true, ownerFile: Bool = true) throws {
        rig = try MacRig()
        var out: [SeedItem] = []
        let t0 = Date(timeIntervalSince1970: 1_789_000_000)
        for (n, name) in Self.legacyNames.enumerated() {
            let size = 2_000 + n * 777
            let bytes = rig.data(UInt8(10 + n), count: size)
            let isInstagram = name.hasPrefix("instagram")
            var item = SeedItem(
                id: "00000000-0000-4000-8000-00000000000\(n + 1)", key: "s:SESSION\(n + 1)", session: "SESSION\(n + 1)",
                link: URL(string: isInstagram ? "https://www.instagram.com/reel/\(name.dropFirst(12).prefix(11))/" : "https://x.com/i/status/\(n)"),
                folderFile: name, cacheData: bytes, keep: nil, mtime: t0.addingTimeInterval(Double(n) * 3_600))
            item.entry = rig.done(name, bytes: size, at: t0.addingTimeInterval(Double(n) * 3_600 + 60))
            out.append(item)
        }
        // the webp of the second original (same session: one media)
        let webpBytes = rig.data(40, count: 1_500)
        var webp = SeedItem(
            id: "00000000-0000-4000-8000-000000000006", key: "w:\(Self.webpURL.absoluteString)", kind: .webp, session: "SESSION2",
            remote: Self.webpURL, link: out[1].link, folderFile: Self.webpName, cacheData: webpBytes, keep: nil,
            mtime: t0.addingTimeInterval(7 * 3_600), ext: "webp")
        webp.entry = rig.done(Self.webpName, bytes: 1_500, at: t0.addingTimeInterval(7 * 3_600 + 60))
        out.append(webp)
        // the gallery: two items of one post, wave 1 (keep false), the folder tagged with the media id
        for (n, (leaf, ext)) in [("01.jpg", "jpg"), ("02.mp4", "mp4")].enumerated() {
            let size = 3_000 + n * 411
            var item = SeedItem(
                id: "00000000-0000-4000-8000-00000000000\(n + 7)", key: "g:\(Self.gallerySession):\(n)", session: Self.gallerySession,
                link: URL(string: "https://www.instagram.com/p/DeKlsGCGZmx/"), role: .item, itemIndex: n, media: galleryMedia,
                libraryID: "lib-\(n)", postItems: 2, folderFile: "\(galleryFolder)/\(leaf)", cacheData: rig.data(UInt8(60 + n), count: size),
                keep: false, mtime: t0.addingTimeInterval(Double(8 + n) * 3_600), ext: ext)
            item.entry = rig.done("\(galleryFolder)/\(leaf)", bytes: size, at: t0.addingTimeInterval(Double(8 + n) * 3_600 + 60))
            out.append(item)
        }
        for item in out { try rig.seed(item) }
        items = out
        try rig.commit()
        ledgerBytes = try rig.ledgerBytes()

        let fm = FileManager.default
        let gallery = rig.folder.appendingPathComponent(galleryFolder, isDirectory: true)
        try XAttr.set(OfflineFolder.folderAttribute, Data(galleryMedia.utf8), at: gallery)
        for leaf in ["01.jpg", "02.mp4"] { FileAttributes.setExcludedFromBackup(gallery.appendingPathComponent(leaf)) }
        if renamed {
            try fm.moveItem(at: rig.folder.appendingPathComponent(Self.legacyNames[2]), to: rig.folder.appendingPathComponent(renamedTo))
        }
        if ownerFile {
            let holiday = rig.folder.appendingPathComponent(ownerAdded)
            try rig.data(99, count: 2_500).write(to: holiday)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: holiday.path)
            FileAttributes.setExcludedFromBackup(holiday)                       // theirs, so it must stay as it is
        }
    }

    /// The store, as the Mac app builds it.
    func store(ops: TestFileOps? = nil) -> OfflineStore { rig.store(ops: ops) }

    var adoptableIDs: [String] { items.filter { $0.id != items[2].id }.map(\.id) }
    var renamedID: String { items[2].id }
}
