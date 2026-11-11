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
        // The op is stamped `t0`. The engine's default clock is "now", which is years later, so the
        // outbox would drop the edit as expired and never refuse it.
        let engine = SyncEngine(
            store: store,
            transport: ScriptedSync { _ in
                SyncPage(seq: 1, more: false, posts: [original], links: [], collections: [], sets: [], names: [], rules: [], gone: [])
            },
            sender: ScriptedSender(results: [.failure(SyncError.refused("error.library.bad_title"))]),
            clock: { t0 })
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

    /// Only a 404 is "not there". The server answers 503 for any database read that failed, so it is
    /// thrown as the client's own error, like a 500: the engine decides (it falls back when the
    /// device has nothing to show, and stays on when it has a copy).
    @Test func a503AndA500AreTheServersErrorAndNotAMissingRoute() async throws {
        let fixture = SyncFixture(posts: [])
        let server = try await LoopbackServer.start { request in fixture.respond(request) }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { "test-key" })

        fixture.setMode(.notReady)
        do {
            _ = try await client.syncChanges(since: 0, limit: 500)
            Issue.record("a 503 should throw")
        } catch let error as CobaltError {
            #expect(error == .api(code: "error.api.generic", httpStatus: 503))
        } catch {
            Issue.record("unexpected \(error)")
        }
        fixture.setMode(.broken)
        do {
            _ = try await client.syncChanges(since: 0, limit: 500)
            Issue.record("a 500 should throw")
        } catch let error as CobaltError {
            #expect(error == .api(code: "error.api.generic", httpStatus: 500))
        } catch {
            Issue.record("unexpected \(error)")
        }
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
            transport: QuietPull { _ in
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
        let pulls = QuietPull { _ in
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
            transport: QuietPull { _ in throw SyncError.notDeployed },
            sender: ScriptedSender(results: []))
        await sync.kick(.launch)
        #expect(!sync.isActive)
        #expect(sync.status.state == .off)
        #expect(sync.status.lastEvent == .fellBack)
        #expect(try await store.post(id: "kept")?.title == "kept")
    }
}

