import Foundation
import Network
import Synchronization

/// The library's copy of the engine. Created only when `SyncFeature` is on. Screens keep reading
/// `LibraryModel`; this fills it from the store at launch and after every pass, so a filter, a sort
/// or a name search never waits on the network once the copy is here.
///
/// The database stays in the app container. The keyboard and the Finder extension are unchanged:
/// they still walk `GET /library` and still drop hidden posts.
@MainActor
final class LibrarySync {
    let store: SyncStore
    private let engine: SyncEngine
    private let paths = SyncPathWatch()
    private var confirmations: [String: @MainActor () async -> Void] = [:]
    private var undos: [String: @MainActor () -> Void] = [:]
    private var connected = false
    /// False after `GET /sync` answers 404. Today's library loading takes over for this launch.
    private(set) var isActive = true
    var onApply: (@MainActor (SyncLibrarySnapshot, String) -> Void)?
    /// The route is missing and the cache, if any, must not be the only copy the screen keeps.
    var onLegacy: (@MainActor () async -> Void)?

    init(store: SyncStore, transport: any SyncTransport, sender: any SyncSender) {
        self.store = store
        self.engine = SyncEngine(store: store, transport: transport, sender: sender)
    }

    /// The real client. `client` is read on each request, so a server change is picked up.
    convenience init(databaseURL: URL, client: @escaping @MainActor () -> HTTPCobaltClient?) throws {
        let store = try SyncStore(fileURL: databaseURL)
        let http = HTTPSyncClient(client: client)
        self.init(store: store, transport: http, sender: http)
    }

    /// Launch. A copy from last time is shown before the pull, and the pull is the launch trigger.
    func start() async {
        await connect()
        if await store.hasReadyMarker(), let snapshot = try? await store.snapshot(), !snapshot.visible.isEmpty || !snapshot.hidden.isEmpty {
            deliver(snapshot, source: "cache")
        }
        paths.start { [weak self] in
            Task { @MainActor in await self?.kick(.reconnect) }
        }
        await kick(.launch)
        if !isActive { await onLegacy?() }
    }

    func kick(_ trigger: SyncTrigger) async {
        guard isActive else { return }
        await connect()
        await engine.syncNow()
        _ = trigger
    }

    /// The ChangeFeed socket will call this. The nudge carries no rows; the pull does.
    func nudge() async { await kick(.nudge) }

    func syncNow() async { await kick(.foreground) }

    func invalidate() async {
        isActive = true
        confirmations.removeAll()
        undos.removeAll()
        await engine.invalidate()
        deliver(SyncLibrarySnapshot(visible: [], hidden: [], caughtUp: false), source: "reset")
    }

    // MARK: - Edits

    func enqueueTitle(before: LibraryPost, after: LibraryPost, anchor: String, title: String?, undo: @escaping @MainActor () -> Void) async throws {
        let op = make(.title, post: before, anchor: anchor, title: title, status: nil, makePublic: nil, fileID: nil)
        let stored = try await store.commit(post: after, op: op)
        undos[stored.opID] = undo
        await kick(.outbox)
    }

    func enqueueDelete(post: LibraryPost, anchor: String, onAck: @escaping @MainActor () async -> Void) async throws {
        let op = make(.delete, post: post, anchor: anchor, title: nil, status: nil, makePublic: nil, fileID: nil)
        let stored = try await store.commit(post: nil, op: op)
        confirmations[stored.opID] = onAck
        await kick(.outbox)
    }

    func enqueueHide(before: LibraryPost, after: LibraryPost?, status: PostStatus) async throws {
        let op = make(.hide, post: before, anchor: before.files.first?.id ?? before.id, title: nil, status: status.rawValue, makePublic: nil, fileID: nil)
        _ = try await store.commit(post: after, op: op)
        await kick(.outbox)
    }

    func enqueueVisibility(before: LibraryPost, after: LibraryPost, fileID: String, makePublic: Bool) async throws {
        let op = make(.visibility, post: before, anchor: fileID, title: nil, status: nil, makePublic: makePublic, fileID: fileID)
        _ = try await store.commit(post: after, op: op)
        await kick(.outbox)
    }

    func enqueueStatus(before: LibraryPost, after: LibraryPost?, status: PostStatus) async throws {
        if status == .hidden || status == .off {
            try await enqueueHide(before: before, after: after, status: status)
        } else {
            let op = make(.visibility, post: before, anchor: before.files.first?.id ?? before.id, title: nil, status: status.rawValue, makePublic: nil, fileID: nil)
            _ = try await store.commit(post: after, op: op)
            await kick(.outbox)
        }
    }

