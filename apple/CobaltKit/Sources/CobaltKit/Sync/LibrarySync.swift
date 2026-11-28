import Foundation
import Network
import Synchronization

/// Notes from a pass. The engine appends and returns; it does not wait on the main actor. `Mutex`
/// stays inside this class, so the callback captures a reference.
private final class SyncInbox: @unchecked Sendable {
    enum Item: Sendable {
        case snapshot(SyncLibrarySnapshot, String)
        case fallback
        case degraded
        case acknowledged(SyncOp, SyncReceipt)
        case refused(SyncOp, String)
        case pullFailed(any Error)
        case activity(SyncActivity)
    }

    private let items = Mutex<[Item]>([])
    private let ping = Mutex<(@Sendable () -> Void)?>(nil)

    /// A retry the engine starts itself has no `kick` to drain this. The ping schedules that drain.
    func arm(_ body: @escaping @Sendable () -> Void) {
        ping.withLock { $0 = body }
    }

    func add(_ item: Item) {
        items.withLock { $0.append(item) }
        ping.withLock { $0?() }
    }

    func drain() -> [Item] {
        items.withLock { let copy = $0; $0.removeAll(); return copy }
    }
}

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
    private var confirmations: [String: @MainActor ([String]) async -> Void] = [:]
    private var undos: [String: @MainActor () -> Void] = [:]
    /// Ops whose caller is waiting inside `kick` to hear how the server answered, and what it heard.
    private var awaited: Set<String> = []
    private var answers: [String: Answer] = [:]
    private var connected = false
    /// The route fell back and today's loading has not been started for it yet.
    private var owesLegacyLoad = false
    /// The server's code for the last refusal or failed pull in the inbox, handed to the status when
    /// the activity that follows it is read (the engine appends the failure, then the signal).
    private var failureCode: String?
    /// Engine callbacks append here and return. They do not hop to the main actor: a pass that
    /// waited on the main actor (the caller of `kick`) stalled for seconds, and a nudge set just
    /// before that wait was already "over" by the time the pass began.
    private let inbox = SyncInbox()
    /// The drain of the inbox that is running now, if any.
    private var flushing: Task<Void, Never>?
    /// False after `GET /sync` answers 404/501 (`SyncError.notDeployed`), or after `stop()`. Today's
    /// library loading takes over for this launch. A 5xx or a network error never turns it off.
    private(set) var isActive = true
    /// The pull failed (a 5xx, the network) with no copy on the device, so the library is showing
    /// today's `GET /library` pages for now. The engine is still on and retrying (5 s, 15 s, 45 s, then
    /// 120 s); the first pull that lands ends this. Edits still go through the outbox.
    private(set) var isPagedFallback = false
    /// The engine fills the library screens: it is on, and the screens are not on the paged fallback.
    var servesLibrary: Bool { isActive && !isPagedFallback }
    /// `stop()` ran: nothing the engine still has in flight reaches the library.
    private var stopped = false
    /// What the library sync is doing. Updated as passes start and end; it does not decide them.
    let status = SyncStatusTracker()
    var onApply: (@MainActor (SyncLibrarySnapshot, String) -> Void)?
    /// Today's first `GET /library` page is wanted: the route is missing and the cache, if any, must
    /// not be the only copy the screen keeps, or the pull failed with nothing on the device to show
    /// (`isPagedFallback`). Called once for each, whichever pass it happened in.
    var onLegacy: (@MainActor () async -> Void)?
    /// A pass ended without a pull while the engine stays on: the library says why it is not fresh.
    var onPullFailure: (@MainActor (any Error) -> Void)?
    /// A delete queued by an earlier launch was taken by the server. The closure that removes the
    /// device's files died with that launch, so the post it deleted is handed over instead.
    var onDeleteConfirmed: (@MainActor (LibraryPost) async -> Void)?

    /// How the server answered an op while its caller was still waiting.
    private enum Answer {
        case refused(String)
        case partial([String])
    }

    init(
        store: SyncStore, transport: any SyncTransport, sender: any SyncSender,
        retryDelays: [TimeInterval] = SyncEngine.defaultRetryDelays
    ) {
        self.store = store
        self.engine = SyncEngine(store: store, transport: transport, sender: sender, retryDelays: retryDelays)
        inbox.arm { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flushInbox()
                await self?.loadLegacyIfOwed()
            }
        }
    }

    /// The real client. `client` is read on each request, so a server change is picked up. Cheap: the database is opened
    /// by `start()`, on the store's actor, not here (this runs at launch, before the first frame).
    convenience init(databaseURL: URL, client: @escaping @MainActor () -> HTTPCobaltClient?) throws {
        let store = try SyncStore(fileURL: databaseURL)
        let http = HTTPSyncClient(client: client)
        self.init(store: store, transport: http, sender: http)
    }

    /// The edits waiting in the outbox, oldest first (the System Health Inspector's list). Read-only: it never sends or changes
    /// anything. Empty when the store cannot be read.
    func pendingEdits() async -> [PendingSyncEdit] {
        ((try? await store.pendingOps()) ?? []).sorted { $0.createdAt < $1.createdAt }.map(PendingSyncEdit.init)
    }

    /// Switches the engine off for good: a pass in flight drops its page, no timer or path change starts
    /// another, and nothing it still holds reaches the library. The edits waiting in the outbox get one last
    /// try first, so an owner who turns sync off does not strand them. The copy and the outbox stay on disk.
    func stop() async {
        guard !stopped else { return }
        if isActive, ((try? await store.pendingOps().isEmpty) ?? true) == false { await kick(.outbox) }
        stopped = true
        isActive = false
        isPagedFallback = false
        owesLegacyLoad = false
        paths.stop()
        await engine.shutdown()
        confirmations.removeAll()
        undos.removeAll()
        _ = inbox.drain()
    }

    /// The owner dismissed the error in the status. The engine's own retry carries on.
    func dismissError() {
        status.dismissed()
    }

    /// Launch. A copy from last time is shown before the pull, and the pull is the launch trigger.
    func start() async {
        // A database that cannot be opened is a server with no `/sync` for this launch: today's library loading takes over
        // (it used to fail the initializer, which left the library on today's loading the same way).
        do {
            try await store.open()
        } catch {
            Telemetry.log(.error, .sync, "sync store failed", data: ["error": .string(String(describing: error))])
            markFellBack()
            await loadLegacyIfOwed()
            return
        }
        await connect()
        if await store.hasReadyMarker(), let snapshot = try? await store.snapshot(), !snapshot.visible.isEmpty || !snapshot.hidden.isEmpty {
            deliver(snapshot, source: "cache")
        }
        paths.start({ [weak self] in
            Task { @MainActor in await self?.kick(.reconnect) }
        }, onReachable: { [weak self] up in
            Task { @MainActor in await self?.noteReachable(up) }
        })
        await kick(.launch)
    }

    func kick(_ trigger: SyncTrigger) async {
        guard isActive, !stopped else { return }
        await connect()
        await engine.syncNow()
        await flushInbox()
        await loadLegacyIfOwed()
        _ = trigger
    }

    /// After a fallback the screen must not be left with the cache, or with nothing: today's first
    /// page is loaded, once, whoever asked for the pass that fell back.
    private func loadLegacyIfOwed() async {
        guard owesLegacyLoad else { return }
        owesLegacyLoad = false
        await onLegacy?()
    }

    /// The ChangeFeed socket will call this. The nudge carries no rows; the pull does.
    func nudge() async {
        await kick(.nudge)
    }

    func syncNow() async { await kick(.foreground) }

    func invalidate() async {
        isActive = true
        isPagedFallback = false
        owesLegacyLoad = false
        confirmations.removeAll()
        undos.removeAll()
        awaited.removeAll()
        answers.removeAll()
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

    /// `onAck` runs once the server has taken the delete, with the file ids it could not remove
    /// (empty: the whole post is gone). Returns those ids when the server answered during this call;
    /// empty when everything went, or when the delete is still waiting to be sent.
    @discardableResult
    func enqueueDelete(post: LibraryPost, anchor: String, onAck: @escaping @MainActor ([String]) async -> Void) async throws -> [String] {
        let op = make(.delete, post: post, anchor: anchor, title: nil, status: nil, makePublic: nil, fileID: nil)
        let stored = try await store.commit(post: nil, op: op)
        confirmations[stored.opID] = onAck
        if case .partial(let remaining)? = await send(awaiting: stored.opID) { return remaining }
        return []
    }

    /// Throws `SyncError.refused(code)` when the server answered during this call and would not take
    /// the status for this post: the row is already back as it was.
    func enqueueHide(before: LibraryPost, after: LibraryPost?, status: PostStatus) async throws {
        let op = make(.hide, post: before, anchor: before.files.first?.id ?? before.id, title: nil, status: status.rawValue, makePublic: nil, fileID: nil)
        let stored = try await store.commit(post: after, op: op)
        if case .refused(let code)? = await send(awaiting: stored.opID) { throw SyncError.refused(code) }
    }

    func enqueueVisibility(before: LibraryPost, after: LibraryPost, fileID: String, makePublic: Bool) async throws {
        let op = make(.visibility, post: before, anchor: fileID, title: nil, status: nil, makePublic: makePublic, fileID: fileID)
        _ = try await store.commit(post: after, op: op)
        await kick(.outbox)
    }

    /// Throws like `enqueueHide`.
    func enqueueStatus(before: LibraryPost, after: LibraryPost?, status: PostStatus) async throws {
        if status == .hidden || status == .off {
            try await enqueueHide(before: before, after: after, status: status)
        } else {
            let op = make(.visibility, post: before, anchor: before.files.first?.id ?? before.id, title: nil, status: status.rawValue, makePublic: nil, fileID: nil)
            let stored = try await store.commit(post: after, op: op)
            if case .refused(let code)? = await send(awaiting: stored.opID) { throw SyncError.refused(code) }
        }
    }

    /// Runs a pass and returns what the server said about this op in it, if it said anything the
    /// caller has to know (a refusal, a delete that left files). Nil: taken as asked, or still queued.
    private func send(awaiting id: String) async -> Answer? {
        awaited.insert(id)
        await kick(.outbox)
        awaited.remove(id)
        return answers.removeValue(forKey: id)
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
        let inbox = inbox
        await engine.setCallbacks(
            snapshot: { [inbox] snapshot in
                inbox.add(.snapshot(snapshot, "sync"))
            },
            fallback: { [inbox] in
                inbox.add(.fallback)
            },
            acknowledged: { [inbox] op, receipt in
                inbox.add(.acknowledged(op, receipt))
            },
            refused: { [inbox] op, reason in
                inbox.add(.refused(op, reason))
            },
            pullFailed: { [inbox] error in
                inbox.add(.pullFailed(error))
            },
            degraded: { [inbox] in
                inbox.add(.degraded)
            })
        await engine.setActivity { [inbox] signal in
            inbox.add(.activity(signal))
        }
    }

    /// Applies what the pass recorded. `kick` calls this before it returns, so the screen and the
    /// status match the pass with no extra hop. A retry the engine starts on its own has no `kick`,
    /// so the callback also asks for a flush; draining twice is empty the second time.
    ///
    /// One drain at a time: applying an item can wait (the cursor is read from the store), so a second
    /// caller that drained meanwhile would find the inbox empty and return before the first had
    /// written the status. It waits for the drain in flight, then drains what is left.
    private func flushInbox() async {
        while let running = flushing { await running.value }
        let drain = Task { @MainActor [weak self] in
            await self?.drainInbox()
            self?.flushing = nil
        }
        flushing = drain
        await drain.value
    }

    private func drainInbox() async {
        for item in inbox.drain() {
            switch item {
            case .snapshot(let snapshot, let source):
                apply(snapshot, source: source)
            case .fallback:
                markFellBack()
            case .degraded:
                markPagedFallback()
            case .acknowledged(let op, let receipt):
                await acknowledge(op, receipt)
            case .refused(let op, let reason):
                failureCode = reason
                refuse(op, reason: reason)
            case .pullFailed(let error):
                failureCode = SyncStatusReducer.code(of: error)
                onPullFailure?(error)
            case .activity(let signal):
                await receive(signal)
            }
        }
    }

    private func receive(_ signal: SyncActivity) async {
        switch signal {
        case .passBegan:
            status.passBegan()
        case .passEnded(let pending):
            status.passEnded(pending: pending, cursor: await store.cursor())
        case .refused(let pending):
            status.refused(pending: pending, code: takeFailureCode())
        case .repull:
            status.repullBegan()
        case .fellBack:
            status.routeFellBack()
        case .pulled:
            isPagedFallback = false
            status.pulled(cursor: await store.cursor())
        case .retryScheduled(let at):
            status.retryScheduled(at: at)
        case .pullFailed(let offline):
            // Nothing reached the server: offline. The server answered and would not serve the pull: an error.
            status.pullFailed(offline: offline, code: takeFailureCode(), pending: status.pendingCount)
        }
    }

    private func takeFailureCode() -> String? {
        defer { failureCode = nil }
        return failureCode
    }

    private func noteReachable(_ up: Bool) async {
        let pending = (try? await store.pendingOps().count) ?? status.pendingCount
        status.reachability(up, pending: pending)
    }

    private func apply(_ snapshot: SyncLibrarySnapshot, source: String) {
        guard !stopped else { return }
        // An empty copy that is not whole says nothing: the engine publishes one before the first pull, and
        // after a reset, and it must not blank the pages on screen. On the paged fallback the screen holds
        // today's pages, so the first page of a pull that then failed must not replace them either: only
        // a whole pull does.
        if !snapshot.caughtUp, isPagedFallback || (snapshot.visible.isEmpty && snapshot.hidden.isEmpty) { return }
        onApply?(snapshot, source)
    }

    private func markFellBack() {
        guard isActive else { return }
        isActive = false
        isPagedFallback = false
        owesLegacyLoad = true
    }

    /// A pull failed with nothing on the device: today's first page is shown (once per failure) and the
    /// engine, still on, keeps trying.
    private func markPagedFallback() {
        guard isActive, !stopped else { return }
        isPagedFallback = true
        owesLegacyLoad = true
    }

    private func acknowledge(_ op: SyncOp, _ receipt: SyncReceipt) async {
        undos[op.opID] = nil
        if awaited.contains(op.opID), !receipt.remaining.isEmpty { answers[op.opID] = .partial(receipt.remaining) }
        if let body = confirmations.removeValue(forKey: op.opID) {
            await body(receipt.remaining)
        } else if op.kind == .delete, receipt.remaining.isEmpty, let post = op.payload.before.flatMap(SyncPostCoding.decode) {
            await onDeleteConfirmed?(post)
        }
    }

    private func refuse(_ op: SyncOp, reason: String) {
        if awaited.contains(op.opID) { answers[op.opID] = .refused(reason) }
        confirmations[op.opID] = nil
        undos.removeValue(forKey: op.opID)?()
    }

    private func deliver(_ snapshot: SyncLibrarySnapshot, source: String) {
        guard !stopped else { return }
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

    func send(_ op: SyncOp) async throws -> SyncReceipt {
        guard let http = await currentClient() else { throw SyncError.retryable("no client") }
        let key = op.idempotencyKey
        do {
            switch op.kind {
            case .title:
                _ = try await http.writeTitle(anchor: op.payload.anchor, op.payload.title, idempotencyKey: key)
                return .done
            case .delete:
                let result = try await http.writeDelete(anchor: op.payload.anchor, idempotencyKey: key)
                return SyncReply.delete(result, op: op)
            case .hide:
                let status = PostStatus(rawValue: op.payload.status ?? PostStatus.hidden.rawValue) ?? .hidden
                let change = try await http.writeStatus(ids: [op.target], status: status, idempotencyKey: key)
                return try SyncReply.status(change, op: op)
            case .visibility:
                if let makePublic = op.payload.makePublic {
                    _ = try await http.writeVisibility(item: op.payload.fileID ?? op.payload.anchor, public: makePublic, idempotencyKey: key)
                } else if let status = op.payload.status.flatMap(PostStatus.init(rawValue:)) {
                    let change = try await http.writeStatus(ids: [op.target], status: status, idempotencyKey: key)
                    return try SyncReply.status(change, op: op)
                }
                return .done
            }
        } catch {
            switch MutationRetry.attempt(error, kind: op.kind) {
            case .succeeded: return .done
            case .refused: throw SyncError.refused(SyncReply.reason(error))
            case .retry: throw SyncError.retryable(String(describing: error))
            case .rekey: throw SyncError.keyConflict
            }
        }
    }

    private func currentClient() async -> HTTPCobaltClient? {
        let client = self.client
        return await MainActor.run { client() }
    }
}

/// Reads the answers of the write routes that say more than their status code does.
enum SyncReply {
    /// `POST /library/status` answers 200 even when it did nothing for the post, and lists why under
    /// `failed`. No entry for the post under `posts`: the server would not take it, which is a
    /// refusal like any other. An entry, with failures beside it: the status was taken and some
    /// files were not switched, so the server's account of the files replaces the device's guess.
    static func status(_ change: StatusChange, op: SyncOp) throws -> SyncReceipt {
        guard let answer = change.posts.first(where: { $0.id == op.target || $0.postKey == op.target }) else {
            let named = change.failed.first(where: { $0.id == op.target }) ?? change.failed.first
            throw SyncError.refused(named?.error ?? "error.api.generic")
        }
        guard !change.failed.isEmpty, let before = op.payload.before.flatMap(SyncPostCoding.decode) else { return .done }
        let failed = Set(change.failed.map(\.id))
        return SyncReceipt(post: SyncMerge.settle(before, answer: answer, failedFiles: failed))
    }

    /// `502 error.library.partial`: some files are still on the server. The post stays, with those.
    static func delete(_ result: PostDeleteResult, op: SyncOp) -> SyncReceipt {
        guard !result.remaining.isEmpty else { return .done }
        let remaining = Set(result.remaining)
        var post = op.payload.before.flatMap(SyncPostCoding.decode)
        post?.files.removeAll { !remaining.contains($0.id) }
        if post?.files.isEmpty == true { post = nil }
        return SyncReceipt(post: post, remaining: result.remaining)
    }

    /// The server's error code where there is one, so a refusal can be worded like any other failure.
    static func reason(_ error: any Error) -> String {
        if let e = error as? SyncError, case .refused(let why) = e { return why }
        if let e = error as? CobaltError, case .api(let code, _) = e { return code }
        if let failure = error as? PipelineFailure, case .server(let code) = failure { return code }
        return String(describing: error)
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

    func start(_ onReconnect: @escaping @Sendable () -> Void, onReachable: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard !started else { return }
        started = true
        let down = wasDown
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            let net: EnergyNetwork
            if !up {
                net = .none
            } else if path.usesInterfaceType(.wifi) {
                net = .wifi
            } else if path.usesInterfaceType(.cellular) {
                net = .cell
            } else {
                net = .other
            }
            EnergySampler.shared.setNetwork(net)
            onReachable(up)
            if !up {
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

    func stop() {
        guard started else { return }
        monitor.cancel()
    }
}