@Suite("sync outbox: an op in flight is never rewritten")
struct SyncOutboxMergeTests {
    @Test func anEditMadeWhileTheFirstIsBeingSentGetsItsOwnOpAndIsSentAfterIt() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "clip")
        try await store.upsert(original)
        var hiddenPost = original
        hiddenPost.hidden = true
        let hidden = hiddenPost
        let first = try await store.commit(post: hidden, op: edit(.hide, post: original, status: .hidden))
        let second = edit(.hide, post: hidden, status: .off)
        let sender = HookSender { op in
            // the owner unhides while the hide is still on its way
            if op.opID == first.opID { _ = try await store.commit(post: original, op: second) }
            return .done
        }

        let done = await OutboxDrainer.drain(store: store, sender: sender, now: t0)
        #expect(done.acknowledged == [first.opID])
        #expect(sender.sent.map(\.payload.status) == ["hidden"])
        let left = try await store.pendingOps()
        #expect(left.map(\.opID) == [second.opID])
        #expect(left.first?.payload.status == "off")

        let next = await OutboxDrainer.drain(store: store, sender: sender, now: t0)
        #expect(next.acknowledged == [second.opID])
        #expect(sender.sent.map(\.payload.status) == ["hidden", "off"])
        #expect(sender.sent.map(\.idempotencyKey) == [first.opID, second.opID])
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func anEditMergedIntoAnOpThatWasNeverHandedOutIsWhatTheDrainSends() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let a = sample("a", title: "a", custom: "a")
        let b = sample("b", title: "b", custom: "b")
        let first = try await store.commit(post: renamed(a, "a2"), op: edit(.title, post: a, title: "a2"))
        let queued = try await store.commit(post: renamed(b, "one"), op: edit(.title, post: b, title: "one"))
        let again = edit(.title, post: renamed(b, "one"), title: "two")
        let sender = HookSender { op in
            // b is renamed again while a's title is on its way: b's op was only listed, never handed out
            if op.opID == first.opID { _ = try await store.commit(post: renamed(b, "two"), op: again) }
            return .done
        }

        let done = await OutboxDrainer.drain(store: store, sender: sender, now: t0)
        #expect(done.acknowledged == [first.opID, queued.opID])
        #expect(sender.sent.map(\.payload.title) == ["a2", "two"])
        #expect(try await store.pendingOps().isEmpty)
        #expect(try await store.post(id: "b")?.customTitle == "two")
    }

    @Test func aSendCutOffByTheAppEndingCountsAsATryAndIsNotMergedInto() async throws {
        let file = try tempDB()
        let original = sample("p", title: "old", custom: "old")
        var handedID = ""
        do {
            let store = try SyncStore(fileURL: file)
            let stored = try await store.commit(post: renamed(original, "one"), op: edit(.title, post: original, title: "one"))
            let begun = try await store.beginSend(stored.opID)
            let handed = try #require(begun)
            #expect(handed.sending)
            handedID = handed.opID
        }
        // the next launch
        let store = try SyncStore(fileURL: file)
        let waiting = try await store.pendingOps()
        #expect(waiting.map(\.opID) == [handedID])
        #expect(waiting.first?.sending == false)
        #expect(waiting.first?.tries == 1)
        let second = try await store.commit(post: renamed(original, "two"), op: edit(.title, post: renamed(original, "one"), title: "two"))
        #expect(second.opID != handedID)
        let both = try await store.pendingOps()
        #expect(both.map(\.payload.title) == ["one", "two"])
    }

    @Test func oneFilesSwitchAnothersAndTheWholePostsStatusAreSeparateOps() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = twoFiles("p", visibility: .private)
        try await store.upsert(post)
        _ = try await store.commit(post: post, op: edit(.visibility, post: post, fileID: "p-f", makePublic: true))
        let g = try await store.commit(post: post, op: edit(.visibility, post: post, fileID: "p-g", makePublic: true))
        var ops = try await store.pendingOps()
        #expect(ops.map(\.payload.fileID) == ["p-f", "p-g"])

        // the same file again, nothing sent yet: the same op, with the newer answer
        let gAgain = try await store.commit(post: post, op: edit(.visibility, post: post, fileID: "p-g", makePublic: false))
        #expect(gAgain.opID == g.opID)
        ops = try await store.pendingOps()
        #expect(ops.map(\.payload.makePublic) == [true, false])

        // the whole post, then the first file again: neither is written into an older op
        _ = try await store.commit(post: post, op: edit(.visibility, post: post, status: .private))
        _ = try await store.commit(post: post, op: edit(.visibility, post: post, fileID: "p-f", makePublic: false))
        ops = try await store.pendingOps()
        #expect(ops.count == 4)
        #expect(ops.map(\.payload.fileID) == ["p-f", "p-g", nil, "p-f"])
        #expect(ops.map(\.payload.status) == [nil, nil, "private", nil])
    }

    @Test func aKeyConflictIsSentAgainUnderANewKeyAndIsNotARefusal() async throws {
        #expect(MutationRetry.attempt(CobaltError.api(code: "error.idempotency.conflict", httpStatus: 409), kind: .title) == .rekey)
        #expect(MutationRetry.attempt(SyncError.keyConflict, kind: .hide) == .rekey)
        #expect(MutationRetry.attempt(CobaltError.api(code: "error.library.conflict", httpStatus: 409), kind: .title) == .refused)

        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        let stored = try await store.commit(post: renamed(original, "new"), op: edit(.title, post: original, title: "new"))
        let sender = ScriptedSender(results: [
            .failure(CobaltError.api(code: "error.idempotency.conflict", httpStatus: 409)), .success(()),
        ])
        let first = await OutboxDrainer.drain(store: store, sender: sender, now: t0)
        #expect(first.refused.isEmpty)
        #expect(first.acknowledged.isEmpty)
        #expect(try await store.post(id: "p")?.customTitle == "new")
        let waiting = try await store.pendingOps()
        #expect(waiting.map(\.opID) == [stored.opID])
        #expect(waiting.first?.tries == 1)
        let newKey = try #require(waiting.first?.idempotencyKey)
        #expect(newKey != stored.opID)

        let second = await OutboxDrainer.drain(store: store, sender: sender, now: t0.addingTimeInterval(MutationRetry.backoff(tries: 1)))
        #expect(second.acknowledged == [stored.opID])
        #expect(sender.keys == [stored.opID, newKey])
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aRefusalPutsBackThePostWithoutThatEditAndKeepsTheLaterOne() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        let first = try await store.commit(post: renamed(original, "one"), op: edit(.title, post: original, title: "one"))
        _ = try await store.beginSend(first.opID)
        let second = try await store.commit(post: renamed(original, "two"), op: edit(.title, post: renamed(original, "one"), title: "two"))
        #expect(second.opID != first.opID)

        try await store.rollback(first)
        #expect(try await store.post(id: "p")?.customTitle == "two")
        let left = try await store.pendingOps()
        #expect(left.map(\.opID) == [second.opID])
        let before = try #require(left.first?.payload.before)
        #expect(SyncPostCoding.decode(before)?.customTitle == "old")

        try await store.rollback(try #require(left.first))
        #expect(try await store.post(id: "p")?.customTitle == "old")
    }
}

