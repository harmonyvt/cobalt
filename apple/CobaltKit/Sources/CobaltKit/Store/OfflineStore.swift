import Foundation
import Synchronization
import Observation
import UniformTypeIdentifiers

public struct StoredVideo: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case original, webp }
    public var id: String
    public var kind: Kind
    public var fileURL: URL?        // nil when only the poster is kept
    public var posterURL: URL?      // JPEG, 360 px long edge
    public var name: String
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var bytes: Int64
    public var sessionID: String?
    public var link: URL?
    public var remoteURL: URL?
    public var createdAt: Date
    /// The flipbook: ~12 evenly spaced JPEG frames, long edge <= 160 px, in play order. Empty until
    /// generated (`OfflineStore.ensurePreviewFrames(for:)`), and always empty for still images.
    /// Kept when the video file is evicted.
    public var previewFrameURLs: [URL] = []
    /// The public link of this video's hosted original ("public share"), once a host-original
    /// publish for its session finished (attached or detached). Persisted in the index; nil for an
    /// entry that was never shared and for an index written before this existed.
    public var publicURL: URL?
    /// The media this record belongs to (CONTRACT-MEDIA 1.2): an opaque local id, the id of the media's
    /// first record. Never empty: a record the index has no `mediaID` for yet reads as its own `id`.
    public var mediaID: String
    /// What a webp was made from, when this device made it (`.webp` only).
    public var clip: WebpClip?
    /// The owner's title for this media (CONTRACT-LIBRARY2 decision 8). Every record of a media carries
    /// the same value (`OfflineStore.setTitle(_:media:)`); nil = no custom title, the default shows.
    /// `decodeIfPresent`: an index written before titles existed decodes as nil.
    public var title: String?
    /// Where the file is (CONTRACT-OFFLINE.md decision 3): `.cache` is the hidden `files/` folder (a kept file
    /// that is waiting to move in is there too), `.offline` the visible folder (Files on iOS). Nil: there is
    /// no file on this device. `fileURL` can be nil while `place == .offline`: the share extension cannot open
    /// the app's Documents.
    public var place: Place?
    /// The owner wants this on the device: never evicted by the cache limit. A record can be kept and have no
    /// file yet (a download is on its way).
    public var keep: Bool
    /// The file is here and the owner keeps it.
    public var isOffline: Bool { keep && place != nil }
    /// Where this record sits in its media's post (apple/CONTRACT-GALLERY.md 4). Nil on everything that predates
    /// galleries and on every plain original and webp.
    /// `.item`: one original of a gallery (`itemIndex` is its place in the post); `.slideshow`, `.export` (a gallery
    /// image) and `.crop`: a file made from the post (a slideshow webp is `kind .webp`, the rest `kind .original`).
    public var role: GalleryRole?
    /// The item's index in the post (0-based) for `.item`; nil otherwise.
    public var itemIndex: Int?
    /// The item indices a made file or a webp of an item was made from.
    public var madeFrom: [Int]?
    /// The JSON spec a made file was made with (`MadeSpec`); at most 512 bytes.
    public var madeSpec: Data?
    /// The server's library row for this file (an item or a made file), when known: what a download and a replace
    /// are keyed by. Nil for everything else.
    public var libraryID: String?
    /// How many items the post had when this item was kept (a gallery's items; nil elsewhere and on older records). It lets
    /// the folder rule tell a single pasted photo (a flat file) from the first item of a gallery that is still arriving.
    public var postItems: Int?

    public enum Place: String, Sendable, Codable { case cache, offline }

    public init(
        id: String, kind: Kind, fileURL: URL?, posterURL: URL?, name: String, duration: Double?,
        width: Int?, height: Int?, bytes: Int64, sessionID: String?, link: URL?, remoteURL: URL?,
        createdAt: Date, previewFrameURLs: [URL] = [], publicURL: URL? = nil, mediaID: String? = nil,
        clip: WebpClip? = nil, title: String? = nil, place: Place? = nil, keep: Bool = false,
        role: GalleryRole? = nil, itemIndex: Int? = nil, madeFrom: [Int]? = nil, madeSpec: Data? = nil, libraryID: String? = nil,
        postItems: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.posterURL = posterURL
        self.name = name
        self.duration = duration
        self.width = width
        self.height = height
        self.bytes = bytes
        self.sessionID = sessionID
        self.link = link
        self.remoteURL = remoteURL
        self.createdAt = createdAt
        self.previewFrameURLs = previewFrameURLs
        self.publicURL = publicURL
        self.mediaID = mediaID.flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.clip = clip
        self.title = title
        // a file with no stated place is a cache file (every pre-offline caller)
        self.place = place ?? (fileURL != nil ? .cache : nil)
        self.keep = keep
        self.role = role
        self.itemIndex = itemIndex
        self.madeFrom = madeFrom
        self.madeSpec = madeSpec
        self.libraryID = libraryID
        self.postItems = postItems
    }

    /// The kind of made file this is (the key a remake replaces); nil for anything else.
    public var madeKind: MadeKind? {
        guard let role, role != .item else { return nil }
        return MadeKind(role: role, spec: madeSpec.flatMap { MadeSpec(data: $0) })
    }
}

extension StoredVideo {
    /// A value written before the flipbook (or the media id) existed lacks those keys.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
            fileURL: try c.decodeIfPresent(URL.self, forKey: .fileURL),
            posterURL: try c.decodeIfPresent(URL.self, forKey: .posterURL), name: try c.decode(String.self, forKey: .name),
            duration: try c.decodeIfPresent(Double.self, forKey: .duration),
            width: try c.decodeIfPresent(Int.self, forKey: .width), height: try c.decodeIfPresent(Int.self, forKey: .height),
            bytes: try c.decode(Int64.self, forKey: .bytes), sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
            link: try c.decodeIfPresent(URL.self, forKey: .link), remoteURL: try c.decodeIfPresent(URL.self, forKey: .remoteURL),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            previewFrameURLs: try c.decodeIfPresent([URL].self, forKey: .previewFrameURLs) ?? [],
            publicURL: try c.decodeIfPresent(URL.self, forKey: .publicURL),
            mediaID: try c.decodeIfPresent(String.self, forKey: .mediaID),
            clip: try c.decodeIfPresent(WebpClip.self, forKey: .clip),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            place: try c.decodeIfPresent(Place.self, forKey: .place),
            keep: try c.decodeIfPresent(Bool.self, forKey: .keep) ?? false,
            // a role this build does not know (a later one wrote it) reads as none: one record must not make the index unreadable
            role: (try? c.decodeIfPresent(GalleryRole.self, forKey: .role)) ?? nil,
            itemIndex: try c.decodeIfPresent(Int.self, forKey: .itemIndex),
            madeFrom: try c.decodeIfPresent([Int].self, forKey: .madeFrom),
            madeSpec: try c.decodeIfPresent(Data.self, forKey: .madeSpec),
            libraryID: try c.decodeIfPresent(String.self, forKey: .libraryID),
            postItems: try c.decodeIfPresent(Int.self, forKey: .postItems))
    }
}

public struct StorageUsage: Sendable, Equatable {
    /// Records that have a file.
    public var count: Int
    public var bytes: Int64
    /// Media with at least one file (CONTRACT-MEDIA 1.14): what "13 videos · 54 MB" counts.
    public var mediaCount: Int

    /// `mediaCount` defaults to `count` (one record per media).
    public init(count: Int, bytes: Int64, mediaCount: Int? = nil) {
        self.count = count
        self.bytes = bytes
        self.mediaCount = mediaCount ?? count
    }
}

public enum OfflineStoreError: Error, Sendable, Equatable {
    /// `attach(file:to:move:)` for an entry that is not in the index (removed, or never there).
    case notFound
}

