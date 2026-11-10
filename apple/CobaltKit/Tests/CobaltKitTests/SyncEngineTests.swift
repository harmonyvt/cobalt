import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The on-device sync engine: the local library, the cursor (including a 410 and `more`), and the
// outbox (one idempotency key, a retry, a refusal that puts the edit back, a pending edit that wins
// over an older pull). `GET /sync` is the contract in `SyncContract.swift`. The flag defaults off,
// so these tests build the engine directly.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("sync store")
struct SyncStoreTests {
    @Test func roundTripsPostsAndAnswersFilterSortAndNameSearchLocally() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.upsert(sample("a", title: "zebra", custom: "Alpha clip", at: t0))
        try await store.upsert(sample("b", title: "capybara spa day", at: t0.addingTimeInterval(10), visibility: .public))
        try await store.upsert(sample("c", title: "hidden one", at: t0.addingTimeInterval(20), hidden: true))

        let visible = try await store.posts(hidden: false)
        #expect(visible.map(\.id) == ["b", "a"])
        let named = try await store.posts(hidden: false, name: "spa")
        #expect(named.map(\.id) == ["b"])
        let alpha = try await store.posts(hidden: false, name: "alpha")
        #expect(alpha.map(\.id) == ["a"])
        let byTitle = try await store.posts(hidden: false, sort: SyncLibrarySort(key: "title", ascending: true))
        #expect(byTitle.map(\.id) == ["a", "b"])
        let onlyPublic = try await store.posts(hidden: false, visibility: "public")
        #expect(onlyPublic.map(\.id) == ["b"])
        let hidden = try await store.posts(hidden: true)
        #expect(hidden.map(\.id) == ["c"])
        let percent = try await store.posts(hidden: false, name: "%")
        #expect(percent.isEmpty)
    }

    @Test func cursorPagesGoneAndOtherEntities() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let link = SyncEntity(id: "l1", json: Data(#"{"id":"l1","href":"https://example.com"}"#.utf8))
        let first = SyncPage(
            seq: 41, more: true, posts: [sample("p1", title: "one")],
            links: [link], collections: [], sets: [], names: [], rules: [], gone: [])
        try await store.apply(first)
        #expect(await store.cursor() == 41)
        #expect(await store.hasReadyMarker())
        #expect(try await store.snapshot().caughtUp == false)
        #expect(try await store.entity(table: "links", id: "l1") != nil)

        let second = SyncPage(
            seq: 44, more: false, posts: [sample("p2", title: "two")],
            links: [], collections: [], sets: [], names: [], rules: [],
            gone: [SyncGone(entity: "post", id: "p1"), SyncGone(entity: "link", id: "l1")])
        try await store.apply(second)
        let snap = try await store.snapshot()
        #expect(await store.cursor() == 44)
        #expect(snap.caughtUp)
        #expect(snap.visible.map(\.id) == ["p2"])
        #expect(try await store.entity(table: "links", id: "l1") == nil)
    }

    @Test func resetDropsTheCopyAndKeepsTheOutbox() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = sample("p", title: "keep")
        try await store.apply(SyncPage(seq: 9, more: false, posts: [post], links: [], collections: [], sets: [], names: [], rules: [], gone: []))
        _ = try await store.commit(post: nil, op: op(.delete, post: post, title: nil))
        try await store.resetCursor()
        #expect(await store.cursor() == 0)
        #expect(try await store.snapshot().visible.isEmpty)
        #expect(try await store.pendingOps().map(\.kind) == [.delete])
    }

    @Test func pendingTitleWinsOverAnOlderPullAndAGoneMarker() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p2", title: "old name", custom: "old name")
        var edited = original
        edited.customTitle = "capybara spa day"
        _ = try await store.commit(post: edited, op: op(.title, post: original, title: "capybara spa day"))

        var older = original
        older.customTitle = "server still says old"
        older.title = "server still says old"
        try await store.apply(SyncPage(
            seq: 44, more: false, posts: [older], links: [], collections: [], sets: [], names: [], rules: [],
            gone: [SyncGone(entity: "post", id: "p2")]))
        let kept = try await store.post(id: "p2")
        #expect(kept?.customTitle == "capybara spa day")
    }

    @Test func pendingDeleteStaysGoneWhenThePullStillListsThePost() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = sample("p3", title: "going")
        try await store.upsert(post)
        _ = try await store.commit(post: nil, op: op(.delete, post: post, title: nil))
        try await store.apply(SyncPage(
            seq: 3, more: false, posts: [post], links: [], collections: [], sets: [], names: [], rules: [], gone: []))
        #expect(try await store.post(id: "p3") == nil)
    }

    @Test func aSecondUnsentTitleKeepsTheOpIdAndTheOriginalBefore() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        var first = original
        first.customTitle = "one"
        let stored = try await store.commit(post: first, op: op(.title, post: original, title: "one"))
        var second = first
        second.customTitle = "two"
        let again = try await store.commit(post: second, op: op(.title, post: first, title: "two"))
        #expect(again.opID == stored.opID)
        #expect(try await store.pendingOps().count == 1)
        #expect(try await store.post(id: "p")?.customTitle == "two")
        let before = try #require(again.payload.before)
        #expect(SyncPostCoding.decode(before)?.customTitle == "old")
    }
}