@Suite("sync outbox: what the server answered")
struct SyncReplyTests {
    @Test func aStatusReplyThatListsThePostAsFailedIsARefusal() throws {
        let post = twoFiles("p", visibility: .private)
        let op = edit(.visibility, post: post, status: .public)

        let refusedReply = StatusChange(posts: [], failed: [StatusChange.Failure(id: "p", error: "error.private.not_toggleable")])
        #expect(throws: SyncError.refused("error.private.not_toggleable")) {
            _ = try SyncReply.status(refusedReply, op: op)
        }

        let taken = StatusChange(posts: [StatusChange.Post(id: "p", postKey: "p", status: .public)], failed: [])
        #expect(try SyncReply.status(taken, op: op) == .done)

        // the post was taken, one file was not: the server's account of the files is the receipt
        let partly = StatusChange(
            posts: [StatusChange.Post(id: "p", postKey: "p", status: .public, files: [StatusChange.File(id: "p-f", visibility: "public")])],
            failed: [StatusChange.Failure(id: "p-g", error: "error.share.off")])
        let receipt = try SyncReply.status(partly, op: op)
        let served = try #require(receipt.post)
        #expect(served.files.map(\.isPublic) == [true, false])
        #expect(served.visibility == .public)
        #expect(!served.hidden)
    }

    @Test func theServersAnswerReplacesTheOptimisticRow() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = twoFiles("p", visibility: .private)
        var optimistic = post
        SyncMerge.apply(PostStatus.public, to: &optimistic)
        let stored = try await store.commit(post: optimistic, op: edit(.visibility, post: post, status: .public))
        #expect(try await store.post(id: "p")?.files.map(\.isPublic) == [true, true])

        var answer = post
        answer.files[0].wireVisibility = .public
        let served = answer
        let sender = HookSender { _ in SyncReceipt(post: served) }
        let done = await OutboxDrainer.drain(store: store, sender: sender, now: t0)
        #expect(done.acknowledged == [stored.opID])
        #expect(done.receipts[stored.opID]?.post?.id == "p")
        #expect(try await store.post(id: "p")?.files.map(\.isPublic) == [true, false])
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aPartialDeleteKeepsThePostWithTheFilesThatAreLeft() async throws {
        let post = twoFiles("p")
        let op = edit(.delete, post: post)
        #expect(SyncReply.delete(PostDeleteResult(deletedFiles: 2, deletedBytes: 20, remaining: []), op: op) == .done)
        let receipt = SyncReply.delete(PostDeleteResult(deletedFiles: 1, deletedBytes: 10, remaining: ["p-g"]), op: op)
        #expect(receipt.remaining == ["p-g"])
        #expect(receipt.post?.files.map(\.id) == ["p-g"])

        let store = try SyncStore(fileURL: try tempDB())
        try await store.upsert(post)
        let stored = try await store.commit(post: nil, op: op)
        #expect(try await store.post(id: "p") == nil)
        let sender = HookSender { _ in receipt }
        let done = await OutboxDrainer.drain(store: store, sender: sender, now: t0)
        #expect(done.acknowledged == [stored.opID])
        #expect(done.receipts[stored.opID]?.remaining == ["p-g"])
        #expect(try await store.post(id: "p")?.files.map(\.id) == ["p-g"])
    }
}

