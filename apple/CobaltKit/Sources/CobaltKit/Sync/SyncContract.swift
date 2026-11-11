import Foundation

// The app side of the Capystore sync engine (design slices 2 and 3). The server half — a stored post
// key, the change log, `GET /sync`, the ChangeFeed socket — is a different change and is not called
// until `SyncFeature` is on. With the flag off, nothing in this folder runs.

/// `UserDefaults` switch for the engine. Off unless this key is true, so today's library loading stays
/// as it is. A `404` from `GET /sync`, or a pull that fails with nothing on the device to show, also
/// leaves the flag on but uses today's loading for that launch.
enum SyncFeature {
    static let defaultsKey = "sync.engine"

    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

/// Where the on-device database lives, and the wire this client speaks.
///
/// The database is in the app's own container, never the app group. iOS kills a suspended app that
/// holds a lock on a database in a shared container, and the keyboard and Finder extension keep the
/// read-only `GET /library` snapshot they have today (hidden posts never appear there).
enum SyncContract {
    static let pageLimit = 500
    static let path = "/sync"
    /// `410` body, either a bare string or the API's `{error:{code}}` envelope.
    static let cursorTooOld = "sync.cursor_too_old"
    static let idempotencyHeader = "Idempotency-Key"

    /// Application Support, not the app group. Tests pass their own file instead.
    static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("CapystoreSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite")
    }
}

/// What a pull or a write can answer. A refusal is the only outcome that undoes a local edit;
/// anything else waits and is sent again.
enum SyncError: Error, Equatable, Sendable {
    /// `GET /sync` is not deployed (`404`). The caller uses today's `GET /library` pages.
    case notDeployed
    /// `410 sync.cursor_too_old`: delete markers older than the cursor were trimmed. Start again from 0.
    case cursorTooOld
    /// The server will not take this edit (a 400, a 404 on a title, a 409 that is not "busy", a 422).
    case refused(String)
    /// Offline, a 5xx, a 429, a busy 409: the edit stays queued.
    case retryable(String)
    /// `409 error.idempotency.conflict`: the server holds another body under this key. The edit is
    /// not refused; it is sent again under a new key.
    case keyConflict
}

enum SyncTrigger: String, Sendable {
    case launch, foreground, reconnect, outbox, nudge
}

/// One row of `gone`. `entity` is `post`, `link`, `collection`, `set`, `name` or `rule`.
struct SyncGone: Sendable, Equatable {
    var entity: String
    var id: String
}

/// A non-post row kept so a later slice can read it. The library screens do not.
struct SyncEntity: Sendable, Equatable {
    var id: String
    var json: Data
}

/// One page of `GET /sync?since=&limit=`.
///
/// ```
/// GET /sync?since=<seq>&limit=500
/// Authorization: Api-Key <key>
/// Accept: application/json
///
/// 200 {
///   "seq": 44,
///   "more": false,
///   "posts": [ <the same post object as GET /library, including created_at and files> ],
///   "links": [ { "id": "...", ... } ],
///   "collections": [], "sets": [], "names": [], "rules": [],
///   "gone": [ { "entity": "post", "id": "p3" } ]
/// }
/// 410 { "error": "sync.cursor_too_old" }     // or { "error": { "code": "sync.cursor_too_old" } }
/// 404                                        // route not deployed: fall back to GET /library
/// 503                                        // a database read failed: an error like any other 5xx
/// ```
///
/// `seq` is the cursor to send as `since` next time. `more` means call again with that `seq`.
/// Each post is a library post (`created_at` and `files` included). A post that cannot be read is
/// skipped; the cursor still advances. The short sketch in the design (`title`, `visibility`,
/// `hidden`, `files`) is that object with the fields the screen does not need left out — `created_at`
/// is required or the post is skipped.
struct SyncPage: Sendable, Equatable {
    var seq: Int64
    var more: Bool
    var posts: [LibraryPost]
    var links: [SyncEntity]
    var collections: [SyncEntity]
    var sets: [SyncEntity]
    var names: [SyncEntity]
    var rules: [SyncEntity]
    var gone: [SyncGone]