@Suite("sync cursor and outbox")
struct SyncEngineTests {
    @Test func pagesWhileMoreIsSetAndStopsOnTheLastSeq() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let transport = ScriptedSync { since in
            if since == 0 {
                return SyncPage(seq: 2, more: true, posts: [sample("a", title: "a")], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
            }
            #expect(since == 2)
            return SyncPage(seq: 4, more: false, posts: [sample("b", title: "b")], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
        }
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.syncNow()
        #expect(transport.calls == [0, 2])
        let snap = try await store.snapshot()
        #expect(snap.visible.map(\.id).sorted() == ["a", "b"])
        #expect(await store.cursor() == 4)
        #expect(snap.caughtUp)
    }

    @Test func aStaleCursorRestartsFromZeroAndKeepsTheOutbox() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = sample("old", title: "old")
        try await store.apply(SyncPage(seq: 50, more: false, posts: [post], links: [], collections: [], sets: [], names: [], rules: [], gone: []))
        var pendingTitle = op(.title, post: post, title: "pending")
        pendingTitle.createdAt = Date()
        _ = try await store.commit(post: renamed(post, "pending"), op: pendingTitle)
        let freshPage = SyncPage(seq: 1, more: false, posts: [sample("fresh", title: "fresh")], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
        let transport = ScriptedSync { since in
            if since != 0 { throw SyncError.cursorTooOld }
            return freshPage
        }
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: [.failure(SyncError.retryable("offline"))]))
        await engine.syncNow()
        #expect(transport.calls == [50, 0])
        #expect(try await store.post(id: "old") == nil)
        let fresh = try await store.post(id: "fresh")
        #expect(fresh?.title == "fresh")
        let pending = try await store.pendingOps()
        #expect(pending.count == 1)
        // the pending title's target is "old"; the restart must not have dropped it
        #expect(pending.first?.target == "old")
        #expect(await store.cursor() == 1)
    }

    @Test func aMissingRouteFallsBackAndDoesNotWipeTheCopy() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.upsert(sample("kept", title: "kept"))
        let transport = ScriptedSync { _ in throw SyncError.notDeployed }
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.syncNow()
        #expect(await engine.fellBack)
        #expect(try await store.post(id: "kept")?.title == "kept")
    }

    @Test func retryReusesTheOpIdAndOnlyARefusalRollsBack() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        let edited = renamed(original, "new")
        let stored = try await store.commit(post: edited, op: op(.title, post: original, title: "new"))
        let sender = ScriptedSender(results: [.failure(SyncError.retryable("offline"))])
        let now = t0
        let waiting = await OutboxDrainer.drain(store: store, sender: sender, now: now)
        #expect(sender.keys == [stored.opID])
        #expect(try await store.post(id: "p")?.customTitle == "new")
        #expect(waiting.wake == now.addingTimeInterval(MutationRetry.backoff(tries: 1)))
        let early = await OutboxDrainer.drain(store: store, sender: sender, now: now)
        #expect(sender.keys == [stored.opID])
        #expect(early.acknowledged.isEmpty)

        sender.results = [.success(())]
        let done = await OutboxDrainer.drain(store: store, sender: sender, now: now.addingTimeInterval(MutationRetry.backoff(tries: 1)))
        #expect(sender.keys == [stored.opID, stored.opID])
        #expect(done.acknowledged == [stored.opID])
        #expect(try await store.pendingOps().isEmpty)

        let again = try await store.commit(post: renamed(original, "nope"), op: op(.title, post: original, title: "nope"))
        sender.results = [.failure(SyncError.refused("error.library.bad_title"))]
        let refused = await OutboxDrainer.drain(store: store, sender: sender, now: now)
        #expect(refused.refused.map(\.opID) == [again.opID])
        #expect(try await store.post(id: "p")?.customTitle == "old")
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func backoffGrowsAndThenCaps() {
        #expect(MutationRetry.backoff(tries: 1) == 1)
        #expect(MutationRetry.backoff(tries: 2) == 2)
        #expect(MutationRetry.backoff(tries: 3) == 4)
        #expect(MutationRetry.backoff(tries: 10) == 300)
        #expect(MutationRetry.isFinal(CobaltError.api(code: "error.library.bad_title", httpStatus: 400)))
        #expect(!MutationRetry.isFinal(CobaltError.network(.notConnectedToInternet)))
        #expect(MutationRetry.attempt(PipelineFailure.expired, kind: .delete) == .succeeded)
        #expect(MutationRetry.attempt(PipelineFailure.server(code: "error.library.bad_title"), kind: .title) == .refused)
        #expect(MutationRetry.attempt(CobaltError.api(code: "error.library.busy", httpStatus: 409), kind: .delete) == .retry)
    }

    @Test func decodesTheSyncContractIncludingASkippedPostAndA410() throws {
        let json = """
        {"seq":44,"more":true,"posts":[
          {"id":"p2","title":"capybara spa day","visibility":"public","hidden":false,"created_at":1700000000000,"files":[]},
          {"id":"broken","title":"no date","files":[]}
        ],"links":[{"id":"l1"}],"collections":[],"sets":[],"names":[],"rules":[],
        "gone":[{"entity":"post","id":"p3"}]}
        """
        let page = try SyncPage.decode(Data(json.utf8))
        #expect(page.seq == 44)
        #expect(page.more)
        #expect(page.posts.map(\.id) == ["p2"])
        #expect(page.posts[0].title == "capybara spa day")
        #expect(page.posts[0].visibility == .public)
        #expect(page.links.map(\.id) == ["l1"])
        #expect(page.gone == [SyncGone(entity: "post", id: "p3")])
        let bare = Data(#"{"error":"sync.cursor_too_old"}"#.utf8)
        let envelope = Data(#"{"error":{"code":"sync.cursor_too_old"}}"#.utf8)
        #expect(SyncPage.isCursorTooOld(status: 200, data: bare))
        #expect(SyncPage.isCursorTooOld(status: 410, data: Data("{}".utf8)))
        #expect(SyncPage.isCursorTooOld(status: 409, data: envelope))
    }

    @Test func aReportDoesNotChangeARefusalOrAStaleCursor() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        try await store.upsert(original)
        _ = try await store.commit(post: renamed(original, "new"), op: op(.title, post: original, title: "new"))
        let seen = Mutex<[SyncActivity]>([])
        let engine = SyncEngine(
            store: store,
            transport: ScriptedSync { _ in
                SyncPage(seq: 1, more: false, posts: [original], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
            },
            sender: ScriptedSender(results: [.failure(SyncError.refused("error.library.bad_title"))]))
        await engine.setActivity { event in seen.withLock { $0.append(event) } }
        await engine.syncNow()
        let events = seen.withLock { $0 }
        #expect(events.first == .passBegan)
        #expect(events.contains { if case .refused(let pending) = $0 { return pending == 0 } else { return false } })
        #expect(events.last == .passEnded(pending: 0))
        #expect(try await store.post(id: "p")?.customTitle == "old")
        #expect(try await store.pendingOps().isEmpty)

        let restart = try SyncStore(fileURL: try tempDB())
        let kept = sample("old", title: "old")
        try await restart.apply(SyncPage(seq: 50, more: false, posts: [kept], links: [], collections: [], sets: [], names: [], rules: [], gone: []))
        var pendingTitle = op(.title, post: kept, title: "pending")
        pendingTitle.createdAt = Date()
        _ = try await restart.commit(post: renamed(kept, "pending"), op: pendingTitle)
        let pulls = ScriptedSync { since in
            if since != 0 { throw SyncError.cursorTooOld }
            return SyncPage(seq: 1, more: false, posts: [sample("fresh", title: "fresh")], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
        }
        let again = Mutex<[SyncActivity]>([])
        let restartEngine = SyncEngine(store: restart, transport: pulls, sender: ScriptedSender(results: [.failure(SyncError.retryable("offline"))]))
        await restartEngine.setActivity { event in again.withLock { $0.append(event) } }
        await restartEngine.syncNow()
        #expect(pulls.calls == [50, 0])
        #expect(try await restart.post(id: "old") == nil)
        #expect(try await restart.pendingOps().count == 1)
        #expect(await restart.cursor() == 1)
        let reported = again.withLock { $0 }
        #expect(reported.contains(.repull))
        #expect(reported.last == .passEnded(pending: 1))
    }

    @Test func featureFlagDefaultsOff() {
        let defaults = UserDefaults(suiteName: "cobalt.sync.flag.\(UUID().uuidString)")!
        #expect(!SyncFeature.isEnabled(defaults))
        defaults.set(true, forKey: SyncFeature.defaultsKey)
        #expect(SyncFeature.isEnabled(defaults))
    }
}

@Suite("sync http contract")
struct SyncHTTPTests {
    @Test func pullsPagesAndSendsTheIdempotencyKeyOnce() async throws {
        let post = sample("p2", title: "capybara spa day", custom: "capybara spa day")
        let fixture = SyncFixture(posts: [post])
        let server = try await LoopbackServer.start { request in fixture.respond(request) }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { "test-key" })

        let first = try await client.syncChanges(since: 0, limit: 500)
        #expect(first.more)
        #expect(first.posts.map(\.id) == ["p2"])
        let second = try await client.syncChanges(since: first.seq, limit: 500)
        #expect(!second.more)
        #expect(second.seq == first.seq)

        let key = UUID().uuidString
        _ = try await client.writeTitle(anchor: post.files[0].id, "capybara spa day", idempotencyKey: key)
        _ = try await client.writeTitle(anchor: post.files[0].id, "capybara spa day", idempotencyKey: key)
        #expect(fixture.applied[key] == 1)
        let writes = server.requests.filter { $0.method == "PATCH" }
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0.headers["idempotency-key"] == key })

        fixture.setMode(.tooOld)
        do {
            _ = try await client.syncChanges(since: 1, limit: 500)
            Issue.record("a 410 should throw")
        } catch SyncError.cursorTooOld {
        } catch {
            Issue.record("unexpected \(error)")
        }
        fixture.setMode(.missing)
        do {
            _ = try await client.syncChanges(since: 0, limit: 500)
            Issue.record("a 404 should throw")
        } catch SyncError.notDeployed {
        } catch {
            Issue.record("unexpected \(error)")
        }
        let syncs = server.requests.filter { $0.path == "/sync" }
        #expect(syncs.contains { $0.target.contains("since=0") && $0.target.contains("limit=500") })
    }
}