/// Videos kept on the device: the orbit's source. Files live under `root/files`, posters under
/// `root/posters`, incoming files under `root/inbox`, and the index in `root/index.json` (file
/// names are stored relative to `root` so a moved container still resolves).
///
/// **Two tiers** (CONTRACT-OFFLINE.md decision 3). A record the owner keeps (`keep`) has its file in the
/// **visible root** (`visibleRoot`: the app's `Documents`, "On My iPhone › cobalt" in Files; `visiblePath`,
/// relative to it) or, until it can move in, in `files/`. Anything else is **cache** in `files/`, which the
/// storage limit may take. `fileName` and `visiblePath` are never both set; `visiblePath != nil` implies
/// `keep`. A file in the visible root carries an extended attribute with its id (`OfflineTag`), so the
/// owner's renames and moves in Files are followed (`scanVisibleRoot()`, `OfflineFolder.reconcile`).
///
/// Next to each video's poster sits its **flipbook**: `root/previews/<id>-NN.jpg`, ~12 evenly spaced
/// frames (<= 160 px long edge) the orbit plays for items that are not worth a real player. They are
/// made when a video is added (animated webps too; still images get none), or later by
/// `ensurePreviewFrames(for:)` for entries that predate them. They count toward `usage`, survive the
/// eviction of the video file (like the poster), and go when the record goes.
///
/// The app and the share extension both write the index, so every read-modify-write runs under an
/// `NSFileCoordinator` and re-reads the file first.
///
/// **Storage limit** (CONTRACT-LIVE.md section 4). The limit lives in the app-group defaults
/// (`Settings.storageLimit`) and is re-read inside every enforcement. Enforcement runs inside the
/// same coordinated write as `add` / `attach`: the new record goes in, usage is computed over the
/// merged index, the oldest-added files are marked gone (`fileName = nil`), the index is written,
/// and only then are those files deleted (a concurrent reader never sees a record pointing at a
/// deleted file). Evicted entries keep their poster and record, so the orbit and the library still
/// show them; `attach` refills one with a fresh download. The newest 12 entries, the entry just
/// added and entries pinned by this process are never evicted.
@MainActor @Observable
public final class OfflineStore {
    @ObservationIgnored let root: URL
    /// The visible folder for kept files: `Documents` in the iOS app process, the Finder folder in the Mac app process
    /// (`.macFolder`: that URL whether or not it is reachable right now, 13.1); nil in every extension. It can change at
    /// run time on the Mac (the owner chose another folder): swapped only inside `OfflineFolderGate` by `setVisibleRoot`.
    /// Tests inject a temp directory.
    public internal(set) var visibleRoot: URL?
    /// Where `visibleRoot` comes from (13.1): every Mac-only rule is keyed on this, never on `#if`.
    @ObservationIgnored public let rootMode: VisibleRootMode
    /// Whether `visibleRoot` can be used right now (13.1, 13.6). Always `.ready` in `.documents`.
    public internal(set) var rootState: RootState = .ready
    /// A failed move into the root ran out of space (the Mac folder's "the disk is full" line); cleared by the next success.
    public internal(set) var rootDiskFull = false
    /// Adoption of what `FolderSync` wrote is running (13.3).
    public internal(set) var isAdopting = false
    /// The usable root (`visibleRoot` while `rootState == .ready`, else nil) as the gate's work reads it: a box any context
    /// can read, so entering the gate never waits for the main actor (a hop there would make every gate holder queue behind
    /// whatever else the main actor is doing). Written with the properties it mirrors, and by the gate's own swap.
    @ObservationIgnored let rootBox = OfflineRootBox()
    /// `.macFolder`: re-reads where the root is (the ledger's bookmark or path, the default folder) and who it is.
    @ObservationIgnored let rootProvider: MacRootProvider?
    /// `.macFolder`: the ledger FolderSync wrote, read (never written) by the adoption.
    @ObservationIgnored let folderLedger: FolderLedger?
    /// The root's security scope, held open for the life of the process and swapped with the root.
    @ObservationIgnored var rootAccess: FolderAccess?
    @ObservationIgnored let ops: any OfflineFileOps
    /// Whether a kept file in this store can ever reach the visible folder: this process has one, or it is an
    /// extension whose store the app also reads (the app group), where the app promotes. The Mac app always has one (its
    /// Finder folder, reachable or not, 13.1). A store nobody promotes from (the extension with no app group) takes nothing as kept: kept files
    /// are never evicted, so every one would stay forever (review fixes S2, S3). Its saves are cache.
    /// `shared()` decides it from the process (`OfflineFolder.storeIsSharedWithApp`); a store built directly (tests,
    /// previews) says so with `sharedWithApp` and defaults to a store that can keep.
    /// The UI hides every keep-offline control and offline state when this is false.
    @ObservationIgnored public let canKeep: Bool
    /// Where `offline.json` (the migration's marker) goes; nil in tests.
    @ObservationIgnored let syncDirectory: URL?
    /// Whether another part of the app still holds this studio session (a live share job or a pending
    /// original): promotion leaves such a record where it is. Set by `shared()`.
    @ObservationIgnored var sessionIsHeld: (@MainActor (String) -> Bool)?
    @ObservationIgnored var watcher: OfflineFolderWatcher?
    @ObservationIgnored let tools: any MediaTools
    /// Where the effective limit is read (the app group's defaults in the app and the extension).
    @ObservationIgnored let defaults: UserDefaults
    /// `addedAt` stamps; tests inject a clock.
    @ObservationIgnored let now: @Sendable () -> Date
    /// Previews show "13 videos · 54 MB" without 13 files on disk: this is added to what is.
    @ObservationIgnored var usageBase: StorageUsage?
    /// Previews: what `offlineUsage` shows without files on disk (added to what is).
    @ObservationIgnored var offlineUsageBase: OfflineUsage?
    /// Called after every `add` and `attach` that landed (the app's photos sync hooks in here; the
    /// share extension never sets it).
    @ObservationIgnored var onAdd: (@MainActor (StoredVideo, AddOrigin) -> Void)?
    /// Entries a running pipeline reads frames from or plays: never evicted while pinned.
    @ObservationIgnored private(set) var pins: [String: Int] = [:]
    /// The index as last read or written; `usage` sums it, with no disk I/O.
    @ObservationIgnored private(set) var records: [Record] = []
    /// Flipbooks being made right now, by entry id: a second `ensurePreviewFrames` joins the first.
    @ObservationIgnored private var previewJobs: [String: Task<Void, Never>] = [:]
    /// Entries whose flipbook could not be made this session (an unreadable file): not retried on every ask.
    @ObservationIgnored private var previewFailures: Set<String> = []

    public internal(set) var videos: [StoredVideo] = []   // newest first
    /// The same records grouped by media (CONTRACT-MEDIA 1.1), latest activity first; rebuilt in `adopt`.
    public internal(set) var media: [StoredMedia] = []

    /// Incoming files older than this are leftovers of a run that never finished.
    nonisolated static let inboxLifetime: TimeInterval = 24 * 60 * 60
    /// The newest entries (the orbit shows `latest(7)`, plus slack): never evicted.
    nonisolated static let protectedNewest = 12

    public convenience init(root: URL) {
        self.init(root: root, tools: SystemMediaTools())
    }