    static func decode(_ data: Data) throws -> SyncPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.retryable("sync page was not an object")
        }
        if isCursorTooOld(status: 200, data: data), root["seq"] == nil {
            throw SyncError.cursorTooOld
        }
        guard let seq = jsonInt(root["seq"]) else { throw SyncError.retryable("sync page had no seq") }
        let more = root["more"] as? Bool ?? false
        return SyncPage(
            seq: seq, more: more,
            posts: posts(in: root["posts"]),
            links: entities(in: root["links"]),
            collections: entities(in: root["collections"]),
            sets: entities(in: root["sets"]),
            names: entities(in: root["names"]),
            rules: entities(in: root["rules"]),
            gone: gones(in: root["gone"]))
    }

    func jsonData() throws -> Data {
        let posts = try self.posts.map { post -> Any in
            guard let data = SyncPostCoding.encode(post),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncStoreError(message: "could not encode post \(post.id)")
            }
            return object
        }
        let object: [String: Any] = [
            "seq": seq, "more": more, "posts": posts,
            "links": try Self.objects(links), "collections": try Self.objects(collections),
            "sets": try Self.objects(sets), "names": try Self.objects(names), "rules": try Self.objects(rules),
            "gone": gone.map { ["entity": $0.entity, "id": $0.id] },
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// True for a `410`, and for a body that names `sync.cursor_too_old` whatever the status.
    static func isCursorTooOld(status: Int, data: Data) -> Bool {
        if status == 410 { return true }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let code = root["error"] as? String, code == SyncContract.cursorTooOld { return true }
        if let env = root["error"] as? [String: Any], let code = env["code"] as? String, code == SyncContract.cursorTooOld {
            return true
        }
        return false
    }

    private static func objects(_ rows: [SyncEntity]) throws -> [Any] {
        try rows.map { row in
            (try JSONSerialization.jsonObject(with: row.json))
        }
    }

    private static func posts(in value: Any?) -> [LibraryPost] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { row in
            guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row) else {
                return nil
            }
            return SyncPostCoding.decode(data)
        }
    }

    private static func entities(in value: Any?) -> [SyncEntity] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return SyncEntity(id: id, json: data)
        }
    }

    private static func gones(in value: Any?) -> [SyncGone] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let entity = row["entity"] as? String, let id = row["id"] as? String, !entity.isEmpty, !id.isEmpty else {
                return nil
            }
            return SyncGone(entity: entity, id: id)
        }
    }

    private static func jsonInt(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

enum SyncPostCoding {
    static func encode(_ post: LibraryPost) -> Data? {
        try? CobaltJSON.encoder().encode(post)
    }

    static func decode(_ data: Data) -> LibraryPost? {
        try? CobaltJSON.decoder().decode(LibraryPost.self, from: data)
    }
}

/// A change waiting to be sent. `opID` names the row; it is also the `Idempotency-Key` until the
/// server answers that the key is taken by another body (`payload.key` then holds the new one).
/// `before` is the post as it was, so a refusal can put it back; nil means the post did not exist.
struct SyncOp: Sendable, Equatable {
    var opID: String
    var kind: Kind
    var target: String
    var payload: Payload
    var createdAt: Date
    var tries: Int
    var nextAttemptAt: Date
    /// The op is with the sender. Set in the store before the request leaves, so a later edit is
    /// queued behind it instead of being written into a request that is already on its way.
    var sending = false

    /// What goes in the `Idempotency-Key` header.
    var idempotencyKey: String { payload.key ?? opID }

    enum Kind: String, Sendable, Codable { case title, delete, hide, visibility }

    struct Payload: Sendable, Equatable, Codable {
        var anchor: String
        var title: String?
        var status: String?
        var makePublic: Bool?
        var fileID: String?
        var before: Data?
        /// Set after a `409 error.idempotency.conflict`; nil means the op id is the key.
        var key: String?
    }
}

/// What the server said about an edit it took, where that is not simply "done as asked".
struct SyncReceipt: Sendable, Equatable {
    /// The post as the server left it, when it could not do all that was asked (a status change some
    /// files did not take, a delete that left files). Nil: the device's own row stands.
    var post: LibraryPost?
    /// File ids a delete left on the server (`502 error.library.partial`). Empty for a whole delete.
    var remaining: [String] = []

    static let done = SyncReceipt()
}

/// Pending edits win over a pulled row until the server accepts them.
enum SyncMerge {
    /// The pulled post with pending edits laid on top, or nil when a pending delete keeps it gone.
    /// `ops` are in outbox order (the store reads them so): two edits stamped the same instant keep
    /// the order they were made in.
    static func overlay(_ post: LibraryPost, ops: [SyncOp]) -> LibraryPost? {
        let mine = ops.filter { $0.target == post.id }
        if mine.contains(where: { $0.kind == .delete }) { return nil }
        var post = post
        for op in mine { apply(op, to: &post) }
        return post
    }

    /// A `gone` marker removes the row unless a pending edit (not a pending delete) still owns it.
    static func keepsRow(id: String, ops: [SyncOp]) -> Bool {
        let mine = ops.filter { $0.target == id }
        return mine.contains { $0.kind != .delete }
    }

    /// A new edit may be written into a queued one only when both are the same edit of the same
    /// thing. One file's switch and another file's, or one file's switch and the whole post's status,
    /// are different edits: each keeps its own op.
    static func sameEdit(_ a: SyncOp, _ b: SyncOp) -> Bool {
        a.kind == b.kind && a.target == b.target && a.payload.fileID == b.payload.fileID
            && (a.payload.makePublic == nil) == (b.payload.makePublic == nil)
    }

    /// The post after `POST /library/status` took it but could not switch every file. The same rules
    /// as the library's own handling of that answer: the server's word for each file it describes, a
    /// failed file it does not describe stays as it was, the rest follow the status.
    static func settle(_ before: LibraryPost, answer: StatusChange.Post, failedFiles: Set<String>) -> LibraryPost {
        var post = before
        if answer.status == .hidden {
            post.hidden = true
            post.hiddenBy = .you
            post.hiddenRule = nil
        } else {
            post.hidden = false
            post.hiddenBy = nil
            post.hiddenRule = nil
        }
        for index in post.files.indices {
            let id = post.files[index].id
            let wire = answer.files.first { $0.id == id }
            if wire == nil, failedFiles.contains(id) { continue }
            let isPublic = wire.map { $0.visibility == "public" } ?? (answer.status == .public)
            if isPublic {
                post.files[index].wireVisibility = .public
                post.files[index].privateURL = nil
            } else {
                post.files[index].wireVisibility = .private
                post.files[index].url = nil
                post.files[index].privateURL = answer.status == .private ? wire?.privateURL : nil
            }
        }
        if post.visibility != nil {
            let files = post.files
            if answer.status == .hidden {
                post.visibility = files.contains(where: \.isPublic) ? .public : .private
            } else {
                post.visibility = files.first { $0.role == .privateCopy }?.visibility
                    ?? (files.contains(where: \.isPublic) ? .public : .private)
            }
        }
        return post
    }

    static func apply(_ op: SyncOp, to post: inout LibraryPost) {
        switch op.kind {
        case .delete:
            break
        case .title:
            post.customTitle = op.payload.title
        case .hide:
            let status = PostStatus(rawValue: op.payload.status ?? PostStatus.hidden.rawValue) ?? .hidden
            apply(status, to: &post)
        case .visibility:
            if let makePublic = op.payload.makePublic {
                let fileID = op.payload.fileID ?? op.payload.anchor
                if let index = post.files.firstIndex(where: { $0.id == fileID }) {
                    post.files[index].wireVisibility = makePublic ? .public : .private
                    if !makePublic { post.files[index].url = nil }
                }
                let files = post.files
                post.visibility = files.first { $0.role == .privateCopy }?.visibility
                    ?? (files.contains(where: \.isPublic) ? .public : .private)
            } else if let status = op.payload.status.flatMap(PostStatus.init(rawValue:)) {
                apply(status, to: &post)
            }
        }
    }

    static func apply(_ status: PostStatus, to post: inout LibraryPost) {
        switch status {
        case .hidden:
            post.hidden = true
            post.hiddenBy = .you
            post.hiddenRule = nil
        case .off:
            post.hidden = false
            post.hiddenBy = nil
            post.hiddenRule = nil
        case .public, .private:
            post.hidden = false
            post.hiddenBy = nil
            post.hiddenRule = nil
            post.visibility = status == .public ? .public : .private
            for index in post.files.indices {
                post.files[index].wireVisibility = post.visibility
                if status == .private { post.files[index].url = nil }
            }
        }
    }
}

/// What the library screen is filled from. Visible posts are the library; hidden posts are the album.
struct SyncLibrarySnapshot: Sendable, Equatable {
    var visible: [LibraryPost]
    var hidden: [LibraryPost]
    var caughtUp: Bool

    var postCount: Int { visible.count }
    var hiddenCount: Int { hidden.count }
    var fileCount: Int { visible.reduce(0) { $0 + $1.files.count } }
}

struct SyncStoreError: Error, Equatable, Sendable {
    var message: String
}

/// How the engine asks. The real one is `GET /sync`; tests pass a scripted double.
protocol SyncTransport: Sendable {
    func pull(since: Int64, limit: Int) async throws -> SyncPage
}

/// How a queued edit is sent through today's write routes. The key is `op.idempotencyKey`.
protocol SyncSender: Sendable {
    func send(_ op: SyncOp) async throws -> SyncReceipt
}