    // MARK: -

    private func make(_ kind: SyncOp.Kind, post: LibraryPost, anchor: String, title: String?, status: String?, makePublic: Bool?, fileID: String?) -> SyncOp {
        SyncOp(
            opID: UUID().uuidString, kind: kind, target: post.id,
            payload: SyncOp.Payload(anchor: anchor, title: title, status: status, makePublic: makePublic, fileID: fileID, before: SyncPostCoding.encode(post)),
            createdAt: Date(), tries: 0, nextAttemptAt: Date(timeIntervalSince1970: 0))
    }

    private func connect() async {
        guard !connected else { return }
        connected = true
        await engine.setCallbacks(
            snapshot: { [weak self] snapshot in
                await self?.apply(snapshot, source: "sync")
            },
            fallback: { [weak self] in
                await self?.markFellBack()
            },
            acknowledged: { [weak self] id in
                await self?.acknowledge(id)
            },
            refused: { [weak self] op in
                await self?.refuse(op)
            })
    }

    private func apply(_ snapshot: SyncLibrarySnapshot, source: String) {
        onApply?(snapshot, source)
    }

    private func markFellBack() { isActive = false }

    private func acknowledge(_ id: String) async {
        undos[id] = nil
        if let body = confirmations.removeValue(forKey: id) { await body() }
    }

    private func refuse(_ op: SyncOp) {
        confirmations[op.opID] = nil
        undos.removeValue(forKey: op.opID)?()
    }

    private func deliver(_ snapshot: SyncLibrarySnapshot, source: String) {
        onApply?(snapshot, source)
    }
}

/// `GET /sync` and the four write routes, with `Idempotency-Key` set to the op id.
final class HTTPSyncClient: SyncTransport, SyncSender, @unchecked Sendable {
    private let client: @MainActor () -> HTTPCobaltClient?

    init(client: @escaping @MainActor () -> HTTPCobaltClient?) {
        self.client = client
    }

    func pull(since: Int64, limit: Int) async throws -> SyncPage {
        guard let http = await currentClient() else { throw SyncError.notDeployed }
        return try await http.syncChanges(since: since, limit: limit)
    }

    func send(_ op: SyncOp) async throws {
        guard let http = await currentClient() else { throw SyncError.retryable("no client") }
        do {
            switch op.kind {
            case .title:
                _ = try await http.writeTitle(anchor: op.payload.anchor, op.payload.title, idempotencyKey: op.opID)
            case .delete:
                _ = try await http.writeDelete(anchor: op.payload.anchor, idempotencyKey: op.opID)
            case .hide:
                let status = PostStatus(rawValue: op.payload.status ?? PostStatus.hidden.rawValue) ?? .hidden
                _ = try await http.writeStatus(ids: [op.target], status: status, idempotencyKey: op.opID)
            case .visibility:
                if let makePublic = op.payload.makePublic {
                    _ = try await http.writeVisibility(item: op.payload.fileID ?? op.payload.anchor, public: makePublic, idempotencyKey: op.opID)
                } else if let status = op.payload.status.flatMap(PostStatus.init(rawValue:)) {
                    _ = try await http.writeStatus(ids: [op.target], status: status, idempotencyKey: op.opID)
                }
            }
        } catch {
            switch MutationRetry.attempt(error, kind: op.kind) {
            case .succeeded: return
            case .refused: throw SyncError.refused(String(describing: error))
            case .retry: throw SyncError.retryable(String(describing: error))
            }
        }
    }

    private func currentClient() async -> HTTPCobaltClient? {
        let client = self.client
        return await MainActor.run { client() }
    }
}

/// `Mutex` is not copyable, so the path callback cannot capture one by value. It keeps this reference.
private final class PathDown: Sendable {
    let flag = Mutex(false)
}

/// Fires when the path becomes usable again. The first satisfied path is launch, which already pulls.
final class SyncPathWatch: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cobalt.sync.path")
    private let wasDown = PathDown()
    private var started = false

    func start(_ onReconnect: @escaping @Sendable () -> Void) {
        guard !started else { return }
        started = true
        let down = wasDown
        monitor.pathUpdateHandler = { path in
            if path.status != .satisfied {
                down.flag.withLock { $0 = true }
                return
            }
            let again = down.flag.withLock { wasDown -> Bool in
                if !wasDown { return false }
                wasDown = false
                return true
            }
            if again { onReconnect() }
        }
        monitor.start(queue: queue)
    }
}