    init(
        root: URL, tools: any MediaTools, defaults: UserDefaults = AppGroup.defaults(),
        now: @escaping @Sendable () -> Date = { Date() }, visibleRoot: URL? = nil,
        ops: (any OfflineFileOps)? = nil, syncDirectory: URL? = nil, sharedWithApp: Bool = true,
        rootMode: VisibleRootMode = .documents, rootProvider: MacRootProvider? = nil, folderLedger: FolderLedger? = nil
    ) {
        self.root = root
        self.rootMode = rootMode
        self.rootProvider = rootMode == .macFolder ? rootProvider : nil
        self.folderLedger = folderLedger ?? (rootMode == .macFolder ? rootProvider?.ledger : nil)
        // The Mac app's root is whatever the ledger says, reachable or not: never nil (13.1)
        var resolvedRoot = visibleRoot
        if rootMode == .macFolder, let provider = rootProvider {
            let resolution = provider.resolve()
            resolvedRoot = resolution.url
            self.rootAccess = resolution.access
            self.rootState = resolution.state
        } else if rootMode == .macFolder, let visibleRoot {
            var isDirectory: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: visibleRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                self.rootState = .unreachable(path: visibleRoot.path)
            }
        }
        self.visibleRoot = resolvedRoot
        self.canKeep = resolvedRoot != nil || sharedWithApp
        self.ops = ops ?? SystemFileOps(mode: rootMode)
        self.syncDirectory = syncDirectory
        self.tools = tools
        self.defaults = defaults
        self.now = now
        publishRoot()
        adopt(Self.reconciled(root: root))
        Self.purgeInbox(root: root, olderThan: Self.inboxLifetime)
    }

    private static var sharedInstance: OfflineStore?

    /// `<app group>/Videos`, else `Application Support/Videos`.
    public static func shared() -> OfflineStore {
        if let s = sharedInstance { return s }
        let s: OfflineStore
        #if os(macOS)
        // The Mac's visible root is the Finder folder the ledger names (13.1)
        let ledger = FolderLedger.shared()
        s = OfflineStore(
            root: AppGroup.directory("Videos"), tools: SystemMediaTools(), visibleRoot: nil,
            syncDirectory: AppGroup.directory("Sync"), sharedWithApp: false, rootMode: .macFolder,
            rootProvider: MacRootProvider(ledger: ledger), folderLedger: ledger)
        #else
        s = OfflineStore(
            root: AppGroup.directory("Videos"), tools: SystemMediaTools(), visibleRoot: OfflineFolder.defaultVisibleRoot(),
            syncDirectory: AppGroup.directory("Sync"), sharedWithApp: OfflineFolder.storeIsSharedWithApp())
        #endif
        s.sessionIsHeld = { session in
            if PendingOriginals.shared().isLive(session: session) { return true }
            return SharedJobStore.shared().all().contains { job in
                guard job.sessionID == session else { return false }
                switch job.stage {
                case .saving, .rendering, .uploadInterrupted: return true
                default: return false
                }
            }
        }
        sharedInstance = s
        s.logRoot()
        return s
    }

    /// Where this process keeps the store (app group, the app's own folder, or nowhere) and whether it
    /// takes writes: the first line to read when "nothing is ever kept" is reported from a device.
    func logRoot() {
        let location = AppGroup.location
        var data = location.telemetry
        data["root"] = .string(root.lastPathComponent)
        data["index"] = .bool(FileManager.default.fileExists(atPath: Self.indexURL(root: root).path))
        data["records"] = .int(records.count)
        data["writable"] = .bool(AppGroup.writable(root))
        Telemetry.log(location.kind == .appGroup ? .info : .warn, .store, "store root", data: data)
    }

    nonisolated static func failureData(step: String, _ error: any Error) -> [String: TelemetryValue] {
        var data = Telemetry.errorData(error)
        data["step"] = .string(step)
        data["root"] = .string(AppGroup.location.kind.rawValue)
        return data
    }

    /// Entries that have a file, and the bytes of those files plus every poster: summed from the
    /// index (no disk I/O), so a view can read it in `body`.
    public var usage: StorageUsage {
        _ = videos                                              // registers the observation
        var u = Self.usage(of: records)
        u.count += usageBase?.count ?? 0
        u.bytes += usageBase?.bytes ?? 0
        u.mediaCount += usageBase?.mediaCount ?? 0
        return u
    }

    /// The two tiers, from the index (no disk I/O): `offline` is the kept files wherever they wait, `cache` what
    /// the limit governs (files nobody asked to keep, and the posters and flipbooks of media with nothing kept).
    public var offlineUsage: OfflineUsage {
        _ = videos                                              // registers the observation
        var u = Self.offlineUsage(of: records)
        if let base = offlineUsageBase {
            u.offline.count += base.offline.count; u.offline.bytes += base.offline.bytes; u.offline.mediaCount += base.offline.mediaCount
            u.cache.count += base.cache.count; u.cache.bytes += base.cache.bytes; u.cache.mediaCount += base.cache.mediaCount
        }
        return u
    }

    /// What the store enforces now (the defaults' `storageLimit`); nil = no limit.
    public var limitBytes: Int64? { LimitDefaults.bytes(defaults) }

    /// The owner chose another limit: store it and enforce it at once.
    public func setLimit(_ bytes: Int64?) async {
        LimitDefaults.write(bytes, to: defaults)
        await enforceLimit()
    }

    /// What `setLimit(limit)` would evict right now, in bytes (the "this removes about 1.2 GB" confirm).
    public func bytesToFree(for limit: Int64?) -> Int64 {
        var copy = Self.readRecords(root: root)
        let before = Self.offlineUsage(of: copy).cache.bytes
        _ = Self.enforce(&copy, limit: limit, protecting: pinnedIDs)
        return max(0, before - Self.offlineUsage(of: copy).cache.bytes)
    }

    /// "delete everything": removes every video, poster and record (except entries a running pipeline pins),
    /// the kept files in the visible folder included. The server keeps its copies. The cache's own
    /// "clear cache" is `clearCache()`.
    public func clearAll() async {
        let keep = pinnedIDs
        let refused = await purgeVisible(of: records.filter { !keep.contains($0.id) })      // a file not provably its own stays
        let stay = keep.union(refused)
        var gone: [Record] = []
        guard let merged = try? Self.mutate(root: root, { records in
            gone = records.filter { !stay.contains($0.id) }
            records.removeAll { !stay.contains($0.id) }
        }) else { return }
        Self.delete(
            Eviction(
                files: gone.compactMap(\.fileName), posters: gone.compactMap(\.posterName),
                previews: gone.flatMap { $0.previewNames ?? [] }),
            root: root)
        adopt(merged)
    }

    /// "clear cache" (decision 4): drops the files nobody asked to keep. Every record, poster and flipbook and
    /// every kept file (in the visible folder or waiting in `files/`) stays. Entries a running pipeline pins stay.
    public func clearCache() async {
        let pinned = pinnedIDs
        var names: [String] = []
        guard let merged = try? Self.mutate(root: root, { records in
            for i in records.indices where records[i].keep != true && !pinned.contains(records[i].id) {
                if let name = records[i].fileName {
                    names.append(name)
                    records[i].fileName = nil
                }
            }
        }) else { return }
        Self.delete(Eviction(files: names), root: root)
        adopt(merged)
    }

    /// One pass over the current index with the effective limit (app launch, `reload`, `setLimit`).
    /// Writes only when something has to go.
    func enforceLimit() async {
        var preview = Self.readRecords(root: root)
        let plan = Self.enforce(&preview, limit: limitBytes, protecting: pinnedIDs)
        guard !plan.isEmpty else { adopt(Self.readRecords(root: root)); return }
        _ = try? commit { _ in }
    }

    // MARK: pins (this process only: a file another process has open survives its unlink on iOS)

    func pin(_ id: String) { pins[id, default: 0] += 1 }

    func unpin(_ id: String) {
        guard let n = pins[id] else { return }
        if n <= 1 { pins[id] = nil } else { pins[id] = n - 1 }
    }

    var pinnedIDs: Set<String> { Set(pins.keys) }

    // MARK: reading

    public func latest(_ n: Int) -> [StoredVideo] { Array(videos.prefix(max(0, n))) }

    /// The newest `n` media by latest activity (the orbit shows `latestMedia(7)` and a few more).
    public func latestMedia(_ n: Int) -> [StoredMedia] { Array(media.prefix(max(0, n))) }

    public func media(id: String) -> StoredMedia? { media.first { $0.id == id } }

    /// The media that holds the record `videoID`.
    public func media(containing videoID: String) -> StoredMedia? {
        media.first { m in m.renditions.contains { $0.id == videoID } }
    }

    /// The media with any record of this studio session.
    public func media(session id: String) -> StoredMedia? {
        media.first { $0.sessionIDs.contains(id) }
    }

    // MARK: adding

    /// Stores a file as a new record, or folds it into the record that is the same item (`duplicateIndex`).
    /// `keep` (no default: every caller decides) is the owner's intent (decision 5): kept files never leave
    /// to the limit, and with a visible root the file is moved in before this returns (tagged, `fileName == nil`);
    /// without one (the extension, the Mac) it waits in `files/` and `reload()` promotes it. `createdAt` is the
    /// item's own date when it has one (a library post kept offline keeps the server's, so an old post does not
    /// jump to the front of the orbit); `origin` is passed on to `onAdd`.
    public func add(
        file: URL, kind: StoredVideo.Kind, media: MediaInfo, sessionID: String?,
        link: URL?, remoteURL: URL?, move: Bool, publicURL: URL? = nil,
        mediaID: String? = nil, clip: WebpClip? = nil, keep: Bool, createdAt: Date? = nil,
        origin: AddOrigin = .save,
        role: GalleryRole? = nil, itemIndex: Int? = nil, madeFrom: [Int]? = nil, madeSpec: Data? = nil, libraryID: String? = nil,
        postItems: Int? = nil
    ) async throws -> StoredVideo {
        let keep = keep && canKeep
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let ext = file.pathExtension.isEmpty ? (kind == .webp ? "webp" : "mp4") : file.pathExtension.lowercased()
        var fileName = "\(id).\(ext)"
        var destination: URL
        let backedUp = Self.hasServerCopy(kind: kind, sessionID: sessionID, remoteURL: remoteURL, publicURL: publicURL, libraryID: libraryID)
        do {
            destination = try await place(file, as: fileName, move: move, excludeFromBackup: backedUp)
        } catch {
            Telemetry.log(.error, .store, "store add failed", data: Self.failureData(step: "place", error))
            throw error
        }
        if kind == .original, !media.isImage, let proxy = await playableProxy(of: destination, named: "\(id)-play.mp4") {
            fileName = proxy.lastPathComponent
            destination = proxy
        }

        let size = ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? media.bytes ?? 0
        var media = media
        media.bytes = media.bytes ?? size
        await fillGaps(of: &media, kind: kind, file: destination)

        let posterName = "\(id).jpg"
        let posterURL = root.appendingPathComponent("posters", isDirectory: true).appendingPathComponent(posterName)
        let hasPoster = await tools.poster(for: destination, isImage: kind == .webp || media.isImage, to: posterURL)
        let flipbook: Flipbook
        switch Self.previewSource(kind: kind, isImage: media.isImage) {
        case .animatedImage: flipbook = await Self.renderFlipbook(tools: tools, file: destination, animated: true, id: id, root: root)
        case .video: flipbook = await Self.renderFlipbook(tools: tools, file: destination, animated: false, id: id, root: root)
        case .none: flipbook = Flipbook()
        }

        let stamp = now()
        let record = Record(
            id: id, kind: kind, fileName: fileName, posterName: hasPoster ? posterName : nil,
            name: media.name, duration: media.duration, width: media.width, height: media.height,
            bytes: size, sessionID: sessionID, link: link, remoteURL: remoteURL, createdAt: createdAt ?? stamp,
            addedAt: stamp, posterBytes: hasPoster ? Self.fileSize(posterURL) : nil,
            previewNames: flipbook.names.isEmpty ? nil : flipbook.names,
            previewBytes: flipbook.names.isEmpty ? nil : flipbook.bytes, publicURL: publicURL,
            mediaID: nil, clip: kind == .webp ? clip : nil, keep: keep,
            role: role, itemIndex: itemIndex, madeFrom: madeFrom, madeSpec: madeSpec, libraryID: libraryID, postItems: postItems)

        // The identity check runs inside the coordinated index write (re-read from disk first), so
        // two adds of the same item, in this process or the other one, can never both insert.
        var result = record
        var discard = Eviction()
        var survivor = id
        do {
            try commit(protecting: [survivor]) { records in
                guard let i = Self.duplicateIndex(of: record, in: records) else {
                    // The media is resolved here, against the index just re-read: the app and the
                    // share extension can never split one media (CONTRACT-MEDIA 1.2).
                    var placed = record
                    placed.mediaID = Self.resolveMediaID(for: record, explicit: mediaID, in: records)
                    // a new rendition of a titled media carries the media's title (decision 8)
                    placed.title = records.first { $0.media == placed.media && $0.title != nil }?.title
                    records.insert(placed, at: 0)
                    result = placed
                    survivor = id
                    return
                }
                discard = Self.merge(record, into: &records[i])
                result = records[i]
                survivor = records[i].id
            }
        } catch {
            Telemetry.log(.error, .store, "store add failed", data: Self.failureData(step: "index", error))
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: posterURL)
            Self.delete(Eviction(previews: flipbook.names), root: root)
            throw error
        }
        Self.delete(discard, root: root)
        // A kept file goes into the visible folder now (decision 3); where that cannot happen (no root, a record
        // in use, a failure) it stays kept in `files/` and `reload()` tries again.
        if keep, visibleRoot != nil { await promote(only: [survivor]) }
        let added = videos.first { $0.id == survivor } ?? result.video(root: root, visibleRoot: visibleRoot)
        Telemetry.log(.info, .store, survivor == id ? "store add" : "store add merged", data: [
            "kind": .string(kind.rawValue), "bytes": .bytes(size), "session": .bool(sessionID != nil),
            "poster": .bool(hasPoster), "records": .int(records.count), "root": .string(AppGroup.location.kind.rawValue),
            "keep": .bool(keep), "origin": .string("\(origin)"),
        ])
        onAdd?(added, origin)
        return added
    }

    /// The identity of a stored item, so `add` is idempotent. Two records are the same item when:
    /// - **webp**: same `kind` and the same non-nil `remoteURL`. The hosted webp's URL is unguessable
    ///   and unique per render, so it names the render whichever session or run stored it (the
    ///   attached run and the detached run of one render both carry it).
    /// - **original**: same `kind` and the same non-nil `sessionID`. One studio session has one
    ///   hosted original, which "keep videos on device" downloads once per run; a second add for the
    ///   session (attached and detached paths racing, a retry) is the same file.
    ///
    /// Never duplicates, however alike they look: an original with no `sessionID` (a plain cobalt
    /// save, a picker item: two saves of the same link are two copies the owner asked for), and a
    /// webp with no `remoteURL`.
    static func duplicateIndex(of new: Record, in records: [Record]) -> Int? {
        // A gallery's items and the files made from it (apple/CONTRACT-GALLERY.md 4): an item is the same item when its
        // session and its index are; a made file when it is the same library row. Nothing else is ever folded in.
        switch new.role {
        case .item?:
            guard let sid = new.sessionID, let index = new.itemIndex else { return nil }
            return records.firstIndex { $0.role == .item && $0.sessionID == sid && $0.itemIndex == index }
        case .some:
            guard let id = new.libraryID else { return nil }
            return records.firstIndex { $0.role == new.role && $0.libraryID == id }
        case nil:
            break
        }
        switch new.kind {
        case .webp:
            guard let url = new.remoteURL else { return nil }
            return records.firstIndex { $0.kind == .webp && $0.role == nil && $0.remoteURL == url }
        case .original:
            guard let sid = new.sessionID else { return nil }
            return records.firstIndex { $0.isPlainOriginal && $0.sessionID == sid }
        }
    }

    /// Folds the duplicate's newly known fields into the existing record and returns the files of
    /// the duplicate that must now be deleted. The existing record keeps its id, name, file, poster
    /// and flipbook; only gaps are filled. An existing entry whose file was evicted takes the
    /// duplicate's file instead (a fresh download is a refill, as `attach` does) and, if it had
    /// none, its poster and flipbook too.
    static func merge(_ new: Record, into old: inout Record) -> Eviction {
        old.duration = old.duration ?? new.duration
        old.width = old.width ?? new.width
        old.height = old.height ?? new.height
        old.sessionID = old.sessionID ?? new.sessionID
        old.link = old.link ?? new.link
        old.remoteURL = old.remoteURL ?? new.remoteURL
        old.publicURL = old.publicURL ?? new.publicURL
        old.clip = old.clip ?? new.clip
        old.libraryID = old.libraryID ?? new.libraryID
        old.madeFrom = old.madeFrom ?? new.madeFrom
        old.madeSpec = old.madeSpec ?? new.madeSpec
        old.postItems = old.postItems ?? new.postItems

        var discard = Eviction()
        if old.fileName == nil, old.visiblePath == nil, let name = new.fileName {
            old.fileName = name
            old.bytes = new.bytes
            old.addedAt = new.addedAt
            if old.keep == nil { old.keep = new.keep ?? false }       // a new-build save is never "legacy"
        } else if let name = new.fileName {
            discard.files.append(name)
        }
        // keeping is the owner's intent: it is never lost to a duplicate that was not kept
        if new.keep == true { old.keep = true }
        if old.posterName == nil, let name = new.posterName {
            old.posterName = name
            old.posterBytes = new.posterBytes
        } else if let name = new.posterName {
            discard.posters.append(name)
        }
        if old.previewNames?.isEmpty != false, let names = new.previewNames, !names.isEmpty {
            old.previewNames = names
            old.previewBytes = new.previewBytes
        } else {
            discard.previews.append(contentsOf: new.previewNames ?? [])
        }
        return discard
    }

    /// Refills an evicted entry with a fresh download (library "save", local playback) and makes it
    /// the newest for eviction. The entry keeps its id, poster and metadata; the file goes under a
    /// new name, so a delete queued by another process for the old one can never hit it.
    ///
    /// `keep` is the owner's intent, as in `add` (a kept file moves into the visible folder before this returns);
    /// a record that was already kept stays kept. A record that already has its file in the visible folder is left
    /// as it is (the new file is dropped when `move`): attaching never replaces a kept file.
    public func attach(
        file: URL, to id: String, move: Bool, keep: Bool, origin: AddOrigin = .save
    ) async throws -> StoredVideo {
        let keep = keep && canKeep
        let fm = FileManager.default
        guard let existing = Self.readRecords(root: root).first(where: { $0.id == id }) else {
            Telemetry.log(.warn, .store, "store attach failed", data: ["step": "lookup", "reason": "not found"])
            throw OfflineStoreError.notFound
        }
        if existing.visiblePath != nil, let current = videos.first(where: { $0.id == id }) {
            if move { try? fm.removeItem(at: file) }
            Telemetry.log(.info, .store, "store attach skipped", data: ["reason": "already kept"])
            return current
        }
        let ext = file.pathExtension.isEmpty
            ? (existing.kind == .webp ? "webp" : "mp4") : file.pathExtension.lowercased()
        var fileName = "\(id)-\(UUID().uuidString.prefix(6).lowercased()).\(ext)"
        var destination: URL
        do {
            destination = try await place(
                file, as: fileName, move: move,
                excludeFromBackup: Self.hasServerCopy(
                    kind: existing.kind, sessionID: existing.sessionID, remoteURL: existing.remoteURL, publicURL: existing.publicURL))
        } catch {
            Telemetry.log(.error, .store, "store attach failed", data: Self.failureData(step: "place", error))
            throw error
        }
        if existing.kind == .original,
           let proxy = await playableProxy(of: destination, named: "\((fileName as NSString).deletingPathExtension)-play.mp4") {
            fileName = proxy.lastPathComponent
            destination = proxy
        }
        let size = Self.fileSize(destination) ?? 0

        // The poster usually survived the eviction; make one only when the entry has none.
        var posterName = existing.posterName
        var posterBytes = existing.posterBytes
        var madePoster: URL?
        let posterURL = root.appendingPathComponent("posters", isDirectory: true).appendingPathComponent("\(id).jpg")
        if posterName == nil || !fm.fileExists(atPath: posterURL.path) {
            if await tools.poster(for: destination, isImage: existing.kind == .webp, to: posterURL) {
                posterName = "\(id).jpg"
                posterBytes = Self.fileSize(posterURL)
                madePoster = posterURL
            } else {
                posterName = nil
                posterBytes = nil
            }
        }

        var found = false
        var replaced: String?
        let stamp = now()
        var result: Record?
        do {
            try commit(protecting: [id]) { records in
                guard let i = records.firstIndex(where: { $0.id == id }) else { return }
                found = true
                replaced = records[i].fileName
                records[i].fileName = fileName
                records[i].visiblePath = nil
                records[i].keep = keep ? true : (records[i].keep ?? false)
                records[i].bytes = size
                records[i].addedAt = stamp
                records[i].posterName = posterName
                records[i].posterBytes = posterBytes
                result = records[i]
            }
        } catch {
            Telemetry.log(.error, .store, "store attach failed", data: Self.failureData(step: "index", error))
            try? fm.removeItem(at: destination)
            if let madePoster { try? fm.removeItem(at: madePoster) }
            throw error
        }
        guard found, let result else {
            // removed while the download ran
            Telemetry.log(.warn, .store, "store attach failed", data: ["step": "index", "reason": "removed while downloading"])
            try? fm.removeItem(at: destination)
            if let madePoster { try? fm.removeItem(at: madePoster) }
            throw OfflineStoreError.notFound
        }
        if let replaced, replaced != fileName {
            try? fm.removeItem(at: root.appendingPathComponent("files/\(replaced)"))
        }
        if keep, visibleRoot != nil { await promote(only: [id]) }
        let refilled = videos.first { $0.id == id } ?? result.video(root: root, visibleRoot: visibleRoot)
        Telemetry.log(.info, .store, "store attach", data: [
            "kind": .string(existing.kind.rawValue), "bytes": .bytes(size), "keep": .bool(keep), "origin": .string("\(origin)"),
        ])
        onAdd?(refilled, origin)
        return refilled
    }

    /// A GIF original is stored as an mp4 of its frames: AVFoundation (the planet, the trim's preview, full
    /// screen, the filmstrip, the flipbook) cannot open a GIF, and the server keeps the GIF itself for the
    /// render. Returns the mp4 (the GIF is deleted) or nil when `file` is not a GIF or could not be converted.
    private func playableProxy(of file: URL, named name: String) async -> URL? {
        let out = file.deletingLastPathComponent().appendingPathComponent(name)
        guard out != file, await tools.playableCopy(of: file, to: out) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return out
    }

    /// Moves or copies `file` to `root/files/<name>` off the main actor: a 200 MB copy must not
    /// stall the orbit.
    private func place(_ file: URL, as name: String, move: Bool, excludeFromBackup: Bool = false) async throws -> URL {
        let filesDir = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let destination = filesDir.appendingPathComponent(name)
        try await Task.detached {
            if move {
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                } catch {
                    // across volumes (an inbox on another container): copy, then drop the source
                    try FileManager.default.copyItem(at: file, to: destination)
                    try? FileManager.default.removeItem(at: file)
                }
            } else {
                try FileManager.default.copyItem(at: file, to: destination)
            }
            // the server is this file's backup (decision 14)
            if excludeFromBackup { OfflineFolder.excludeFromBackup(destination) }
        }.value
        return destination
    }

    /// A caller that only knows the session's numbers (or none) still gets a stored entry with
    /// the duration and size the file itself says.
    private func fillGaps(of media: inout MediaInfo, kind: StoredVideo.Kind, file: URL) async {
        guard media.duration == nil || media.width == nil || media.height == nil else { return }
        let probed: MediaInfo?
        if kind == .webp || media.isImage {
            probed = tools.imageInfo(file: file)
        } else {
            probed = await tools.probe(file: file)
        }
        guard let probed else { return }
        media.duration = media.duration ?? probed.duration
        media.width = media.width ?? probed.width
        media.height = media.height ?? probed.height
    }

    /// Where `start(file:)` and the share extension copy incoming files.
    public func inboxURL(for name: String) -> URL {
        Self.inboxURL(root: root, name: name)
    }

    /// `inboxURL(for:)` for code that is not on the main actor (a background session's delegate).
    nonisolated static func inboxURL(root: URL, name: String) -> URL {
        // The name may come from a server or another app: one plain component, never "..", and
        // checked to land inside its own folder (so nothing that removes the destination can ever
        // be pointed at the inbox itself).
        let dir = root
            .appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = SafeFileName.clean(name, fallback: "file")
        return SafeFileName.contained(safe, in: dir) ?? dir.appendingPathComponent("file")
    }

    public func remove(_ id: String) async {
        guard await purgeVisible(of: records.filter { $0.id == id }).isEmpty else { return }   // a file not provably its own stays
        var removed: Record?
        guard let records = try? Self.mutate(root: root, { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            removed = records.remove(at: index)
        }) else { return }
        guard let removed else { return }
        Self.delete(
            Eviction(
                files: removed.fileName.map { [$0] } ?? [], posters: removed.posterName.map { [$0] } ?? [],
                previews: removed.previewNames ?? []),
            root: root)
        adopt(records)
    }

    /// Every record of the media `id` (files, posters, flipbooks) goes, and its planet with it
    /// (CONTRACT-MEDIA 1.12 "remove from this iphone"; the server keeps its copies). Nothing is
    /// removed, and false is returned, when any record is pinned by a running pipeline in this
    /// process, and for an unknown id.
    @discardableResult
    public func removeMedia(_ id: String) async -> Bool {
        let pinned = pinnedIDs
        let current = records.filter { $0.media == id }
        if !current.contains(where: { pinned.contains($0.id) }), !(await purgeVisible(of: current)).isEmpty { return false }
        var gone: [Record] = []
        var blocked = false
        guard let merged = try? Self.mutate(root: root, { records in
            let members = records.filter { $0.media == id }
            if members.contains(where: { pinned.contains($0.id) }) { blocked = true; return }
            gone = members
            records.removeAll { $0.media == id }
        }) else { return false }
        if !gone.isEmpty {
            Self.delete(
                Eviction(
                    files: gone.compactMap(\.fileName), posters: gone.compactMap(\.posterName),
                    previews: gone.flatMap { $0.previewNames ?? [] }),
                root: root)
        }
        adopt(merged)
        return !blocked && !gone.isEmpty
    }

    /// Records the public link of a hosted original on the entries it belongs to: the originals
    /// of `sessionID`, or just `id` when given. One coordinated index write (the share extension
    /// may write too); `videos` updates. Returns how many entries took it (0: the original is not
    /// kept on this device, so there is nothing to badge). Nil clears it (the owner switched the link off).
    @discardableResult
    public func setPublicURL(_ url: URL?, forSession sessionID: String?, orEntry id: String? = nil) -> Int {
        var touched = 0
        func matches(_ r: Record) -> Bool {
            if let id, r.id == id { return true }
            if let sessionID, r.kind == .original, r.sessionID == sessionID { return true }
            return false
        }
        guard let merged = try? Self.mutate(root: root, { records in
            for i in records.indices where matches(records[i]) && records[i].publicURL != url {
                records[i].publicURL = url
                touched += 1
            }
        }) else { return 0 }
        if touched > 0 { adopt(merged) }
        return merged.filter(matches).count
    }

    /// The owner's title of a media, on every record of it, in one coordinated index write (the share
    /// extension may write too). `title` is cleaned (`MediaTitle.clean`); nil, empty or blank clears it.
    /// Unchanged records are not rewritten; an unknown media is a no-op. `videos` and `media` update
    /// only when something changed.
    ///
    /// The kept files of the media follow the new title (decision 8): see `followTitle(media:)`.
    public func setTitle(_ title: String?, media id: String) async {
        let (_, changed) = applyTitle(title, media: id)
        if changed { await followTitle(media: id) }
    }

    /// `setTitle` for callers that must not suspend (an optimistic rename, a run). False when the index
    /// could not be written (the caller keeps the title in memory). A change renames the kept files in a
    /// task of its own.
    @discardableResult
    func writeTitle(_ title: String?, media id: String) -> Bool {
        let (written, changed) = applyTitle(title, media: id)
        if changed, visibleRoot != nil { Task { await followTitle(media: id) } }
        return written
    }

    private func applyTitle(_ title: String?, media id: String) -> (written: Bool, changed: Bool) {
        let cleaned = title.flatMap(MediaTitle.clean)
        var touched = 0
        guard let merged = try? Self.mutate(root: root, { records in
            for i in records.indices where records[i].media == id && records[i].title != cleaned {
                records[i].title = cleaned
                touched += 1
            }
        }) else { return (false, false) }
        if touched > 0 { adopt(merged) }
        return (true, touched > 0)
    }

    /// Drops every file nobody asked to keep and keeps every record and poster (the old "keep videos" off). Kept
    /// files stay: turning "keep new saves offline" off deletes nothing (decision 5).
    public func dropFilesKeepingPosters() async {
        var names: [String] = []
        guard let records = try? Self.mutate(root: root, { records in
            for i in records.indices where records[i].keep != true {
                if let name = records[i].fileName {
                    names.append(name)
                    records[i].fileName = nil
                }
            }
        }) else { return }
        Self.delete(Eviction(files: names, posters: []), root: root)
        adopt(records)
    }

    /// An entry a running pipeline reads frames from or plays right now (its file must stay).
    public func isInUse(_ id: String) -> Bool { pins[id] != nil }

    /// "remove offline copy": drops the video file of one entry, kept or cached, in the visible folder or hidden
    /// (`removeItem`, not the trash), and keeps its record, poster and flipbook (the library and the orbit still
    /// show it; `attach` refills it with a fresh download). `keep` becomes false. It is the owner's own choice,
    /// so the newest-entries protection of the limit does not apply; an entry a running pipeline pins
    /// (`isInUse`) is never removed.
    /// Returns whether a file was dropped: false for an unknown id, an entry with no file (nothing to free; a
    /// wish to keep it is cleared all the same) and an entry in use.
    @discardableResult
    public func removeOfflineCopy(_ id: String) async -> Bool {
        guard !isInUse(id), records.contains(where: { $0.id == id }) else { return false }
        // Both tiers run inside the gate (a promotion's move and its index write are one step to this), and the
        // visible file goes by identity, not by the path remembered (review fixes B1, S5).
        let (hidden, ops, stamp, excludes) = (root, ops, now(), excludesBackup)
        let outcome = await inGate { visible in
            await OfflineFolder.removeCopy(id: id, hiddenRoot: hidden, visibleRoot: visible, ops: ops, now: stamp, excludesBackup: excludes)
        }
        if let written = outcome.records { adopt(written) }
        return outcome.had && !outcome.refused
    }

    /// The old name of `removeOfflineCopy(_:)`.
    @discardableResult
    public func evict(_ id: String) async -> Bool { await removeOfflineCopy(id) }

    /// Deletes the visible files of `gone` (a record is being removed for good), each by identity (the file must carry
    /// the record's own tag; see `OfflineFolder.removeVisibleChecked`). Before the index write, never after: a
    /// tagged file with no record would be rebuilt by the next scan. Returns the ids whose file could not be
    /// proved theirs, which the caller leaves in place.
    private func purgeVisible(of gone: [Record]) async -> Set<String> {
        guard visibleRoot != nil else { return [] }
        let ids = gone.filter { $0.visiblePath != nil }.map(\.id)
        guard !ids.isEmpty else { return [] }
        let (hidden, ops, stamp, excludes) = (root, ops, now(), excludesBackup)
        return await inGate { visible in
            // a root that cannot be used (an unplugged disk) refuses: the files are there, and the records stay with them
            guard let visible else { return Set(ids) }
            return await OfflineFolder.purge(ids: ids, hiddenRoot: hidden, visibleRoot: visible, ops: ops, now: stamp, excludesBackup: excludes)
        }
    }

    /// Previews: writes poster-less, file-less entries into the index so `reload()` keeps them.
    func seed(_ seeds: [StoredVideo]) {
        let records = seeds.map { v in
            Record(
                id: v.id, kind: v.kind, fileName: nil, posterName: nil, name: v.name, duration: v.duration,
                width: v.width, height: v.height, bytes: v.bytes, sessionID: v.sessionID, link: v.link,
                remoteURL: v.remoteURL, createdAt: v.createdAt, publicURL: v.publicURL, mediaID: v.mediaID, clip: v.clip,
                title: v.title, role: v.role, itemIndex: v.itemIndex, madeFrom: v.madeFrom, madeSpec: v.madeSpec,
                libraryID: v.libraryID, postItems: v.postItems)
        }
        if let written = try? Self.mutate(root: root, { $0 = records }) {
            adopt(written)
        }
    }

    /// Re-reads the index (the share extension may have written), tidies leftovers and enforces the
    /// limit (the app calls this on every foreground, so it also covers app launch).
    ///
    /// With a visible root it also runs, in this order: the scan of the visible folder (decision 7), the
    /// migration (section 2) and the promotion of kept files that wait in `files/`.
    public func reload() async {
        adopt(Self.reconciled(root: root))
        Self.purgeInbox(root: root, olderThan: Self.inboxLifetime)
        Self.purgeOrphanPreviews(
            root: root, referenced: Set(records.flatMap { $0.previewNames ?? [] }), olderThan: Self.inboxLifetime)
        if !canKeep { releaseUnpromotableKeeps() }
        if visibleRoot != nil {
            if rootMode == .macFolder {
                // The Mac: where is the root now, and is it the folder cobalt was using? Then what FolderSync wrote is
                // adopted by tag, before the scan (13.3).
                await resolveRoot()
                await adoptFolderSyncFiles()
                await normalizeLegacyKeeps()
            }
            // The scan comes first: a file the last run moved but did not get to index (section 2.3) is adopted
            // by its tag here, and must not be moved a second time.
            let report = await scanVisibleRoot()
            if rootMode == .macFolder, !report.rootMissing, !report.indexUnreadable { rootProvider?.recordIdentity(ofRoot: visibleRoot) }
            await runMigrationIfNeeded()
            await promote(only: nil, respectHolds: true)
        }
        await enforceLimit()
    }

    /// A store nobody promotes from (see `canKeep`) that an earlier build filled with kept files: they are cache
    /// now, so the limit governs them again.
    private func releaseUnpromotableKeeps() {
        guard records.contains(where: { $0.keep == true && $0.visiblePath == nil }) else { return }
        guard let merged = try? Self.mutate(root: root, { records in
            for i in records.indices where records[i].keep == true && records[i].visiblePath == nil { records[i].keep = false }
        }) else { return }
        adopt(merged)
    }

    func adopt(_ merged: [Record]) {
        records = merged
        videos = merged.map { $0.video(root: root, visibleRoot: visibleRoot) }
        media = StoredMedia.build(from: videos)
    }

    /// One coordinated write: `body` changes the merged index, then (unless `enforce` is false) the
    /// limit is applied to the result, all before the index is written. The evicted files are
    /// deleted only after that write.
    @discardableResult
    func commit(
        protecting extra: @autoclosure () -> Set<String> = [], enforce: Bool = true, _ body: (inout [Record]) -> Void
    ) throws -> [Record] {
        let pinned = pinnedIDs
        let defaults = defaults
        var evicted = Eviction()
        let merged = try Self.mutate(root: root) { records in
            body(&records)
            // evaluated after `body`: `add` learns inside the write which entry it must protect
            if enforce {
                evicted = Self.enforce(
                    &records, limit: LimitDefaults.bytes(defaults), protecting: extra().union(pinned))
            }
        }
        Self.delete(evicted, root: root)
        adopt(merged)
        return merged
    }

    // MARK: flipbook (preview frames)

    /// Makes the flipbook of an entry that has none (an entry from before they existed, or one whose
    /// frames could not be made at `add`). Idempotent and cheap to call from a view: it returns at once
    /// when the frames exist, the entry is a still image, or its file is gone (nothing to read frames
    /// from); a second call while the first is running waits for it instead of repeating the work.
    /// The decoding and encoding run off the main actor, one entry at a time; when the frames are in
    /// the index, `videos` is replaced, so an observing view sees `previewFrameURLs` fill.
    public func ensurePreviewFrames(for video: StoredVideo) async {
        let id = video.id
        if let job = previewJobs[id] { await job.value; return }
        guard let record = records.first(where: { $0.id == id }), record.previewNames?.isEmpty != false,
              let file = record.video(root: root, visibleRoot: visibleRoot).fileURL, !previewFailures.contains(id)
        else { return }
        let animated: Bool
        switch Self.previewSource(kind: record.kind, isImage: Self.looksLikeImage(file.lastPathComponent)) {
        case .none: return
        case .animatedImage: animated = true
        case .video: animated = false
        }
        pin(id)                                                // the file stays until the frames are read
        let job = Task {
            let book = await Self.renderFlipbook(tools: tools, file: file, animated: animated, id: id, root: root)
            finishPreviews(id: id, book: book)
        }
        previewJobs[id] = job
        await job.value
    }

    /// Runs `ensurePreviewFrames` for every kept video that still has no flipbook, newest first
    /// (the lazy backfill of entries that predate the flipbook).
    /// Only the faces of the newest `backfillLimit` media (the orbit never shows more) and then their
    /// originals, and it stops between entries when its task is cancelled.
    public func backfillPreviewFrames() async {
        let newest = media.prefix(Self.backfillLimit)
        let faces = newest.map(\.face)
        let originals = newest.compactMap { m in m.original.flatMap { $0.id == m.face.id ? nil : $0 } }
        let candidates = (faces + originals).filter { $0.fileURL != nil && $0.previewFrameURLs.isEmpty }
        for video in candidates {
            if Task.isCancelled { return }
            await ensurePreviewFrames(for: video)
        }
    }

    /// The orbit's maximum: entries past the newest 35 are never drawn, so they get no flipbook here
    /// (one is still made on demand by `ensurePreviewFrames(for:)`).
    nonisolated static let backfillLimit = 35

    private func finishPreviews(id: String, book: Flipbook) {
        previewJobs[id] = nil
        unpin(id)
        guard !book.names.isEmpty else { previewFailures.insert(id); return }
        var present = false
        do {
            try commit(protecting: [id]) { records in
                guard let i = records.firstIndex(where: { $0.id == id }) else { return }
                present = true
                // another process may have made them meanwhile: same names, keep what is there
                if records[i].previewNames?.isEmpty == false { return }
                records[i].previewNames = book.names
                records[i].previewBytes = book.bytes
            }
        } catch {
            present = false
        }
        if !present { Self.delete(Eviction(previews: book.names), root: root) }     // removed while it ran
    }

    enum PreviewSource { case video, animatedImage, none }

    /// A video gets a flipbook from its frames, an animated webp from its decoded frames, an image none.
    nonisolated static func previewSource(kind: StoredVideo.Kind, isImage: Bool) -> PreviewSource {
        if kind == .webp { return .animatedImage }
        return isImage ? .none : .video
    }

    nonisolated static func looksLikeImage(_ fileName: String) -> Bool {
        UTType(filenameExtension: (fileName as NSString).pathExtension)?.conforms(to: .image) == true
    }

    /// The files of a finished flipbook (names relative to `root/previews`) and their total size.
    struct Flipbook: Sendable {
        var names: [String] = []
        var bytes: Int64 = 0
    }

    /// Frames in, JPEGs out, one flipbook at a time process-wide (decoding is the expensive part, and
    /// the share extension has little memory). Each file is written atomically; the entry only names
    /// them once the whole set is done, in the coordinated index write.
    @concurrent
    nonisolated static func renderFlipbook(
        tools: any MediaTools, file: URL, animated: Bool, id: String, root: URL
    ) async -> Flipbook {
        let gate = PreviewGate.shared
        await gate.enter()
        let book = await makeFlipbook(tools: tools, file: file, animated: animated, id: id, root: root)
        await gate.leave()
        return book
    }

    nonisolated private static func makeFlipbook(
        tools: any MediaTools, file: URL, animated: Bool, id: String, root: URL
    ) async -> Flipbook {
        let images = await tools.previewFrames(
            of: file, animatedImage: animated, count: PreviewSize.frameCount, maxEdge: PreviewSize.longEdge)
        guard images.count >= 2 else { return Flipbook() }          // one frame is a poster, not a flipbook
        let fm = FileManager.default
        let dir = root.appendingPathComponent("previews", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return Flipbook() }
        var book = Flipbook()
        for (i, image) in images.enumerated() {
            guard let data = PreviewSize.jpeg(image) else { continue }
            let name = "\(id)-\(i < 10 ? "0" : "")\(i).jpg"
            do {
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            } catch {
                delete(Eviction(previews: book.names), root: root)
                return Flipbook()
            }
            book.names.append(name)
            book.bytes += Int64(data.count)
        }
        if book.names.count < 2 {
            delete(Eviction(previews: book.names), root: root)
            return Flipbook()
        }
        return book
    }

    // MARK: index on disk

    struct Record: Codable, Equatable {
        var id: String
        var kind: StoredVideo.Kind
        var fileName: String?
        var posterName: String?
        var name: String
        var duration: Double?
        var width: Int?
        var height: Int?
        var bytes: Int64
        var sessionID: String?
        var link: URL?
        var remoteURL: URL?
        var createdAt: Date
        /// When the file arrived (eviction order, oldest first); nil in an index written before
        /// the limit existed, which reads as `createdAt`. `attach` moves it to now.
        var addedAt: Date?
        /// Size of the poster file; nil in an old index until the first load stats it once.
        var posterBytes: Int64?
        /// The flipbook's files under `previews/` (in play order) and their total size; nil when
        /// there is none (an index from before they existed, a still image).
        var previewNames: [String]?
        var previewBytes: Int64?
        /// The hosted original's public link; nil until shared.
        var publicURL: URL?
        /// The media this record belongs to; nil in an index written before media existed (the
        /// migration in `assignLegacyMediaIDs` fills it on the next coordinated write).
        var mediaID: String?
        /// What a webp was made from, when this device made it.
        var clip: WebpClip?
        /// The owner's title of the media (same value on every record of it); nil in an older index.
        var title: String?
        /// The owner keeps this on the device (decision 3). Nil in an index written before offline existed: a
        /// legacy record, which the migration keeps and moves into the visible folder. A build that saves a file
        /// always writes true or false.
        var keep: Bool?
        /// Where the kept file is, relative to the visible root (it may be in a subfolder the owner made); nil when
        /// the file is in `files/` (`fileName`) or there is none. Never set together with `fileName`; implies `keep`.
        var visiblePath: String?
        /// The file name cobalt chose for the visible file (decision 8): while the file still has it, a rename of
        /// the media in cobalt renames the file; one the owner renamed is never renamed again.
        var givenName: String?
        /// Gallery fields (apple/CONTRACT-GALLERY.md 4); nil in an index written before galleries.
        @LenientRole var role: GalleryRole?
        var itemIndex: Int?
        var madeFrom: [Int]?
        var madeSpec: Data?
        var libraryID: String?
        /// How many items the post had when this item was kept (see `StoredVideo.postItems`).
        var postItems: Int?

        /// The effective media id.
        var media: String { mediaID ?? id }
        var added: Date { addedAt ?? createdAt }
        /// There is a file on this device: in `files/` or in the visible folder.
        var hasFile: Bool { fileName != nil || visiblePath != nil }
        /// The media's own original: not an item of a gallery and not a file made from one.
        var isPlainOriginal: Bool { kind == .original && role == nil }
        /// Nothing may take this off the device: the owner keeps it, or a file of it is in the visible folder.
        var isAnchored: Bool { keep == true || visiblePath != nil }
        /// The server has its own copy (so the file may stay out of the owner's backup, decision 14): a hosted
        /// webp, an original of a studio session or a hosted one. A plain cobalt save or a picker item has none.
        var hasServerCopy: Bool {
            OfflineStore.hasServerCopy(kind: kind, sessionID: sessionID, remoteURL: remoteURL, publicURL: publicURL, libraryID: libraryID)
        }
        /// What this entry costs on the device: its file (if any), its poster and its flipbook.
        var cost: Int64 {
            (hasFile ? bytes : 0) + (posterName != nil ? posterBytes ?? 0 : 0)
                + (previewNames?.isEmpty == false ? previewBytes ?? 0 : 0)
        }
        /// What is left of the entry when its file goes: poster and flipbook.
        var keptCost: Int64 { cost - (hasFile ? bytes : 0) }

        func video(root: URL, visibleRoot: URL? = nil) -> StoredVideo {
            let fileURL: URL?
            let place: StoredVideo.Place?
            if let fileName {
                fileURL = root.appendingPathComponent("files/\(fileName)")
                place = .cache
            } else if let visiblePath {
                fileURL = visibleRoot.map { $0.appendingPathComponent(visiblePath) }
                place = .offline
            } else {
                fileURL = nil
                place = nil
            }
            return StoredVideo(
                id: id, kind: kind, fileURL: fileURL,
                posterURL: posterName.map { root.appendingPathComponent("posters/\($0)") },
                name: name, duration: duration, width: width, height: height, bytes: bytes,
                sessionID: sessionID, link: link, remoteURL: remoteURL, createdAt: createdAt,
                previewFrameURLs: (previewNames ?? []).map { root.appendingPathComponent("previews/\($0)") },
                publicURL: publicURL, mediaID: media, clip: clip, title: title, place: place, keep: keep == true,
                role: role, itemIndex: itemIndex, madeFrom: madeFrom, madeSpec: madeSpec, libraryID: libraryID,
                postItems: postItems)
        }
    }

    /// Where a new record goes (CONTRACT-MEDIA 1.2), against the index as just re-read:
    /// 1. the caller's explicit media (the run was started from it), unless it does not exist any more or
    ///    already has a different original (at most one original per media: a second becomes its own);
    /// 2. else the media of any record with the same non-nil session (an original added after its webps
    ///    joins them; the same rule keeps a second original out of a media that has one);
    /// 3. else a new media, named by this record.
    static func resolveMediaID(for new: Record, explicit: String?, in records: [Record]) -> String {
        func hasOriginal(_ media: String) -> Bool { records.contains { $0.media == media && $0.isPlainOriginal } }
        func accepts(_ media: String) -> Bool { !(new.isPlainOriginal && hasOriginal(media)) }
        if let explicit, !explicit.isEmpty, records.contains(where: { $0.media == explicit }), accepts(explicit) {
            return explicit
        }
        if let sid = new.sessionID,
           let match = records.first(where: { $0.sessionID == sid && accepts($0.media) }) {
            return match.media
        }
        return new.id
    }

    /// The one-time migration of an index without media ids (CONTRACT-MEDIA 1.3). Deterministic (it reads
    /// only the records, in `createdAt`, `id` order), so two processes that run it get the same ids;
    /// never reorders, deletes or moves anything. Returns whether it changed a record.
    /// 1. records of one non-nil session form a media: its earliest original's id, else the earliest
    ///    webp's; a second original of the session stays its own media; a session that already has a
    ///    media in the index (a record an older build wrote later) is joined instead;
    /// 2. a webp-only session joins an original of another session when all its records carry one link
    ///    and exactly one original that has a session carries that link (a reopened session);
    ///    ambiguous or no link: it stays its own media;
    /// 3. records with no session (plain saves, picker items) are their own media.
    @discardableResult
    nonisolated static func assignLegacyMediaIDs(_ records: inout [Record]) -> Bool {
        let lacking = records.indices.filter { records[$0].mediaID == nil }
        guard !lacking.isEmpty else { return false }
        let ordered = lacking.sorted {
            (records[$0].createdAt, records[$0].id) < (records[$1].createdAt, records[$1].id)
        }
        var sessionMedia: [String: String] = [:]
        var mediaWithOriginal: Set<String> = []
        for r in records {
            guard let media = r.mediaID else { continue }
            if let sid = r.sessionID, sessionMedia[sid] == nil { sessionMedia[sid] = media }
            if r.kind == .original { mediaWithOriginal.insert(media) }
        }
        var webpOnlyGroups: [[Int]] = []
        for i in ordered where records[i].mediaID == nil {
            guard let sid = records[i].sessionID else {
                records[i].mediaID = records[i].id                               // 3
                continue
            }
            if let joined = sessionMedia[sid], !(records[i].kind == .original && mediaWithOriginal.contains(joined)) {
                records[i].mediaID = joined
                continue
            }
            let group = ordered.filter { records[$0].mediaID == nil && records[$0].sessionID == sid }
            let originals = group.filter { records[$0].kind == .original }
            let leader = originals.first ?? group[0]
            let media = records[leader].id
            for j in group { records[j].mediaID = media }                          // 1
            for extra in originals.dropFirst() { records[extra].mediaID = records[extra].id }
            sessionMedia[sid] = media
            if originals.isEmpty { webpOnlyGroups.append(group) } else { mediaWithOriginal.insert(media) }
        }
        for group in webpOnlyGroups {                                              // 2
            let links = Set(group.compactMap { records[$0].link })
            guard links.count == 1, group.allSatisfy({ records[$0].link != nil }), let link = links.first else { continue }
            let candidates = records.filter { $0.kind == .original && $0.sessionID != nil && $0.link == link }
            guard candidates.count == 1, let target = candidates.first?.mediaID else { continue }
            for j in group { records[j].mediaID = target }
        }
        return true
    }

    /// Every file, both tiers, plus every poster and flipbook (what `usage` has always meant).
    static func usage(of records: [Record]) -> StorageUsage {
        let kept = records.filter(\.hasFile)
        return StorageUsage(count: kept.count, bytes: records.reduce(0) { $0 + $1.cost }, mediaCount: Set(kept.map(\.media)).count)
    }

    /// The two tiers. `offline`: kept files (the bytes of the files only). `cache`: files nobody asked to keep,
    /// and the posters and flipbooks of media with nothing kept: exactly what `enforce` can free.
    static func offlineUsage(of records: [Record]) -> OfflineUsage {
        let anchored = Set(records.filter(\.isAnchored).map(\.media))
        let keptFiles = records.filter { $0.hasFile && $0.isAnchored }
        let cacheFiles = records.filter { $0.hasFile && !$0.isAnchored }
        let offline = StorageUsage(
            count: keptFiles.count, bytes: keptFiles.reduce(0) { $0 + $1.bytes }, mediaCount: Set(keptFiles.map(\.media)).count)
        var cacheBytes = cacheFiles.reduce(Int64(0)) { $0 + $1.bytes }
        for r in records where !anchored.contains(r.media) { cacheBytes += r.keptCost }
        let cache = StorageUsage(count: cacheFiles.count, bytes: cacheBytes, mediaCount: Set(cacheFiles.map(\.media)).count)
        return OfflineUsage(offline: offline, cache: cache)
    }

    /// Whether the server holds its own copy of an item (decision 14), from what the record knows: a webp this
    /// device had hosted (`remoteURL`), an original that has a studio session or a public link.
    nonisolated static func hasServerCopy(
        kind: StoredVideo.Kind, sessionID: String?, remoteURL: URL?, publicURL: URL?, libraryID: String? = nil
    ) -> Bool {
        if libraryID != nil { return true }                // a gallery item or a made file: the library row is its copy
        switch kind {
        case .webp: return remoteURL != nil
        case .original: return sessionID != nil || publicURL != nil
        }
    }

    /// Files, posters and flipbook frames to delete once the index no longer names them.
    struct Eviction {
        var files: [String] = []
        var posters: [String] = []
        var previews: [String] = []
        var isEmpty: Bool { files.isEmpty && posters.isEmpty && previews.isEmpty }
    }

    /// Brings `records` under `limit` (nil = no limit) and says what to delete. (1) Files of the
    /// oldest-added entries go first (`fileName = nil`; poster, flipbook and record stay). (2) Only if
    /// usage is still over, whole **media** whose records are all file-less, oldest first, for the
    /// poster and flipbook bytes they free: a media never loses its face record while keeping others.
    /// Never touched: every record of the newest `protectedNewest` media (by latest activity: the
    /// newest `added` of its records, so a refill keeps its media young) and `protecting` (the entry
    /// just added, entries pinned by a running pipeline). A file alone over the limit is kept.
    static func enforce(_ records: inout [Record], limit: Int64?, protecting: Set<String>) -> Eviction {
        var plan = Eviction()
        guard let limit else { return plan }
        var total = offlineUsage(of: records).cache.bytes
        guard total > limit else { return plan }

        // Index order is newest first, so a later index means older when two stamps tie.
        var recency: [String: (Date, Int)] = [:]
        for i in records.indices {
            let key = (records[i].added, -i)
            if let current = recency[records[i].media], current >= key { continue }
            recency[records[i].media] = key
        }
        let newestMedia = Set(recency.sorted { $0.value > $1.value }.prefix(protectedNewest).map(\.key))
        // kept files are never evicted (decision 4), however far over the limit the cache is
        func isProtected(_ r: Record) -> Bool { protecting.contains(r.id) || newestMedia.contains(r.media) || r.isAnchored }
        let oldestFirst = records.indices
            .filter { !isProtected(records[$0]) }
            .sorted { (records[$0].added, -$0) < (records[$1].added, -$1) }

        for i in oldestFirst where total > limit {
            guard let name = records[i].fileName else { continue }
            total -= records[i].bytes
            plan.files.append(name)
            records[i].fileName = nil
        }
        if total > limit {
            var members: [String: [Int]] = [:]
            for i in records.indices { members[records[i].media, default: []].append(i) }
            let droppable = members.keys
                .filter { media in
                    guard !newestMedia.contains(media), let rows = members[media] else { return false }
                    // never a media with anything kept (it would take the poster and record of kept files) or a file
                    return rows.allSatisfy { !records[$0].hasFile && !records[$0].isAnchored && !protecting.contains(records[$0].id) }
                        && rows.reduce(0, { $0 + records[$1].keptCost }) > 0
                }
                .sorted { (recency[$0] ?? (.distantPast, 0)) < (recency[$1] ?? (.distantPast, 0)) }
            var dropped: Set<String> = []
            for media in droppable where total > limit {
                for i in members[media] ?? [] {
                    total -= records[i].keptCost
                    if let poster = records[i].posterName { plan.posters.append(poster) }
                    plan.previews.append(contentsOf: records[i].previewNames ?? [])
                    dropped.insert(records[i].id)
                }
            }
            records.removeAll { dropped.contains($0.id) }
        }
        return plan
    }

    nonisolated static func delete(_ plan: Eviction, root: URL) {
        let fm = FileManager.default
        for name in plan.files { try? fm.removeItem(at: root.appendingPathComponent("files/\(name)")) }
        for name in plan.posters { try? fm.removeItem(at: root.appendingPathComponent("posters/\(name)")) }
        for name in plan.previews { try? fm.removeItem(at: root.appendingPathComponent("previews/\(name)")) }
    }

    nonisolated static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    nonisolated static func indexURL(root: URL) -> URL { root.appendingPathComponent("index.json") }

    /// The index exists but this build cannot decode it (a later build's new `Kind`, a torn write). It is never
    /// written over and never read as empty: every caller that would write refuses, and a copy is kept beside it
    /// (review fix S1).
    struct IndexUnreadable: Error, Equatable { var bytes: Int }

    /// Missing and empty are a store with no records yet; anything else that does not decode is `IndexUnreadable`.
    nonisolated static func decodeChecked(_ url: URL, root: URL) throws -> [Record] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        do { return try JSONDecoder().decode([Record].self, from: data) } catch {
            preserveUnreadable(data, root: root, error: error)
            throw IndexUnreadable(bytes: data.count)
        }
    }

    private nonisolated static let reportedUnreadable = Mutex(Set<String>())

    /// Keeps the bytes of an index that cannot be decoded as `index.unreadable-<date>-<fingerprint>.json` (once per
    /// content) and says so in telemetry (once per process per content).
    private nonisolated static func preserveUnreadable(_ data: Data, root: URL, error: any Error) {
        var hash: UInt64 = 0xcbf29ce484222325                                   // FNV-1a: a name for the content
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let fingerprint = String(hash, radix: 16).prefix(8)
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .contains { $0.hasPrefix("index.unreadable-") && $0.hasSuffix("-\(fingerprint).json") }
        if !existing {
            try? data.write(to: root.appendingPathComponent("index.unreadable-\(stamp)-\(fingerprint).json"), options: .atomic)
        }
        let first = reportedUnreadable.withLock { $0.insert(String(fingerprint)).inserted }
        if first {
            var info = Telemetry.errorData(error)
            info["bytes"] = .int(data.count)
            info["root"] = .string(AppGroup.location.kind.rawValue)
            Telemetry.log(.error, .store, "store index unreadable", data: info)
        }
    }

    /// Reads, lets `body` change the records, and writes them back, all under one coordinated
    /// write so the app and the extension never lose each other's entries. Throws `IndexUnreadable`, writing
    /// nothing, when the index is there and cannot be decoded.
    ///
    /// `nonisolated`: the new folder work (scan, moves) writes the index from `@concurrent` hops. Every write also
    /// holds the invariant `visiblePath != nil` implies `keep`.
    @discardableResult
    nonisolated static func mutate(root: URL, _ body: (inout [Record]) -> Void) throws -> [Record] {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Telemetry.log(.error, .store, "store index write failed", data: failureData(step: "createRoot", error))
            throw error
        }
        let url = indexURL(root: root)
        var result: [Record] = []
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordination) { u in
            do {
                var records = try decodeChecked(u, root: root)
                // Every coordinated write first gives a legacy index its media ids (deterministic, so the
                // app and the extension agree), then applies the caller's change.
                _ = assignLegacyMediaIDs(&records)
                body(&records)
                for i in records.indices where records[i].visiblePath != nil && records[i].keep != true { records[i].keep = true }
                try JSONEncoder().encode(records).write(to: u, options: .atomic)
                result = records
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure {
            if !(error is IndexUnreadable) {
                Telemetry.log(.error, .store, "store index write failed", data: failureData(step: coordination != nil ? "coordinate" : "write", error))
            }
            throw error
        }
        return result
    }

    /// The records, or `IndexUnreadable` when the index is there and cannot be decoded.
    nonisolated static func readRecordsChecked(root: URL) throws -> [Record] {
        var out: [Record] = []
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: indexURL(root: root), options: [], error: &coordination) { u in
            do { out = try decodeChecked(u, root: root) } catch { failure = error }
        }
        if let failure { throw failure }
        return out
    }

    /// The records; an index that cannot be decoded reads as empty here (callers that would write go through
    /// `mutate`, which refuses, and the scan checks `readRecordsChecked` first).
    nonisolated static func readRecords(root: URL) -> [Record] {
        (try? readRecordsChecked(root: root)) ?? []
    }

    /// The index with entries whose file or poster has vanished (a container restore, a manual
    /// clean-up) turned into "poster only" / "metadata only" instead of pointing at nothing, and
    /// the poster sizes an older index did not have filled in (stat once, then stored).
    private static func reconciled(root: URL) -> [Record] {
        let fm = FileManager.default
        func missing(_ sub: String, _ name: String?) -> Bool {
            guard let name else { return false }
            return !fm.fileExists(atPath: root.appendingPathComponent("\(sub)/\(name)").path)
        }
        func needsPosterSize(_ r: Record) -> Bool { r.posterName != nil && r.posterBytes == nil }
        // a flipbook with any frame gone is useless (it would stutter): the whole set is dropped
        func brokenFlipbook(_ r: Record) -> Bool {
            guard let names = r.previewNames else { return false }
            return names.isEmpty || names.contains { missing("previews", $0) } || r.previewBytes == nil
        }
        var records = readRecords(root: root)
        let lost = records.filter { missing("files", $0.fileName) }.count
        if lost > 0 {
            Telemetry.log(.warn, .store, "store files missing", data: ["files": .int(lost), "records": .int(records.count), "root": .string(AppGroup.location.kind.rawValue)])
        }
        if records.contains(where: {
            missing("files", $0.fileName) || missing("posters", $0.posterName) || needsPosterSize($0) || brokenFlipbook($0)
                || $0.mediaID == nil
        }), let fixed = try? mutate(root: root, { records in
            for i in records.indices {
                if missing("files", records[i].fileName) { records[i].fileName = nil }
                if missing("posters", records[i].posterName) {
                    records[i].posterName = nil
                    records[i].posterBytes = nil
                }
                if let poster = records[i].posterName, records[i].posterBytes == nil {
                    records[i].posterBytes = fileSize(root.appendingPathComponent("posters/\(poster)")) ?? 0
                }
                if let names = records[i].previewNames {
                    if names.isEmpty || names.contains(where: { missing("previews", $0) }) {
                        delete(Eviction(previews: names), root: root)
                        records[i].previewNames = nil
                        records[i].previewBytes = nil
                    } else if records[i].previewBytes == nil {
                        records[i].previewBytes = names.reduce(0) {
                            $0 + (fileSize(root.appendingPathComponent("previews/\($1)")) ?? 0)
                        }
                    }
                }
            }
        }) {
            records = fixed
        }
        return records
    }

    /// Removes frames in `previews/` no entry names (a crash between writing frames and the index
    /// write), once they are older than `age`: a flipbook another process is writing right now is
    /// not in the index yet.
    nonisolated static func purgeOrphanPreviews(root: URL, referenced: Set<String>, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("previews", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for entry in entries where !referenced.contains(entry.lastPathComponent) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age { try? fm.removeItem(at: entry) }
        }
    }

    /// Removes `inbox/<id>` folders nobody has touched for `age` seconds.
    nonisolated static func purgeInbox(root: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age { try? fm.removeItem(at: entry) }
        }
    }
}

/// Lets one flipbook render at a time in this process (a second caller waits its turn).
private actor PreviewGate {
    static let shared = PreviewGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