@Suite("sync outbox: markers, expiry and a changed server")
struct SyncOutboxSettleTests {
    @Test func aDeleteMarkerHeldForAPendingEditIsAppliedWhenTheEditIsRefused() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p2", title: "old name", custom: "old name")
        let stored = try await store.commit(post: renamed(original, "new name"), op: edit(.title, post: original, title: "new name"))
        try await store.apply(page(44, gone: [SyncGone(entity: "post", id: "p2")]))
        #expect(try await store.post(id: "p2")?.customTitle == "new name")

        // the title's retry is answered 404: the post is gone, and the row must not come back
        let restored = try await store.rollback(stored)
        #expect(restored == nil)
        #expect(try await store.post(id: "p2") == nil)
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aDeleteMarkerHeldForAPendingEditIsAppliedWhenTheEditIsTaken() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p2", title: "clip")
        var hiddenPost = original
        hiddenPost.hidden = true
        let stored = try await store.commit(post: hiddenPost, op: edit(.hide, post: original, status: .hidden))
        try await store.apply(page(44, gone: [SyncGone(entity: "post", id: "p2")]))
        #expect(try await store.post(id: "p2") != nil)

        try await store.settle(stored, post: nil)
        #expect(try await store.post(id: "p2") == nil)

        // a marker is only held while an edit is pending: a post the server lists later is kept
        try await store.apply(page(45, posts: [original]))
        #expect(try await store.post(id: "p2") != nil)
    }

    @Test func anEditGivenUpAfterAWeekIsRolledBackAndReportedAsRefused() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = sample("p", title: "kept")
        try await store.upsert(post)
        let stored = try await store.commit(post: nil, op: edit(.delete, post: post))
        #expect(try await store.post(id: "p") == nil)
        let sender = ScriptedSender(results: [])

        let late = t0.addingTimeInterval(MutationRetry.retention + 1)
        let dropped = await OutboxDrainer.drain(store: store, sender: sender, now: late)
        #expect(sender.keys.isEmpty)
        #expect(dropped.refused.map(\.opID) == [stored.opID])
        #expect(dropped.reasons[stored.opID] == OutboxDrainer.expiredReason)
        #expect(try await store.post(id: "p")?.title == "kept")
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aDrainStopsSendingAndPutsNothingBackOnceTheServerChanged() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let a = sample("a", title: "a", custom: "a")
        let b = sample("b", title: "b", custom: "b")
        let first = try await store.commit(post: renamed(a, "a2"), op: edit(.title, post: a, title: "a2"))
        _ = try await store.commit(post: renamed(b, "b2"), op: edit(.title, post: b, title: "b2"))

        // the server is changed while the first request is out: the copy and the outbox are wiped
        let changed = Mutex(false)
        let sender = HookSender { _ in
            changed.withLock { $0 = true }
            try await store.wipeAll()
            throw SyncError.refused("error.library.not_found")
        }
        let drained = await OutboxDrainer.drain(store: store, sender: sender, now: t0) {
            !changed.withLock { $0 }
        }
        #expect(sender.sent.map(\.opID) == [first.opID])
        #expect(drained.refused.isEmpty)
        #expect(try await store.post(id: "a") == nil)
        #expect(try await store.post(id: "b") == nil)

        // even without the check, an op that is no longer in the outbox puts nothing back
        let restored = try await store.rollback(first)
        #expect(restored == nil)
        #expect(try await store.post(id: "a") == nil)
    }
}

@Suite("sync pull failures")
struct SyncPullFailureTests {
    @Test func aCursorAnswered410OnceLeadsToExactlyOneFullReload() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.apply(page(50, posts: [sample("old", title: "old")]))
        let refusals = Mutex(0)
        let transport = ScriptedSync { since in
            if since == 50 {
                refusals.withLock { $0 += 1 }
                throw SyncError.cursorTooOld
            }
            if since == 0 { return page(2, more: true, posts: [sample("a", title: "a")]) }
            return page(4, posts: since < 4 ? [sample("b", title: "b")] : [])
        }
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.syncNow()
        #expect(transport.calls == [50, 0, 2])
        #expect(refusals.withLock { $0 } == 1)
        #expect(try await store.snapshot().visible.map(\.id).sorted() == ["a", "b"])
        #expect(await store.cursor() == 4)
        #expect(!(await engine.fellBack))