@Suite("library glow wiring")
@MainActor
struct LibrarySyncGlowTests {
    @Test func aRefusalReachesTheGlowAndTheTitleStillComesBack() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        try await store.upsert(original)
        let sync = LibrarySync(
            store: store,
            transport: ScriptedSync { _ in
                SyncPage(seq: 3, more: false, posts: [original], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
            },
            sender: ScriptedSender(results: [.failure(SyncError.refused("error.library.bad_title"))]))
        try await sync.enqueueTitle(before: original, after: renamed(original, "nope"), anchor: "p-f", title: "nope", undo: {})
        #expect(sync.status.state == .refused)
        #expect(sync.status.lastEvent == .refused)
        #expect(try await store.post(id: "p")?.customTitle == "old")
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aNudgeMarksTheGlowAndStillPulls() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let pulls = ScriptedSync { _ in
            SyncPage(seq: 2, more: false, posts: [sample("a", title: "a")], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
        }
        let sync = LibrarySync(store: store, transport: pulls, sender: ScriptedSender(results: []))
        await sync.nudge()
        #expect(sync.status.lastEvent == .nudge)
        #expect(sync.status.state == .nudge)
        #expect(pulls.calls == [0])
        #expect(try await store.post(id: "a")?.title == "a")
    }

    @Test func aMissingRouteTurnsTheGlowOffAndKeepsTheCopy() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.upsert(sample("kept", title: "kept"))
        let sync = LibrarySync(
            store: store,
            transport: ScriptedSync { _ in throw SyncError.notDeployed },
            sender: ScriptedSender(results: []))
        await sync.kick(.launch)
        #expect(!sync.isActive)
        #expect(sync.status.state == .off)
        #expect(sync.status.lastEvent == .fellBack)
        #expect(try await store.post(id: "kept")?.title == "kept")
    }
}

