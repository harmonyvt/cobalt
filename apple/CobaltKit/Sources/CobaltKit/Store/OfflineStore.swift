import Foundation
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

    public init(
        id: String, kind: Kind, fileURL: URL?, posterURL: URL?, name: String, duration: Double?,
        width: Int?, height: Int?, bytes: Int64, sessionID: String?, link: URL?, remoteURL: URL?,
        createdAt: Date, previewFrameURLs: [URL] = [], publicURL: URL? = nil, mediaID: String? = nil,
        clip: WebpClip? = nil, title: String? = nil
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
            title: try c.decodeIfPresent(String.self, forKey: .title))
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
    @ObservationIgnored let tools: any MediaTools
    /// Where the effective limit is read (the app group's defaults in the app and the extension).
    @ObservationIgnored let defaults: UserDefaults
    /// `addedAt` stamps; tests inject a clock.
    @ObservationIgnored let now: @Sendable () -> Date
    /// Previews show "13 videos · 54 MB" without 13 files on disk: this is added to what is.
    @ObservationIgnored var usageBase: StorageUsage?
    /// Called after every `add` and `attach` that landed (the app's photos sync hooks in here; the
    /// share extension never sets it).
    @ObservationIgnored var onAdd: (@MainActor (StoredVideo) -> Void)?
    /// Entries a running pipeline reads frames from or plays: never evicted while pinned.
    @ObservationIgnored private var pins: [String: Int] = [:]
    /// The index as last read or written; `usage` sums it, with no disk I/O.
    @ObservationIgnored private var records: [Record] = []
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.tools = tools
        self.defaults = defaults
        self.now = now
        adopt(Self.reconciled(root: root))
        Self.purgeInbox(root: root, olderThan: Self.inboxLifetime)
    }

    private static var sharedInstance: OfflineStore?

    /// `<app group>/Videos`, else `Application Support/Videos`.
    public static func shared() -> OfflineStore {
        if let s = sharedInstance { return s }
        let s = OfflineStore(root: AppGroup.directory("Videos"))
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
        let before = Self.usage(of: copy).bytes
        _ = Self.enforce(&copy, limit: limit, protecting: pinnedIDs)
        return max(0, before - Self.usage(of: copy).bytes)
    }

    /// Removes every video, poster and record (except entries a running pipeline pins). The server
    /// keeps its copies.
    public func clearAll() async {
        let keep = pinnedIDs
        var gone: [Record] = []
        guard let merged = try? Self.mutate(root: root, { records in
            gone = records.filter { !keep.contains($0.id) }
            records.removeAll { !keep.contains($0.id) }
        }) else { return }
        Self.delete(
            Eviction(
                files: gone.compactMap(\.fileName), posters: gone.compactMap(\.posterName),
                previews: gone.flatMap { $0.previewNames ?? [] }),
            root: root)
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

    public func add(
        file: URL, kind: StoredVideo.Kind, media: MediaInfo, sessionID: String?,
        link: URL?, remoteURL: URL?, move: Bool, publicURL: URL? = nil,
        mediaID: String? = nil, clip: WebpClip? = nil
    ) async throws -> StoredVideo {
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let ext = file.pathExtension.isEmpty ? (kind == .webp ? "webp" : "mp4") : file.pathExtension.lowercased()
        let fileName = "\(id).\(ext)"
        let destination: URL
        do {
            destination = try await place(file, as: fileName, move: move)
        } catch {
            Telemetry.log(.error, .store, "store add failed", data: Self.failureData(step: "place", error))
            throw error
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
            bytes: size, sessionID: sessionID, link: link, remoteURL: remoteURL, createdAt: stamp,
            addedAt: stamp, posterBytes: hasPoster ? Self.fileSize(posterURL) : nil,
            previewNames: flipbook.names.isEmpty ? nil : flipbook.names,
            previewBytes: flipbook.names.isEmpty ? nil : flipbook.bytes, publicURL: publicURL,
            mediaID: nil, clip: kind == .webp ? clip : nil)

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
        let added = result.video(root: root)
        Telemetry.log(.info, .store, survivor == id ? "store add" : "store add merged", data: [
            "kind": .string(kind.rawValue), "bytes": .bytes(size), "session": .bool(sessionID != nil),
            "poster": .bool(hasPoster), "records": .int(records.count), "root": .string(AppGroup.location.kind.rawValue),
        ])
        onAdd?(added)
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
        switch new.kind {
        case .webp:
            guard let url = new.remoteURL else { return nil }
            return records.firstIndex { $0.kind == .webp && $0.remoteURL == url }
        case .original:
            guard let sid = new.sessionID else { return nil }
            return records.firstIndex { $0.kind == .original && $0.sessionID == sid }
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

        var discard = Eviction()
        if old.fileName == nil, let name = new.fileName {
            old.fileName = name
            old.bytes = new.bytes
            old.addedAt = new.addedAt
        } else if let name = new.fileName {
            discard.files.append(name)
        }
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
    public func attach(file: URL, to id: String, move: Bool) async throws -> StoredVideo {
        let fm = FileManager.default
        guard let existing = Self.readRecords(root: root).first(where: { $0.id == id }) else {
            Telemetry.log(.warn, .store, "store attach failed", data: ["step": "lookup", "reason": "not found"])
            throw OfflineStoreError.notFound
        }
        let ext = file.pathExtension.isEmpty
            ? (existing.kind == .webp ? "webp" : "mp4") : file.pathExtension.lowercased()
        let fileName = "\(id)-\(UUID().uuidString.prefix(6).lowercased()).\(ext)"
        let destination: URL
        do {
            destination = try await place(file, as: fileName, move: move)
        } catch {
            Telemetry.log(.error, .store, "store attach failed", data: Self.failureData(step: "place", error))
            throw error
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
        let refilled = result.video(root: root)
        Telemetry.log(.info, .store, "store attach", data: ["kind": .string(existing.kind.rawValue), "bytes": .bytes(size)])
        onAdd?(refilled)
        return refilled
    }

    /// Moves or copies `file` to `root/files/<name>` off the main actor: a 200 MB copy must not
    /// stall the orbit.
    private func place(_ file: URL, as name: String, move: Bool) async throws -> URL {
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
    /// kept on this device, so there is nothing to badge).
    @discardableResult
    public func setPublicURL(_ url: URL, forSession sessionID: String?, orEntry id: String? = nil) -> Int {
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
    public func setTitle(_ title: String?, media id: String) async {
        writeTitle(title, media: id)
    }

    /// `setTitle` for callers that must not suspend (an optimistic rename, a run). False when the index
    /// could not be written (the caller keeps the title in memory).
    @discardableResult
    func writeTitle(_ title: String?, media id: String) -> Bool {
        let cleaned = title.flatMap(MediaTitle.clean)
        var touched = 0
        guard let merged = try? Self.mutate(root: root, { records in
            for i in records.indices where records[i].media == id && records[i].title != cleaned {
                records[i].title = cleaned
                touched += 1
            }
        }) else { return false }
        if touched > 0 { adopt(merged) }
        return true
    }

    /// "keep videos on this iphone" turned off.
    public func dropFilesKeepingPosters() async {
        var names: [String] = []
        guard let records = try? Self.mutate(root: root, { records in
            for i in records.indices {
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

    /// "remove offline copy": drops the video file of one entry and keeps its record, poster and
    /// flipbook, exactly what the storage limit does to the oldest entries (the library and the orbit
    /// still show it; `attach` refills it with a fresh download). It is the owner's own choice, so the
    /// newest-entries protection of the limit does not apply; an entry a running pipeline pins
    /// (`isInUse`) is never evicted. `videos` and `usage` update.
    /// Returns whether a file was dropped: false for an unknown id, an entry with no file (already
    /// evicted, nothing to free) and an entry in use.
    @discardableResult
    public func evict(_ id: String) async -> Bool {
        guard !isInUse(id) else { return false }
        var name: String?
        guard let merged = try? Self.mutate(root: root, { records in
            guard let i = records.firstIndex(where: { $0.id == id }), let file = records[i].fileName else { return }
            name = file
            records[i].fileName = nil
        }) else { return false }
        // The index is written first; only then does the file go (a reader never sees a record
        // pointing at a deleted file).
        if let name { Self.delete(Eviction(files: [name]), root: root) }
        adopt(merged)
        return name != nil
    }

    /// Previews: writes poster-less, file-less entries into the index so `reload()` keeps them.
    func seed(_ seeds: [StoredVideo]) {
        let records = seeds.map { v in
            Record(
                id: v.id, kind: v.kind, fileName: nil, posterName: nil, name: v.name, duration: v.duration,
                width: v.width, height: v.height, bytes: v.bytes, sessionID: v.sessionID, link: v.link,
                remoteURL: v.remoteURL, createdAt: v.createdAt, publicURL: v.publicURL, mediaID: v.mediaID, clip: v.clip,
                title: v.title)
        }
        if let written = try? Self.mutate(root: root, { $0 = records }) {
            adopt(written)
        }
    }

    /// Re-reads the index (the share extension may have written), tidies leftovers and enforces the
    /// limit (the app calls this on every foreground, so it also covers app launch).
    public func reload() async {
        adopt(Self.reconciled(root: root))
        Self.purgeInbox(root: root, olderThan: Self.inboxLifetime)
        Self.purgeOrphanPreviews(
            root: root, referenced: Set(records.flatMap { $0.previewNames ?? [] }), olderThan: Self.inboxLifetime)
        await enforceLimit()
    }

    private func adopt(_ merged: [Record]) {
        records = merged
        videos = merged.map { $0.video(root: root) }
        media = StoredMedia.build(from: videos)
    }

    /// One coordinated write: `body` changes the merged index, then (unless `enforce` is false) the
    /// limit is applied to the result, all before the index is written. The evicted files are
    /// deleted only after that write.
    @discardableResult
    private func commit(
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
              let fileName = record.fileName, !previewFailures.contains(id) else { return }
        let animated: Bool
        switch Self.previewSource(kind: record.kind, isImage: Self.looksLikeImage(fileName)) {
        case .none: return
        case .animatedImage: animated = true
        case .video: animated = false
        }
        let file = root.appendingPathComponent("files/\(fileName)")
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

    struct Record: Codable {
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

        /// The effective media id.
        var media: String { mediaID ?? id }
        var added: Date { addedAt ?? createdAt }
        /// What this entry costs on the device: its file (if kept), its poster and its flipbook.
        var cost: Int64 {
            (fileName != nil ? bytes : 0) + (posterName != nil ? posterBytes ?? 0 : 0)
                + (previewNames?.isEmpty == false ? previewBytes ?? 0 : 0)
        }
        /// What is left of the entry when its file goes: poster and flipbook.
        var keptCost: Int64 { cost - (fileName != nil ? bytes : 0) }

        func video(root: URL) -> StoredVideo {
            StoredVideo(
                id: id, kind: kind,
                fileURL: fileName.map { root.appendingPathComponent("files/\($0)") },
                posterURL: posterName.map { root.appendingPathComponent("posters/\($0)") },
                name: name, duration: duration, width: width, height: height, bytes: bytes,
                sessionID: sessionID, link: link, remoteURL: remoteURL, createdAt: createdAt,
                previewFrameURLs: (previewNames ?? []).map { root.appendingPathComponent("previews/\($0)") },
                publicURL: publicURL, mediaID: media, clip: clip, title: title)
        }
    }

    /// Where a new record goes (CONTRACT-MEDIA 1.2), against the index as just re-read:
    /// 1. the caller's explicit media (the run was started from it), unless it does not exist any more or
    ///    already has a different original (at most one original per media: a second becomes its own);
    /// 2. else the media of any record with the same non-nil session (an original added after its webps
    ///    joins them; the same rule keeps a second original out of a media that has one);
    /// 3. else a new media, named by this record.
    static func resolveMediaID(for new: Record, explicit: String?, in records: [Record]) -> String {
        func hasOriginal(_ media: String) -> Bool { records.contains { $0.media == media && $0.kind == .original } }
        func accepts(_ media: String) -> Bool { !(new.kind == .original && hasOriginal(media)) }
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
    static func assignLegacyMediaIDs(_ records: inout [Record]) -> Bool {
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

    static func usage(of records: [Record]) -> StorageUsage {
        let kept = records.filter { $0.fileName != nil }
        return StorageUsage(count: kept.count, bytes: records.reduce(0) { $0 + $1.cost }, mediaCount: Set(kept.map(\.media)).count)
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
        var total = usage(of: records).bytes
        guard total > limit else { return plan }

        // Index order is newest first, so a later index means older when two stamps tie.
        var recency: [String: (Date, Int)] = [:]
        for i in records.indices {
            let key = (records[i].added, -i)
            if let current = recency[records[i].media], current >= key { continue }
            recency[records[i].media] = key
        }
        let newestMedia = Set(recency.sorted { $0.value > $1.value }.prefix(protectedNewest).map(\.key))
        func isProtected(_ r: Record) -> Bool { protecting.contains(r.id) || newestMedia.contains(r.media) }
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
                    return rows.allSatisfy { records[$0].fileName == nil && !protecting.contains(records[$0].id) }
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

    nonisolated private static func delete(_ plan: Eviction, root: URL) {
        let fm = FileManager.default
        for name in plan.files { try? fm.removeItem(at: root.appendingPathComponent("files/\(name)")) }
        for name in plan.posters { try? fm.removeItem(at: root.appendingPathComponent("posters/\(name)")) }
        for name in plan.previews { try? fm.removeItem(at: root.appendingPathComponent("previews/\(name)")) }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    private static func indexURL(root: URL) -> URL { root.appendingPathComponent("index.json") }

    private static func decode(_ url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// Reads, lets `body` change the records, and writes them back, all under one coordinated
    /// write so the app and the extension never lose each other's entries.
    @discardableResult
    private static func mutate(root: URL, _ body: (inout [Record]) -> Void) throws -> [Record] {
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
            var records = decode(u)
            // Every coordinated write first gives a legacy index its media ids (deterministic, so the
            // app and the extension agree), then applies the caller's change.
            _ = assignLegacyMediaIDs(&records)
            body(&records)
            do {
                try JSONEncoder().encode(records).write(to: u, options: .atomic)
                result = records
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure {
            Telemetry.log(.error, .store, "store index write failed", data: failureData(step: coordination != nil ? "coordinate" : "write", error))
            throw error
        }
        return result
    }

    private static func readRecords(root: URL) -> [Record] {
        var out: [Record] = []
        var coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: indexURL(root: root), options: [], error: &coordination) { u in
            out = decode(u)
        }
        return out
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