        // the next pass carries on from the new cursor: no second reload
        await engine.syncNow()
        #expect(transport.calls == [50, 0, 2, 4])
    }

    @Test func aReloadThatIsAnswered410AgainStopsAndFallsBackInsteadOfLooping() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.apply(page(50, posts: [sample("old", title: "old")]))
        let transport = ScriptedSync { since in
            if since != 0 { throw SyncError.cursorTooOld }
            return page(2, more: true, posts: [sample("a", title: "a")])
        }
        let seen = Mutex<[SyncActivity]>([])
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.setActivity { event in seen.withLock { $0.append(event) } }
        await engine.syncNow()
        #expect(transport.calls == [50, 0, 2])
        #expect(await engine.fellBack)
        #expect(seen.withLock { $0 }.contains(.fellBack))
        // half a library is not kept as the copy
        #expect(!(await store.hasReadyMarker()))
        #expect(await store.cursor() == 0)

        await engine.syncNow()
        #expect(transport.calls == [50, 0, 2])
    }

    @Test func aServerErrorWithNothingOnTheDeviceFallsBack() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let transport = ScriptedSync { _ in throw CobaltError.api(code: "error.api.generic", httpStatus: 500) }
        let seen = Mutex<[SyncActivity]>([])
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.setActivity { event in seen.withLock { $0.append(event) } }
        await engine.syncNow()
        #expect(await engine.fellBack)
        let events = seen.withLock { $0 }
        #expect(events.contains(.fellBack))
        #expect(events.last == .passEnded(pending: 0))
    }

    @Test func aServerErrorWithACopyKeepsTheCopyAndSaysSo() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.apply(page(7, posts: [sample("kept", title: "kept")]))
        let transport = ScriptedSync { _ in throw CobaltError.api(code: "error.api.generic", httpStatus: 500) }
        let seen = Mutex<[SyncActivity]>([])
        let failures = Mutex<[String]>([])
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.setCallbacks(
            snapshot: { _ in }, fallback: {}, acknowledged: { _, _ in }, refused: { _, _ in },
            pullFailed: { error in failures.withLock { $0.append(String(describing: error)) } })
        await engine.setActivity { event in seen.withLock { $0.append(event) } }
        await engine.syncNow()
        #expect(!(await engine.fellBack))
        #expect(failures.withLock { $0 }.count == 1)
        #expect(seen.withLock { $0 }.contains(.pullFailed(offline: false)))
        #expect(try await store.post(id: "kept")?.title == "kept")
        #expect(await store.cursor() == 7)
    }

    /// A 503 is what the server answers when a database read fails. With a copy and an edit waiting
    /// the engine must stay on: turned off, the queued edit would sit unsent for the whole launch
    /// and overwrite a newer one on the next.
    @Test func a503WithACopyAndAnEditWaitingKeepsTheEngineOnAndTheEditQueued() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = sample("p", title: "old", custom: "old")
        try await store.apply(page(7, posts: [original]))
        let stored = try await store.commit(post: renamed(original, "new"), op: op(.title, post: original, title: "new"))
        let transport = ScriptedSync { _ in throw CobaltError.api(code: "error.api.generic", httpStatus: 503) }
        let sender = ScriptedSender(results: [.failure(SyncError.retryable("offline"))])
        let seen = Mutex<[SyncActivity]>([])
        let failures = Mutex<[String]>([])
        let engine = SyncEngine(store: store, transport: transport, sender: sender)
        await engine.setCallbacks(
            snapshot: { _ in }, fallback: { Issue.record("a 503 with a copy must not fall back") },
            acknowledged: { _, _ in }, refused: { _, _ in },
            pullFailed: { error in failures.withLock { $0.append(String(describing: error)) } })
        await engine.setActivity { event in seen.withLock { $0.append(event) } }
        await engine.syncNow()
        #expect(!(await engine.fellBack))
        #expect(failures.withLock { $0 }.count == 1)
        let events = seen.withLock { $0 }
        #expect(events.contains(.pullFailed(offline: false)))
        #expect(!events.contains(.fellBack))
        #expect(events.last == .passEnded(pending: 1))
        #expect(try await store.pendingOps().map(\.opID) == [stored.opID])
        #expect(try await store.post(id: "p")?.customTitle == "new")
        #expect(await store.cursor() == 7)
    }

    /// The API deployed before its migration: 503 and nothing on the device. Today's pages are used.
    @Test func a503WithNothingOnTheDeviceFallsBack() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let transport = ScriptedSync { _ in throw CobaltError.api(code: "error.api.generic", httpStatus: 503) }
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.syncNow()
        #expect(await engine.fellBack)
    }

    @Test func offlineOnTheFirstLaunchStaysOnAndSaysSoThenFillsWhenTheServerAnswers() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let down = Mutex(true)
        let transport = ScriptedSync { _ in
            if down.withLock({ $0 }) { throw CobaltError.network(.notConnectedToInternet) }
            return page(3, posts: [sample("a", title: "a")])
        }
        let seen = Mutex<[SyncActivity]>([])
        let failures = Mutex<[String]>([])
        let engine = SyncEngine(store: store, transport: transport, sender: ScriptedSender(results: []))
        await engine.setCallbacks(
            snapshot: { _ in }, fallback: {}, acknowledged: { _, _ in }, refused: { _, _ in },
            pullFailed: { error in failures.withLock { $0.append(String(describing: error)) } })
        await engine.setActivity { event in seen.withLock { $0.append(event) } }
        await engine.syncNow()
        #expect(!(await engine.fellBack))
        #expect(failures.withLock { $0 }.count == 1)
        #expect(seen.withLock { $0 }.contains(.pullFailed(offline: true)))

        down.withLock { $0 = false }
        await engine.syncNow()
        #expect(seen.withLock { $0 }.contains(.pulled))
        #expect(failures.withLock { $0 }.count == 1)
        #expect(try await store.post(id: "a")?.title == "a")
    }
}

