import Foundation

/// What identifies an item for "once per item, durable" (CONTRACT-SYNC.md decision 10). The key does
/// not depend on the offline index record, so eviction or the removal of a whole record never
/// brings an item back, and a refill (`attach`) has the same key.
enum PhotosKey {
    static func of(_ v: StoredVideo) -> String {
        of(kind: v.kind, sessionID: v.sessionID, remoteURL: v.remoteURL, storeID: v.id)
    }

    static func of(kind: StoredVideo.Kind, sessionID: String?, remoteURL: URL?, storeID: String) -> String {
        switch kind {
        case .original:
            if let sessionID { return "s:\(sessionID)" }
            if let remoteURL { return "r:\(remoteURL.absoluteString)" }
        case .webp:
            if let remoteURL { return "w:\(remoteURL.absoluteString)" }
        }
        return "i:\(storeID)"
    }

    /// The key of a studio session's original.
    static func original(session id: String) -> String { "s:\(id)" }
    static func picker(url: URL) -> String { "r:\(url.absoluteString)" }
}

/// One item's record in the ledger.
struct PhotosEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case claimed, done, failed, skipped }
    /// Where a `done` asset is: in the album, only in the library, or no longer there.
    enum InAlbum: String, Codable, Sendable { case yes, no, gone }
    enum Skip: String, Codable, Sendable { case preexisting, gaveUp }
    /// Who added it: the sync, or the owner's own "save to photos".
    enum Origin: String, Codable, Sendable { case sync, manual }

    var state: State
    var at: Date
    var asset: String?
    var inAlbum: InAlbum = .no
    var code: Int?
    var tries: Int = 0
    var skip: Skip?
    var origin: Origin = .sync
}

struct PhotosAlbumRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
}

struct PhotosLedgerFile: Codable, Equatable, Sendable {
    var album: PhotosAlbumRecord?
    var items: [String: PhotosEntry] = [:]
}

/// `PhotosLedger`: the app group's `Sync/photos.json`, read and written under `NSFileCoordinator` like
/// `SharedJobStore`. The sync claims an item here before it touches PhotoKit, writes the asset's id
/// inside the change block, and marks it done once PhotoKit committed: never twice, and no re-adding
/// of what the owner deleted in Photos (nothing ever re-checks in order to re-add).
final class PhotosLedger: Sendable {
    /// A claim older than this is "in doubt": the process died (or the write is slow) and nobody
    /// knows whether Photos kept the asset.
    static let staleClaim: TimeInterval = 120
    static let maxTries = 3

    private let file: CoordinatedFile<PhotosLedgerFile>

    init(directory: URL) {
        file = CoordinatedFile(url: directory.appendingPathComponent("photos.json"), empty: PhotosLedgerFile())
    }

    private static let sharedInstance = PhotosLedger(directory: AppGroup.directory("Sync"))
    static func shared() -> PhotosLedger { sharedInstance }

    var url: URL { file.url }

    // MARK: Reading

    func snapshot() -> PhotosLedgerFile { file.read() }
    func entry(_ key: String) -> PhotosEntry? { file.read().items[key] }
    var album: PhotosAlbumRecord? { file.read().album }

    // MARK: Claiming

    enum Claim: Equatable, Sendable {
        case claimed                    // yours: go ahead
        case alreadyDone
        case skipped
        case inFlight                   // somebody else's claim, still fresh
        case doubt(PhotosEntry)         // an old claim: settle it (`settle`) before going on
    }

    /// Atomic: the entry is read and (when free) claimed in one coordinated write.
    func claim(_ key: String, now: Date) -> Claim {
        file.mutate { f in
            guard let e = f.items[key] else {
                f.items[key] = PhotosEntry(state: .claimed, at: now)
                return .claimed
            }
            switch e.state {
            case .done: return .alreadyDone
            case .skipped: return .skipped
            case .claimed:
                if now.timeIntervalSince(e.at) < Self.staleClaim { return .inFlight }
                return .doubt(e)
            case .failed:
                var next = e
                next.state = .claimed
                next.at = now
                f.items[key] = next
                return .claimed
            }
        }
    }

    /// The change block hands out the placeholder's id: kept in the claim before PhotoKit commits.
    func recordAsset(_ key: String, _ asset: String) {
        file.mutate { f in
            guard var e = f.items[key], e.state == .claimed else { return }
            e.asset = asset
            f.items[key] = e
        }
    }

    /// PhotoKit committed.
    func finish(_ key: String, asset: String?, inAlbum: PhotosEntry.InAlbum, origin: PhotosEntry.Origin = .sync, now: Date) {
        file.mutate { f in
            var e = f.items[key] ?? PhotosEntry(state: .done, at: now)
            e.state = .done
            e.at = now
            e.asset = asset ?? e.asset
            e.inAlbum = inAlbum
            e.code = nil
            e.skip = nil
            if f.items[key] == nil { e.origin = origin }
            f.items[key] = e
        }
    }

    /// Back to "not tried": out of space, library unavailable, access taken away.
    func release(_ key: String) {
        file.mutate { f in
            if f.items[key]?.state == .claimed { f.items[key] = nil }
        }
    }

    /// A failure that is not "try later": counted; the third becomes `skipped(gaveUp)`.
    @discardableResult
    func fail(_ key: String, code: Int, now: Date) -> PhotosEntry.State {
        file.mutate { f in
            var e = f.items[key] ?? PhotosEntry(state: .failed, at: now)
            e.tries += 1
            e.code = code
            e.at = now
            e.asset = nil
            if e.tries >= Self.maxTries {
                e.state = .skipped
                e.skip = .gaveUp
            } else {
                e.state = .failed
            }
            f.items[key] = e
            return e.state
        }
    }

    // MARK: Skipping

    /// Marks items that have no entry yet: "already there before the album was on" (the backfill
    /// prompt, the include-webps toggle). An item that has an entry keeps it.
    func skipPreexisting(_ keys: [String], now: Date) {
        guard !keys.isEmpty else { return }
        file.mutate { f in
            for key in keys where f.items[key] == nil {
                var e = PhotosEntry(state: .skipped, at: now)
                e.skip = .preexisting
                f.items[key] = e
            }
        }
    }

    /// "add N": the entries `skipPreexisting` wrote for these keys go, so the items are eligible again.
    func unskipPreexisting(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        file.mutate { f in
            for key in keys where f.items[key]?.state == .skipped && f.items[key]?.skip == .preexisting {
                f.items[key] = nil
            }
        }
    }

    // MARK: Album

    func setAlbum(_ album: PhotosAlbumRecord) { file.mutate { $0.album = album } }

    func setInAlbum(_ keys: [String], _ value: PhotosEntry.InAlbum) {
        guard !keys.isEmpty else { return }
        file.mutate { f in
            for key in keys where f.items[key]?.state == .done { f.items[key]?.inAlbum = value }
        }
    }

    // MARK: The owner's own save

    /// A manual "save to photos" is an explicit request: it is recorded as a new asset even over an
    /// older entry (the asset the ledger knew may be gone), and the sync never adds that item again.
    func recordManual(_ key: String, asset: String?, inAlbum: PhotosEntry.InAlbum, now: Date) {
        file.mutate { f in
            var e = PhotosEntry(state: .done, at: now)
            e.asset = asset
            e.inAlbum = inAlbum
            e.origin = .manual
            f.items[key] = e
        }
    }
}