// MARK: - fixtures

private func tempDB() throws -> URL {
    try makeTempDirectory().appendingPathComponent("library.sqlite")
}

private func sample(
    _ id: String, title: String, custom: String? = nil, at: Date = t0, hidden: Bool = false, visibility: Visibility? = nil
) -> LibraryPost {
    var file = LibraryFile(
        id: "\(id)-f", kind: .private, source: .upload, name: "\(id).mp4", url: nil,
        contentType: "video/mp4", bytes: 10, width: 100, height: 100, duration: 1, createdAt: at,
        mediaName: nil, deletable: true)
    file.wireVisibility = visibility
    return LibraryPost(
        id: id, service: nil, link: nil, title: title, duration: 1, width: 100, height: 100, createdAt: at,
        session: nil, files: [file], customTitle: custom ?? title, visibility: visibility, hidden: hidden)
}

private func renamed(_ post: LibraryPost, _ title: String) -> LibraryPost {
    var post = post
    post.customTitle = title
    return post
}

private func op(_ kind: SyncOp.Kind, post: LibraryPost, title: String?) -> SyncOp {
    SyncOp(
        opID: UUID().uuidString, kind: kind, target: post.id,
        payload: SyncOp.Payload(
            anchor: post.files.first?.id ?? post.id, title: title, status: nil, makePublic: nil, fileID: nil,
            before: SyncPostCoding.encode(post)),
        createdAt: t0, tries: 0, nextAttemptAt: Date(timeIntervalSince1970: 0))
}