@Suite("library sync: answers reach the caller and the glow")
@MainActor
struct LibrarySyncAnswerTests {
    @Test func aStatusTheServerWillNotTakeComesBackToTheCallerAndTheRowIsRestored() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let original = twoFiles("p", visibility: .private)
        try await store.upsert(original)
        let sync = LibrarySync(
            store: store,
            transport: QuietPull { _ in page(3, posts: [original]) },
            sender: ScriptedSender(results: [.failure(SyncError.refused("error.private.not_toggleable"))]))
        var after = original
        SyncMerge.apply(PostStatus.public, to: &after)
        do {
            try await sync.enqueueStatus(before: original, after: after, status: .public)
            Issue.record("a refused status should throw")
        } catch SyncError.refused(let code) {
            #expect(code == "error.private.not_toggleable")
            #expect(LibraryModel.statusErrorCode(SyncError.refused(code)) == "error.private.not_toggleable")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(try await store.post(id: "p")?.visibility == .private)
        #expect(try await store.post(id: "p")?.files.map(\.isPublic) == [false, false])
        #expect(try await store.pendingOps().isEmpty)
        #expect(sync.status.state == .refused)
    }

    @Test func aPartialDeleteIsReportedToTheCallerAndToItsConfirmation() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = twoFiles("p")
        try await store.upsert(post)
        var kept = post
        kept.files.removeAll { $0.id != "p-g" }
        let served = kept
        let sync = LibrarySync(
            store: store,
            transport: QuietPull { _ in page(3, posts: [served]) },
            sender: HookSender { _ in SyncReceipt(post: served, remaining: ["p-g"]) })
        let confirmed = Mutex<[[String]]>([])
        let remaining = try await sync.enqueueDelete(post: post, anchor: "p-f") { left in
            confirmed.withLock { $0.append(left) }
        }
        #expect(remaining == ["p-g"])
        #expect(confirmed.withLock { $0 } == [["p-g"]])
        #expect(try await store.post(id: "p")?.files.map(\.id) == ["p-g"])
    }

    @Test func aDeleteQueuedByAnEarlierLaunchStillRemovesTheDevicesCopy() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let post = sample("p", title: "going")
        // queued last launch: the op is in the outbox, the closure that removed the files is not
        _ = try await store.commit(post: nil, op: edit(.delete, post: post, at: Date()))
        let sync = LibrarySync(store: store, transport: QuietPull { _ in page(3) }, sender: ScriptedSender(results: []))
        let removed = Mutex<[String]>([])
        sync.onDeleteConfirmed = { gone in removed.withLock { $0.append(gone.id) } }
        await sync.kick(.launch)
        #expect(removed.withLock { $0 } == ["p"])
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aPullThatCannotReachTheServerTurnsTheGlowOfflineAndTellsTheLibrary() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.apply(page(1, posts: [sample("kept", title: "kept")]))
        let down = Mutex(true)
        let pulls = QuietPull { _ in
            if down.withLock({ $0 }) { throw CobaltError.network(.notConnectedToInternet) }
            return page(2, posts: [sample("b", title: "b")])
        }
        let sync = LibrarySync(store: store, transport: pulls, sender: ScriptedSender(results: []))
        let told = Mutex<[PipelineFailure?]>([])
        sync.onPullFailure = { error in told.withLock { $0.append(pipelineFailure(from: error, during: .saving)) } }
        await sync.kick(.foreground)
        #expect(sync.isActive)
        #expect(sync.status.state == .offlinePending)
        #expect(told.withLock { $0 } == [.unreachable])
        #expect(try await store.post(id: "kept")?.title == "kept")

        down.withLock { $0 = false }
        await sync.kick(.foreground)
        #expect(sync.status.state == .upToDate)
        #expect(told.withLock { $0 }.count == 1)
    }

    /// Offline, then the server is reached and will not serve the pull. The refused flicker plays
    /// and, once it is over, the glow must not settle back on "offline": the server answered.
    @Test func aPullTheServerRefusesAfterAnOfflineOneEndsTheGlowsOffline() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.apply(page(1, posts: [sample("kept", title: "kept")]))
        let down = Mutex(true)
        let pulls = QuietPull { _ in
            if down.withLock({ $0 }) { throw CobaltError.network(.notConnectedToInternet) }
            throw CobaltError.api(code: "error.api.generic", httpStatus: 500)
        }
        let sync = LibrarySync(store: store, transport: pulls, sender: ScriptedSender(results: []))
        let told = Mutex(0)
        sync.onPullFailure = { _ in told.withLock { $0 += 1 } }
        await sync.kick(.foreground)
        #expect(sync.status.state == .offlinePending)

        down.withLock { $0 = false }
        await sync.kick(.foreground)
        #expect(sync.isActive)
        #expect(sync.status.state == .refused)
        #expect(told.withLock { $0 } == 2)
        // long after the flicker
        sync.status.tick(now: Date().addingTimeInterval(3_600))
        #expect(sync.status.state == .upToDate)
    }

    @Test func aPullTheServerRefusesWithACopyFlickersTheGlowAndTellsTheLibrary() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        try await store.apply(page(1, posts: [sample("kept", title: "kept")]))
        let sync = LibrarySync(
            store: store,
            transport: QuietPull { _ in throw CobaltError.api(code: "error.api.generic", httpStatus: 500) },
            sender: ScriptedSender(results: []))
        let told = Mutex(0)
        sync.onPullFailure = { _ in told.withLock { $0 += 1 } }
        await sync.kick(.foreground)
        #expect(sync.isActive)
        #expect(sync.status.state == .refused)
        #expect(told.withLock { $0 } == 1)
    }

    @Test func aPullTheServerCannotServeWithNothingOnTheDeviceLoadsTheOldWayOnce() async throws {
        let store = try SyncStore(fileURL: try tempDB())
        let sync = LibrarySync(
            store: store,
            transport: QuietPull { _ in throw CobaltError.api(code: "error.api.generic", httpStatus: 500) },
            sender: ScriptedSender(results: []))
        let loads = Mutex(0)
        sync.onLegacy = { loads.withLock { $0 += 1 } }
        await sync.kick(.foreground)
        #expect(!sync.isActive)
        #expect(sync.status.state == .off)
        #expect(loads.withLock { $0 } == 1)

        await sync.kick(.foreground)
        #expect(loads.withLock { $0 } == 1)
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

/// A pull double that does not call `#expect`. `ScriptedSync` does, and from a `@MainActor` test that
/// is waiting on the engine, that record has to get back onto the main actor and the pass stalls.
private final class QuietPull: SyncTransport, @unchecked Sendable {
    private let handler: @Sendable (Int64) throws -> SyncPage
    private let seen = Mutex<[Int64]>([])
    var calls: [Int64] { seen.withLock { $0 } }

    init(_ handler: @escaping @Sendable (Int64) throws -> SyncPage) { self.handler = handler }

    func pull(since: Int64, limit: Int) async throws -> SyncPage {
        seen.withLock { $0.append(since) }
        _ = limit
        return try handler(since)
    }
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

    func send(_ op: SyncOp) async throws -> SyncReceipt {
        let index = count.withLock { n -> Int in
            let current = n
            n += 1
            return current
        }
        sent.withLock { $0.append(op.idempotencyKey) }
        if results.indices.contains(index) { try results[index].get() }
        else if let last = results.last { try last.get() }
        return .done
    }
}

/// A sender whose answer is a closure, so a test can act while a request is "on its way" (make a
/// second edit, change the server) and can answer with a receipt.
private final class HookSender: SyncSender, @unchecked Sendable {
    private let body: @Sendable (SyncOp) async throws -> SyncReceipt
    private let seen = Mutex<[SyncOp]>([])
    var sent: [SyncOp] { seen.withLock { $0 } }

    init(_ body: @escaping @Sendable (SyncOp) async throws -> SyncReceipt) { self.body = body }

    func send(_ op: SyncOp) async throws -> SyncReceipt {
        seen.withLock { $0.append(op) }
        return try await body(op)
    }
}

/// A post with two files, `<id>-f` and `<id>-g`.
private func twoFiles(_ id: String, visibility: Visibility? = nil) -> LibraryPost {
    var post = sample(id, title: id, visibility: visibility)
    var second = post.files[0]
    second.id = "\(id)-g"
    post.files.append(second)
    return post
}

private func edit(
    _ kind: SyncOp.Kind, post: LibraryPost, status: PostStatus? = nil, fileID: String? = nil, makePublic: Bool? = nil,
    title: String? = nil, at: Date = t0
) -> SyncOp {
    SyncOp(
        opID: UUID().uuidString, kind: kind, target: post.id,
        payload: SyncOp.Payload(
            anchor: fileID ?? post.files.first?.id ?? post.id, title: title, status: status?.rawValue,
            makePublic: makePublic, fileID: fileID, before: SyncPostCoding.encode(post)),
        createdAt: at, tries: 0, nextAttemptAt: Date(timeIntervalSince1970: 0))
}

private func page(_ seq: Int64, more: Bool = false, posts: [LibraryPost] = [], gone: [SyncGone] = []) -> SyncPage {
    SyncPage(seq: seq, more: more, posts: posts, links: [], collections: [], sets: [], names: [], rules: [], gone: gone)
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
    enum Mode { case ok, missing, tooOld, notReady, broken }

    init(posts: [LibraryPost]) { state = Mutex(State(posts: posts)) }

    var applied: [String: Int] { state.withLock { $0.applied } }
    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    func respond(_ request: LoopbackServer.Request) -> LoopbackServer.Response {
        if request.method == "GET", request.path == "/sync" {
            return state.withLock { state in
                switch state.mode {
                case .missing: return .json(#"{"error":{"code":"error.route.not_found"}}"#, status: 404)
                case .tooOld: return .json(#"{"error":"sync.cursor_too_old"}"#, status: 410)
                case .notReady: return .json(#"{"error":{"code":"error.api.generic"}}"#, status: 503)
                case .broken: return .json(#"{"error":{"code":"error.api.generic"}}"#, status: 500)
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
