import Foundation
import SQLite3

/// The on-device library. One connection, used only from this actor, so library reads and the outbox
/// never touch the main thread and never the app-group container the keyboard and Finder share.
///
/// SQLite, not SwiftData: the design is these tables, the package already forbids third-party
/// dependencies, and a `sqlite3` connection can be opened on a background actor and exercised from
/// the package tests. SwiftData would tie the copy to a container the screens own.
actor SyncStore {
    /// Owns the connection so the actor's deinit never touches a non-Sendable pointer. Every statement
    /// still runs on this actor; the box only closes the database when the store is released.
    private let connection: Connection
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var db: OpaquePointer? { connection.db }

    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(fileURL.path, &opened, flags, nil)
        guard rc == SQLITE_OK, let opened else {
            let message = opened.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite \(rc)"
            sqlite3_close(opened)
            throw SyncStoreError(message: message)
        }
        connection = Connection(opened)
        // `init` is nonisolated, so the schema is applied with the pointer in hand rather than through
        // the actor's methods.
        try Self.exec(opened, "PRAGMA journal_mode=WAL")
        try Self.exec(opened, "PRAGMA busy_timeout=2000")
        try Self.exec(opened, Self.schema)
        try Self.addSendingColumn(opened)
        // A send the last launch never heard back from (the app was closed or killed mid-request). The
        // server may hold it, so it counts as one try: nothing is merged into it and it goes out again
        // under the same key.
        try Self.exec(opened, "UPDATE outbox SET tries = MAX(tries, 1), sending = 0 WHERE sending = 1")
    }

    // MARK: - Posts

    func upsert(_ post: LibraryPost) throws {
        try transaction { try write(post) }
    }

    func post(id: String) throws -> LibraryPost? {
        try queryPosts("SELECT json FROM posts WHERE id = ?", strings: [id]).first
    }

    /// Local filter, sort and name search. The screen uses the same rules on the posts this returns
    /// (every post is loaded; `libraryRows` then filters in memory). This query is what a caller asks
    /// when it does not want the whole list, and what the tests pin.
    func posts(hidden: Bool, name: String = "", visibility: String? = nil, kind: String? = nil, sort: SyncLibrarySort = .newest) throws -> [LibraryPost] {
        var sql = "SELECT json FROM posts WHERE hidden = ?"
        var strings = [hidden ? "1" : "0"]
        // The name is bound, never interpolated. `ESCAPE` keeps a typed `%` from matching everything.
        if !name.isEmpty {
            sql += " AND (title LIKE ? ESCAPE '\\' OR json LIKE ? ESCAPE '\\')"
            let pattern = like(name)
            strings.append(pattern)
            strings.append(pattern)
        }
        if let visibility {
            sql += " AND visibility = ?"
            strings.append(visibility)
        }
        if let kind {
            sql += " AND kind = ?"
            strings.append(kind)
        }
        sql += " ORDER BY \(sort.column) \(sort.ascending ? "ASC" : "DESC"), created_at DESC, id ASC"
        return try queryPosts(sql, strings: strings, hiddenAsInt: true, hidden: hidden)
    }

    func snapshot() throws -> SyncLibrarySnapshot {
        SyncLibrarySnapshot(
            visible: try posts(hidden: false),
            hidden: try posts(hidden: true),
            caughtUp: meta("caught_up") == "1")
    }

    func hasReadyMarker() -> Bool { meta("ready") == "1" }

    func cursor() -> Int64 { Int64(meta("cursor") ?? "0") ?? 0 }

    /// Applies one page. Pending edits are laid over the pulled rows in the same transaction, so a
    /// post the device just renamed does not flicker back to the older title.
    func apply(_ page: SyncPage) throws {
        try transaction {
            let pending = try readOps()
            let held = try heldGone()
            for post in page.posts {
                // the server lists it again: an older delete marker for it no longer holds
                if held.contains(post.id) { try releaseGone(post.id) }
                if let merged = SyncMerge.overlay(post, ops: pending) {
                    try write(merged)
                } else {
                    try removePost(post.id)
                }
            }
            for gone in page.gone {
                if gone.entity == "post" {
                    if SyncMerge.keepsRow(id: gone.id, ops: pending) {
                        // The server sends a marker once. It is kept until the edit is settled, and
                        // applied then (`applyHeldGone`).
                        try holdGone(gone.id)
                        continue
                    }
                    try removePost(gone.id)
                } else if let table = Self.table(for: gone.entity) {
                    try removeEntity(table, id: gone.id)
                }
            }
            for row in page.links { try writeEntity("links", row) }
            for row in page.collections { try writeEntity("collections", row) }
            for row in page.sets { try writeEntity("sets", row) }
            for row in page.names { try writeEntity("names", row) }
            for row in page.rules { try writeEntity("rules", row) }
            try putMeta("cursor", String(page.seq))
            try putMeta("ready", "1")
            try putMeta("caught_up", page.more ? "0" : "1")
        }
    }

    /// `410`: the cursor is too old to trust, so the copy is dropped and the next pull starts at 0.
    /// The outbox stays; those edits have not been confirmed.
    func resetCursor() throws {
        try transaction {
            try exec("DELETE FROM posts")
            for table in Self.entityTables { try exec("DELETE FROM \(table)") }
            try putMeta("cursor", "0")
            try putMeta("ready", "0")
            try putMeta("caught_up", "0")
        }
    }

    /// A different server, or a sign-out: the copy and the outbox both go.
    func wipeAll() throws {
        try transaction {
            try exec("DELETE FROM posts")
            try exec("DELETE FROM outbox")
            try exec("DELETE FROM held_gone")
            for table in Self.entityTables { try exec("DELETE FROM \(table)") }
            try putMeta("cursor", "0")
            try putMeta("ready", "0")
            try putMeta("caught_up", "0")
        }
    }

    func entity(table: String, id: String) throws -> Data? {
        guard Self.entityTables.contains(table) else { return nil }
        let sql = "SELECT json FROM \(table) WHERE id = ?"
        return try queryBlob(sql, id: id)
    }

    // MARK: - Outbox

    /// Writes the post and the op in one transaction. The edit is written into the newest queued op
    /// for the post when that op is the same edit (`SyncMerge.sameEdit`) and was never handed to the
    /// sender: it keeps its id and its `before` (a refusal returns to the original). An op that is
    /// being sent, or was sent and is waiting to be retried, is never rewritten: the server may hold
    /// its body under its key, so the new edit gets its own op and is sent after it.
    @discardableResult
    func commit(post: LibraryPost?, op: SyncOp) throws -> SyncOp {
        var stored = op
        try transaction {
            if let post { try write(post) } else { try removePost(op.target) }
            if let existing = try mergeable(with: op) {
                stored = existing
                stored.payload.title = op.payload.title
                stored.payload.status = op.payload.status
                stored.payload.makePublic = op.payload.makePublic
                stored.payload.fileID = op.payload.fileID
                stored.payload.anchor = op.payload.anchor
                try update(stored)
            } else {
                try insert(op)
            }
        }
        return stored
    }

    func pendingOps() throws -> [SyncOp] { try readOps() }

    /// Hands an op to the sender: marks it as sending and returns it as it is stored now, which may
    /// be newer than the copy the drain listed. Nil when it is no longer in the outbox.
    func beginSend(_ id: String) throws -> SyncOp? {
        var handed: SyncOp?
        try transaction {
            try run("UPDATE outbox SET sending = 1 WHERE op_id = ?") { stmt in bind(stmt, 1, id) }
            handed = try readOps().first { $0.opID == id }
        }
        return handed
    }

    func markRetry(_ op: SyncOp, tries: Int, next: Date) throws {
        try transaction {
            let sql = "UPDATE outbox SET tries = ?, next_attempt_at = ?, sending = 0 WHERE op_id = ?"
            try run(sql) { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(tries))
                sqlite3_bind_int64(stmt, 2, Self.millis(next))
                bind(stmt, 3, op.opID)
            }
        }
    }

    /// `409 error.idempotency.conflict`: the op waits like any retry and goes out under a new key.
    /// The op id stays, so whoever is waiting on it still finds it.
    func rekey(_ op: SyncOp, tries: Int, next: Date) throws {
        var renewed = op.payload
        renewed.key = UUID().uuidString
        let payload = try json(renewed)
        try transaction {
            let sql = "UPDATE outbox SET payload = ?, tries = ?, next_attempt_at = ?, sending = 0 WHERE op_id = ?"
            try run(sql) { stmt in
                bind(stmt, 1, payload)
                sqlite3_bind_int64(stmt, 2, Int64(tries))
                sqlite3_bind_int64(stmt, 3, Self.millis(next))
                bind(stmt, 4, op.opID)
            }
        }
    }

    func removeOp(_ id: String) throws {
        try transaction {
            let target = try readOps().first { $0.opID == id }?.target
            guard try deleteOp(id), let target else { return }
            try applyHeldGone(target)
        }
    }

    /// The server took the op. `post` is its answer where that is not what the device assumed; edits
    /// still queued for the post are laid over it. Nothing is written when the op is no longer in the
    /// outbox (it was wiped for another server while the request was out).
    func settle(_ op: SyncOp, post: LibraryPost?) throws {
        try transaction {
            guard try deleteOp(op.opID) else { return }
            if let post {
                let rest = try readOps()
                if let merged = SyncMerge.overlay(post, ops: rest) {
                    try write(merged)
                } else {
                    try removePost(post.id)
                }
            }
            try applyHeldGone(op.target)
        }
    }

    /// Puts `before` back and drops the op. Returns the restored post, or nil when nothing went back:
    /// the edit had created the post, the server has since said the post is gone, or the op is no
    /// longer in the outbox (it was wiped for another server while the request was out).
    ///
    /// Edits queued after this one for the same post were made on top of it. They are laid over the
    /// restored post, and each one's `before` is moved to the post without the refused edit, so a
    /// second refusal does not bring the first one's change back.
    @discardableResult
    func rollback(_ op: SyncOp) throws -> LibraryPost? {
        var restored = op.payload.before.flatMap(SyncPostCoding.decode)
        try transaction {
            guard try deleteOp(op.opID) else {
                restored = nil
                return
            }
            let later = try readOps().filter { $0.target == op.target }
            if try heldGone().contains(op.target) {
                restored = nil
                if later.isEmpty { try applyHeldGone(op.target) }
                return
            }
            var base = restored
            for var next in later {
                next.payload.before = base.flatMap(SyncPostCoding.encode)
                try update(next)
                if next.kind == .delete {
                    base = nil
                } else if var post = base {
                    SyncMerge.apply(next, to: &post)
                    base = post
                }
            }
            if let base { try write(base) } else { try removePost(op.target) }
        }
        return restored
    }

    // MARK: - SQL

    /// Closes the sqlite connection when the store goes away. `@unchecked` because the pointer is only
    /// used on the store's actor until this deinit, which runs after that use has ended.
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer?
        init(_ db: OpaquePointer?) { self.db = db }
        deinit { sqlite3_close(db) }
    }

    private static let entityTables = ["links", "collections", "sets", "names", "rules"]

    /// `gone.entity` is singular (`link`); the table is plural (`links`).
    private static func table(for entity: String) -> String? {
        switch entity {
        case "link", "links": return "links"
        case "collection", "collections": return "collections"
        case "set", "sets": return "sets"
        case "name", "names": return "names"
        case "rule", "rules": return "rules"
        default: return nil
        }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS posts (
      id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL,
      kind TEXT,
      visibility TEXT,
      hidden INTEGER NOT NULL DEFAULT 0,
      title TEXT,
      json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS posts_created ON posts (created_at);
    CREATE INDEX IF NOT EXISTS posts_hidden_created ON posts (hidden, created_at);
    CREATE INDEX IF NOT EXISTS posts_title ON posts (title);
    CREATE INDEX IF NOT EXISTS posts_visibility ON posts (visibility);
    CREATE INDEX IF NOT EXISTS posts_kind ON posts (kind);
    CREATE TABLE IF NOT EXISTS links (id TEXT PRIMARY KEY, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS collections (id TEXT PRIMARY KEY, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS sets (id TEXT PRIMARY KEY, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS names (id TEXT PRIMARY KEY, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS rules (id TEXT PRIMARY KEY, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS outbox (
      op_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      target TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      tries INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS outbox_order ON outbox (created_at);
    CREATE TABLE IF NOT EXISTS held_gone (id TEXT PRIMARY KEY);
    """

    /// `sending` came after the first databases were made, and `CREATE TABLE IF NOT EXISTS` leaves an
    /// existing table as it is. Adding a column that is already there is the one error let through.
    private static func addSendingColumn(_ db: OpaquePointer) throws {
        do {
            try exec(db, "ALTER TABLE outbox ADD COLUMN sending INTEGER NOT NULL DEFAULT 0")
        } catch let error as SyncStoreError {
            guard error.message.contains("duplicate column name") else { throw error }
        }
    }

    private func write(_ post: LibraryPost) throws {
        guard let json = SyncPostCoding.encode(post) else {
            throw SyncStoreError(message: "could not encode post \(post.id)")
        }
        let text = String(decoding: json, as: UTF8.self)
        let sql = """
        INSERT INTO posts (id, created_at, kind, visibility, hidden, title, json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          created_at = excluded.created_at, kind = excluded.kind, visibility = excluded.visibility,
          hidden = excluded.hidden, title = excluded.title, json = excluded.json
        """
        try run(sql) { stmt in
            bind(stmt, 1, post.id)
            sqlite3_bind_int64(stmt, 2, Self.millis(post.createdAt))
            bind(stmt, 3, post.kind?.rawValue ?? "")
            bind(stmt, 4, post.visibility?.rawValue ?? "")
            sqlite3_bind_int64(stmt, 5, post.hidden ? 1 : 0)
            bind(stmt, 6, post.customTitle ?? post.title ?? "")
            bind(stmt, 7, text)
        }
    }

    private func removePost(_ id: String) throws {
        try run("DELETE FROM posts WHERE id = ?") { stmt in bind(stmt, 1, id) }
    }

    private func writeEntity(_ table: String, _ row: SyncEntity) throws {
        let text = String(decoding: row.json, as: UTF8.self)
        let sql = "INSERT INTO \(table) (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json"
        try run(sql) { stmt in
            bind(stmt, 1, row.id)
            bind(stmt, 2, text)
        }
    }

    private func removeEntity(_ table: String, id: String) throws {
        try run("DELETE FROM \(table) WHERE id = ?") { stmt in bind(stmt, 1, id) }
    }

    private func queryPosts(_ sql: String, strings: [String], hiddenAsInt: Bool = false, hidden: Bool = false) throws -> [LibraryPost] {
        try query(sql) { stmt in
            var index: Int32 = 1
            if hiddenAsInt {
                sqlite3_bind_int64(stmt, index, hidden ? 1 : 0)
                index += 1
                for string in strings.dropFirst() {
                    bind(stmt, index, string)
                    index += 1
                }
            } else {
                for string in strings {
                    bind(stmt, index, string)
                    index += 1
                }
            }
        } row: { stmt in
            guard let text = column(stmt, 0), let data = text.data(using: .utf8) else { return nil }
            return SyncPostCoding.decode(data)
        }
    }

    private func queryBlob(_ sql: String, id: String) throws -> Data? {
        let rows: [Data] = try query(sql) { stmt in bind(stmt, 1, id) } row: { stmt in
            column(stmt, 0)?.data(using: .utf8)
        }
        return rows.first
    }

    /// Oldest first. Two ops stamped the same instant keep the order they were queued in (`rowid`).
    private func readOps() throws -> [SyncOp] {
        try query("SELECT op_id, kind, target, payload, created_at, tries, next_attempt_at, sending FROM outbox ORDER BY created_at ASC, rowid ASC") { _ in
        } row: { stmt in
            guard let id = column(stmt, 0), let kindRaw = column(stmt, 1), let kind = SyncOp.Kind(rawValue: kindRaw),
                  let target = column(stmt, 2), let payloadText = column(stmt, 3),
                  let payloadData = payloadText.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(SyncOp.Payload.self, from: payloadData) else { return nil }
            return SyncOp(
                opID: id, kind: kind, target: target, payload: payload,
                createdAt: Self.date(sqlite3_column_int64(stmt, 4)),
                tries: Int(sqlite3_column_int64(stmt, 5)),
                nextAttemptAt: Self.date(sqlite3_column_int64(stmt, 6)),
                sending: sqlite3_column_int64(stmt, 7) != 0)
        }
    }

    /// The op a new edit may be written into: the newest one queued for the post, when it is the
    /// same edit and no sender ever had it. Only the newest, so the order of edits is kept (a file
    /// switched, the whole post made private, the file switched again are three ops, not two).
    private func mergeable(with op: SyncOp) throws -> SyncOp? {
        guard let newest = try readOps().last(where: { $0.target == op.target }),
              newest.tries == 0, !newest.sending, SyncMerge.sameEdit(newest, op) else { return nil }
        return newest
    }

    /// True when the row was there.
    private func deleteOp(_ id: String) throws -> Bool {
        try run("DELETE FROM outbox WHERE op_id = ?") { stmt in bind(stmt, 1, id) }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Delete markers held for a pending edit

    private func heldGone() throws -> Set<String> {
        let ids: [String] = try query("SELECT id FROM held_gone") { _ in } row: { stmt in column(stmt, 0) }
        return Set(ids)
    }

    private func holdGone(_ id: String) throws {
        try run("INSERT OR IGNORE INTO held_gone (id) VALUES (?)") { stmt in bind(stmt, 1, id) }
    }

    private func releaseGone(_ id: String) throws {
        try run("DELETE FROM held_gone WHERE id = ?") { stmt in bind(stmt, 1, id) }
    }

    /// The last edit for a post has left the outbox: a delete marker that was held for it is applied.
    private func applyHeldGone(_ target: String) throws {
        guard try heldGone().contains(target) else { return }
        if try readOps().contains(where: { $0.target == target }) { return }
        try removePost(target)
        try releaseGone(target)
    }

    private func insert(_ op: SyncOp) throws {
        let payload = try json(op.payload)
        let sql = "INSERT INTO outbox (op_id, kind, target, payload, created_at, tries, next_attempt_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
        try run(sql) { stmt in
            bind(stmt, 1, op.opID)
            bind(stmt, 2, op.kind.rawValue)
            bind(stmt, 3, op.target)
            bind(stmt, 4, payload)
            sqlite3_bind_int64(stmt, 5, Self.millis(op.createdAt))
            sqlite3_bind_int64(stmt, 6, Int64(op.tries))
            sqlite3_bind_int64(stmt, 7, Self.millis(op.nextAttemptAt))
        }
    }

    private func update(_ op: SyncOp) throws {
        let payload = try json(op.payload)
        try run("UPDATE outbox SET payload = ? WHERE op_id = ?") { stmt in
            bind(stmt, 1, payload)
            bind(stmt, 2, op.opID)
        }
    }

    private func meta(_ key: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return column(stmt, 0)
    }

    private func putMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, value)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw SyncStoreError(message: "database is closed") }
        try Self.exec(db, sql)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite \(rc)"
            sqlite3_free(error)
            throw SyncStoreError(message: message)
        }
    }

    private func run(_ sql: String, bind bindBlock: (OpaquePointer?) -> Void) throws {
        guard let db else { throw SyncStoreError(message: "database is closed") }
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        defer { sqlite3_finalize(stmt) }
        bindBlock(stmt)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            try check(rc)
            throw SyncStoreError(message: "sqlite \(rc)")
        }
    }

    private func query<T>(_ sql: String, bind bindBlock: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> T?) throws -> [T] {
        guard let db else { throw SyncStoreError(message: "database is closed") }
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        defer { sqlite3_finalize(stmt) }
        bindBlock(stmt)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { try check(rc); break }
            if let value = row(stmt) { out.append(value) }
        }
        return out
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK || rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "sqlite \(rc)"
            throw SyncStoreError(message: message)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { cString in
            sqlite3_bind_text(stmt, index, cString, -1, transient)
        }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
    }

    private func json(_ payload: SyncOp.Payload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func like(_ raw: String) -> String {
        var escaped = ""
        for character in raw {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

/// Sort keys the `posts` table can answer without reading every JSON blob into Swift.
struct SyncLibrarySort: Sendable, Equatable {
    var key: String
    var ascending: Bool

    static let newest = SyncLibrarySort(key: "date", ascending: false)

    /// A column name from a fixed list. Anything else sorts by date, so a caller cannot inject SQL.
    var column: String {
        switch key {
        case "title": return "title COLLATE NOCASE"
        case "visibility": return "visibility"
        case "kind": return "kind"
        default: return "created_at"
        }
    }
}