private final class ScriptedSync: SyncTransport, @unchecked Sendable {
    private let handler: @Sendable (Int64) throws -> SyncPage
    private let seen = Mutex<[Int64]>([])
    var calls: [Int64] { seen.withLock { $0 } }

    init(_ handler: @escaping @Sendable (Int64) throws -> SyncPage) { self.handler = handler }

    func pull(since: Int64, limit: Int) async throws -> SyncPage {
        seen.withLock { $0.append(since) }
        #expect(limit == SyncContract.pageLimit)
        return try handler(since)
    }
}

private final class ScriptedSender: SyncSender, @unchecked Sendable {
    var results: [Result<Void, Error>]
    private let sent = Mutex<[String]>([])
    private let count = Mutex(0)
    var keys: [String] { sent.withLock { $0 } }

    init(results: [Result<Void, Error>]) { self.results = results }

    func send(_ op: SyncOp) async throws {
        let index = count.withLock { n -> Int in
            let current = n
            n += 1
            return current
        }
        sent.withLock { $0.append(op.opID) }
        if results.indices.contains(index) { try results[index].get() }
        else if let last = results.last { try last.get() }
    }
}

/// A stand-in for the server slice: one page of posts, then `more: false`, and write routes that
/// apply an `Idempotency-Key` only the first time.
private final class SyncFixture: @unchecked Sendable {
    private let state: Mutex<State>
    private struct State {
        var posts: [LibraryPost]
        var mode: Mode = .ok
        var applied: [String: Int] = [:]
    }
    enum Mode { case ok, missing, tooOld }

    init(posts: [LibraryPost]) { state = Mutex(State(posts: posts)) }

    var applied: [String: Int] { state.withLock { $0.applied } }
    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    func respond(_ request: LoopbackServer.Request) -> LoopbackServer.Response {
        if request.method == "GET", request.path == "/sync" {
            return state.withLock { state in
                switch state.mode {
                case .missing: return .json(#"{"error":{"code":"error.route.not_found"}}"#, status: 404)
                case .tooOld: return .json(#"{"error":"sync.cursor_too_old"}"#, status: 410)
                case .ok:
                    let since = query(request.target, "since").flatMap(Int64.init) ?? 0
                    let page = SyncPage(
                        seq: 44, more: since < 44, posts: since < 44 ? state.posts : [],
                        links: [], collections: [], sets: [], names: [], rules: [], gone: [])
                    guard let data = try? page.jsonData(), let text = String(data: data, encoding: .utf8) else {
                        return .json(#"{"error":"encode"}"#, status: 500)
                    }
                    return .json(text)
                }
            }
        }
        if request.method == "PATCH" {
            let key = request.headers["idempotency-key"] ?? ""
            state.withLock { state in
                if state.applied[key] == nil { state.applied[key] = 1 }
            }
            return .json(#"{"post":"p2","title":"capybara spa day"}"#)
        }
        return .json(#"{"error":{"code":"error.route.not_found"}}"#, status: 404)
    }

    private func query(_ target: String, _ name: String) -> String? {
        let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        for part in query.split(separator: "&") {
            let bits = part.split(separator: "=", maxSplits: 1)
            if bits.first == Substring(name) { return bits.dropFirst().first.map(String.init) }
        }
        return nil
    }
}
