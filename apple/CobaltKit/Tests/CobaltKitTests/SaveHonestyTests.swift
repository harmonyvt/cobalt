import Foundation
import Testing
@testable import CobaltKit

// Phase 2 of the transparency work, the pipeline's half (apple 02-PHASE2 2.2.1 to 2.2.4; 06 matrix, CobaltKit tests 1 to 4):
// the session's new fields, the two parts of a save, the server's word on waking, the render poll's pacing, the gallery's own
// count, the error table, and the copy on this device.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// A session of `GET /studio/<sid>` with only what a test needs.
private func session(
    _ id: String = "sid1", status: SessionStatus = .saving, step: SaveStep? = nil, bytes: Int64? = nil, total: Int64? = nil,
    waking: Bool? = nil, engine: SaveEngine? = nil, wakingEngine: SaveEngine? = nil, fallbackFrom: SaveEngine? = nil,
    fallbackCode: String? = nil, itemsDone: Int? = nil, itemsTotal: Int? = nil, errorCode: String? = nil
) -> StudioSession {
    var s = StudioSession(
        id: id, status: status, link: nil, service: nil, title: status == .ready ? "x" : nil,
        duration: status == .ready ? 14.77 : nil, width: status == .ready ? 720 : nil, height: status == .ready ? 1280 : nil,
        bytes: nil, createdAt: epoch, expiresAt: epoch.addingTimeInterval(600_000), errorCode: errorCode, renders: [],
        step: status == .saving ? step : nil, stepBytes: bytes, stepTotal: total, waking: waking)
    s.engine = engine
    s.wakingEngine = wakingEngine
    s.fallbackFrom = fallbackFrom
    s.fallbackCode = fallbackCode
    s.itemsDone = itemsDone
    s.itemsTotal = itemsTotal
    return s
}

// MARK: - 1. The wire

struct SaveWireTests {
    private func decode(_ json: String) throws -> StudioSession {
        try CobaltJSON.decoder().decode(StudioSession.self, from: Data(json.utf8))
    }

    @Test func decodesTheSixNewFields() throws {
        let s = try decode("""
        {"status":"saving","id":"sid_abc123","step":"reading","step_bytes":18979225,"step_total":39426457,"waking":false,
         "queue_ahead":null,"items_done":4,"items_total":6,"engine":"ytdlp","waking_engine":null,
         "fallback_from":"cobalt","fallback_code":"error.api.fetch.fail","created_at":1790000000000,
         "expires_at":1790604800000,"error":null,"renders":[]}
        """)
        #expect(s.itemsDone == 4 && s.itemsTotal == 6)
        #expect(s.engine == .ytdlp && s.wakingEngine == nil)
        #expect(s.fallbackFrom == .cobalt && s.fallbackCode == "error.api.fetch.fail")
        #expect(s.step == .reading && s.stepBytes == 18_979_225 && s.waking == false)
    }

    @Test func decodesAWakingEngine() throws {
        let s = try decode("""
        {"status":"saving","id":"a","step":"fetching","waking":true,"waking_engine":"ytdlp","engine":"ytdlp",
         "created_at":1790000000000,"expires_at":1790604800000,"renders":[]}
        """)
        #expect(s.waking == true && s.wakingEngine == .ytdlp && s.engine == .ytdlp)
    }

    @Test func aLegacySessionWithoutAnyOfThemStillDecodes() throws {
        let s = try decode("""
        {"status":"saving","id":"abc","link":"https://x.com/i/status/1","service":"twitter","title":null,
         "duration":null,"width":null,"height":null,"bytes":null,"created_at":1790000000000,
         "expires_at":1790604800000,"error":null,"renders":[]}
        """)
        #expect(s.itemsDone == nil && s.itemsTotal == nil)
        #expect(s.engine == nil && s.wakingEngine == nil && s.fallbackFrom == nil && s.fallbackCode == nil)
    }

    @Test func anEngineThisBuildDoesNotKnowIsNotSaidAndFailsNothing() throws {
        let s = try decode("""
        {"status":"saving","id":"abc","engine":"gallery-dl","fallback_from":"aria2","waking_engine":7,
         "created_at":1790000000000,"expires_at":1790604800000,"renders":[]}
        """)
        #expect(s.engine == nil && s.fallbackFrom == nil && s.wakingEngine == nil)
        #expect(s.id == "abc")
    }

    @Test func roundTrips() throws {
        let s = session(step: .storing, bytes: 5, total: 10, waking: false, engine: .cobalt, fallbackFrom: .ytdlp,
                        fallbackCode: "error.api.youtube.login", itemsDone: 1, itemsTotal: 3)
        let data = try CobaltJSON.encoder().encode(s)
        let back = try CobaltJSON.decoder().decode(StudioSession.self, from: data)
        #expect(back == s)
    }
}

// MARK: - 2. Reading and storing are two things

struct SaveStatusTests {
    @Test func readingAndStoringAreDistinctPhases() {
        let reading = SaveStatus(session: session(step: .reading, bytes: 1, total: 10))
        let storing = SaveStatus(session: session(step: .storing, bytes: 1, total: 10))
        let fetching = SaveStatus(session: session(step: .fetching))
        #expect(reading.phase == .downloading)
        #expect(storing.phase == .storing)
        #expect(fetching.phase == .downloading)
        #expect(reading.phase != storing.phase)
        #expect(SaveStatus(session: session(step: .queued)).phase == .unknown)
        #expect(SaveStatus(session: session(step: nil)).phase == .unknown)
    }

    @Test func readingAndStoringAreNeverWaking() {
        #expect(!SaveStatus(session: session(step: .reading, waking: true)).waking)
        #expect(!SaveStatus(session: session(step: .storing, waking: true, wakingEngine: .ytdlp)).waking)
        #expect(SaveStatus(session: session(step: .storing, waking: true, wakingEngine: .ytdlp)).wakingEngine == nil)
        #expect(!SaveStatus(session: session(step: .queued, waking: true)).waking)
    }

    @Test func theServersWakingIsTakenAtItsWord() {
        let waking = SaveStatus(session: session(step: .fetching, waking: true, engine: .ytdlp, wakingEngine: .ytdlp))
        #expect(waking.waking && waking.wakingEngine == .ytdlp && waking.engine == .ytdlp)
        // a downloader that is not waking has no waking engine, whatever the field says
        #expect(SaveStatus(session: session(step: .fetching, waking: false, wakingEngine: .ytdlp)).wakingEngine == nil)
        // an older server that never says it is not waking
        #expect(!SaveStatus(session: session(step: .fetching, waking: nil)).waking)
    }

    @Test func aSwitchIsKept() {
        let s = SaveStatus(session: session(step: .reading, engine: .ytdlp, fallbackFrom: .cobalt, fallbackCode: "error.api.fetch.fail"))
        #expect(s.switched && s.fallbackFrom == .cobalt && s.engine == .ytdlp && s.fallbackCode == "error.api.fetch.fail")
        #expect(!SaveStatus(session: session(step: .reading, engine: .cobalt)).switched)
    }
}

// MARK: - 3. Waking is the server's word once it has spoken

@MainActor
@Suite(.serialized)
struct ServerWakingTests {
    @Test func theDevicesGuessHoldsOnlyUntilTheServerSpeaks() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        p.setState(.fetching(since: since, waking: true))                  // the 1.5 s guess on a request still out
        p.setState(.fetching(since: since, waking: false))
        #expect(p.state == .fetching(since: since, waking: true), "a second guess does not flip it back")

        p.serverSpoke = true                                               // the first `GET /studio/<sid>` answered
        p.setState(.fetching(since: since, waking: false))
        #expect(p.state == .fetching(since: since, waking: false), "the server said not waking: nothing keeps the guess alive")

        p.markWaking(since: since)                                         // a late timer cannot turn it back on
        #expect(p.state == .fetching(since: since, waking: false))
    }

    @Test func aFreshRunStartsHonest() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.serverSpoke = true
        p.begin(input: nil)
        #expect(!p.serverSpoke && p.saveStatus == SaveStatus() && p.localCopyState == .notRequested)
    }

    @Test func eachReplysWakingIsShownAsItIsAndPhasesFollowTheStep() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        let seen = Log<String>()
        let polls = Log<Int>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in
            let n = polls.add(1)
            // what the pipeline made of the previous reply
            let before = await MainActor.run { p.saveStatus }
            seen.add("\(n):\(before.phase):\(before.engine?.rawValue ?? "-"):\(before.wakingEngine?.rawValue ?? "-"):\(before.fallbackFrom?.rawValue ?? "-"):\(before.waking)")
            switch n {
            case 1: return session(id, step: .fetching, waking: true, engine: .ytdlp, wakingEngine: .ytdlp)
            case 2: return session(id, step: .fetching, waking: false, engine: .ytdlp, fallbackFrom: .cobalt, fallbackCode: "error.api.fetch.fail")
            case 3: return session(id, step: .reading, bytes: 10, total: 100, waking: true, engine: .ytdlp, fallbackFrom: .cobalt)
            case 4: return session(id, step: .storing, bytes: 50, total: 100, waking: false, engine: .ytdlp, fallbackFrom: .cobalt)
            default: return session(id, status: .ready)
            }
        }
        h.ctx.client = stub
        p.start(link: URL(string: pastedLink)!)
        await h.drive(until: { h.isTerminalOrReady() }, maxVirtualSeconds: 1_000)
        #expect(p.state == .ready)

        // the server's waking, reply by reply: true, then false at once (no flicker held), never on while reading
        let kinds = h.kinds
        let firstWaking = try #require(kinds.firstIndex(of: "fetching(waking)"), "never showed waking: \(kinds)")
        let after = Array(kinds[firstWaking...])
        #expect(isSubsequence(["fetching(waking)", "fetching", "saving"], of: after), "\(kinds)")
        #expect(!after.drop { $0 != "fetching" }.contains("fetching(waking)"), "waking came back after the server said no: \(kinds)")

        // what each reply left behind
        let log = seen.all
        #expect(log.contains("2:downloading:ytdlp:ytdlp:-:true"), "\(log)")          // reply 1: waking yt-dlp
        #expect(log.contains("3:downloading:ytdlp:-:cobalt:false"), "\(log)")        // reply 2: switched from cobalt, awake
        #expect(log.contains("4:downloading:ytdlp:-:cobalt:false"), "\(log)")        // reply 3: reading, waking said true but it is reading
        #expect(log.contains("5:storing:ytdlp:-:cobalt:false"), "\(log)")            // reply 4: storing
    }
}

// MARK: - 4. The render poll keeps its pace

struct RenderPollPacerTests {
    private let working = RenderStatus.pending(phase: .decode, framesDone: 3, framesTotal: 150)

    @Test func aQuickUnchangedAnswerSlowsThePoll() {
        let clock = VirtualClock()
        var pacer = PollPacer()
        #expect(pacer.interval == PollPacer.floor)
        pacer.observe(working, clock: clock)                                 // news: the first answer
        #expect(pacer.interval == 1)
        pacer.observe(working, clock: clock)
        #expect(pacer.interval == 2)
        pacer.observe(working, clock: clock)
        #expect(pacer.interval == 4)
        for _ in 0..<6 { pacer.observe(working, clock: clock) }
        #expect(pacer.interval == PollPacer.ceiling, "never past 10 s")
    }

    @Test func aChangedAnswerPutsItBack() {
        let clock = VirtualClock()
        var pacer = PollPacer()
        for _ in 0..<4 { pacer.observe(working, clock: clock) }
        #expect(pacer.interval > 1)
        pacer.observe(.pending(phase: .decode, framesDone: 4, framesTotal: 150), clock: clock)
        #expect(pacer.interval == 1)
    }

    @Test func theSavesPollCountsTheEngineAndTheGalleryCountAsNews() {
        let clock = VirtualClock()
        var pacer = PollPacer()
        pacer.observe(session(step: .fetching, waking: false), clock: clock)
        pacer.observe(session(step: .fetching, waking: false), clock: clock)
        #expect(pacer.interval == 2)
        pacer.observe(session(step: .fetching, waking: false, engine: .ytdlp, fallbackFrom: .cobalt), clock: clock)
        #expect(pacer.interval == 1, "a switch of downloaders is news")
        pacer.observe(session(step: .fetching, waking: false, engine: .ytdlp, fallbackFrom: .cobalt), clock: clock)
        pacer.observe(session(step: .fetching, waking: false, engine: .ytdlp, fallbackFrom: .cobalt, itemsDone: 1, itemsTotal: 4), clock: clock)
        #expect(pacer.interval == 1, "so is a gallery's own count")
    }

    @Test @MainActor func aRenderThatAnswersAtOnceIsPacedInVirtualTime() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        let sid = try #require(p.sessionID)
        let polls = Log<Double>()
        var stub = ScriptedClient(base: h.ctx.client)
        let clock = h.clock
        stub.renderStatusHook = { _, _, _ in
            let n = polls.add(clock.elapsed)
            if n < 6 { return .pending(phase: .pack, framesDone: nil, framesTotal: nil) }     // the same answer, at once
            return .failed(code: "error.webp.job_lost")
        }
        stub.renderHook = { _, _ in "job1" }
        h.ctx.client = stub
        p.makeWebp()
        _ = sid
        await h.drive(until: { if case .failed = p.state { return true } else { return false } }, maxVirtualSeconds: 600)
        let times = polls.all
        #expect(times.count >= 6, "\(times)")
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 0.999 }, "polls came closer than a second: \(gaps)")
        #expect(gaps.last.map { $0 >= 2 } ?? false, "an unchanged answer did not slow the poll: \(gaps)")
    }
}

// MARK: - 5. A gallery says how many it has

@MainActor
@Suite(.serialized)
struct GalleryItemsDoneTests {
    private func run(_ replies: [StudioSession], total: Int, hook: @escaping @Sendable (Int, Pipeline) async -> Void = { _, _ in }) async -> (Harness, Pipeline, Log<Int>, Log<Bool>) {
        let h = Harness(.happy)
        let p = h.pipeline
        p.galleryRun = GalleryRun(total: total)
        let done = Log<Int>()
        let finished = Log<Bool>()
        let polls = Log<Int>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { _, _ in
            let n = polls.add(1)
            let seen = await MainActor.run { p.galleryRun?.done ?? -1 }
            done.add(seen)                                              // what the previous reply made of `done`
            await hook(n, p)
            return replies[min(n - 1, replies.count - 1)]
        }
        h.ctx.client = stub
        let client: any CobaltClient = stub
        Task { @MainActor in
            _ = try? await p.pollGallerySaving(client, id: "g1")
            finished.add(true)
        }
        await h.drive(until: { finished.count > 0 }, maxVirtualSeconds: 600)
        return (h, p, done, finished)
    }

    @Test func theServersCountIsUsedNotAByteEstimate() async {
        // bytes say 1%, the server says 3 of 6 are done
        let (_, p, done, finished) = await run([
            session("g1", step: .reading, bytes: 10, total: 1_000, itemsDone: 3, itemsTotal: 6),
            session("g1", status: .ready),
        ], total: 6)
        #expect(finished.count == 1)
        #expect(done.all.last == 3, "done after the first reply: \(done.all)")
        #expect(p.galleryRun?.total == 6)
    }

    @Test func theServersTotalMayRaiseTheCountButNeverLowerIt() async {
        let (_, p, done, _) = await run([
            session("g1", step: .reading, itemsDone: 2, itemsTotal: 8),
            session("g1", step: .reading, itemsDone: 1, itemsTotal: 4),                // a reply that went backwards
            session("g1", status: .ready),
        ], total: 6)
        #expect(p.galleryRun?.total == 8)
        #expect((done.all.last ?? 0) >= 2, "done went backwards: \(done.all)")
    }

    @Test func aLegacyServerKeepsTheByteEstimate() async {
        let (_, _, done, _) = await run([
            session("g1", step: .reading, bytes: 500, total: 1_000),                   // no items_done
            session("g1", status: .ready),
        ], total: 4)
        #expect(done.all.last == 2, "half of 4 by bytes: \(done.all)")
    }

    @Test func wakingGoesThroughToTheRun() async {
        let wakes = Log<Bool>()
        _ = await run([
            session("g1", step: .fetching, waking: true, engine: .ytdlp, wakingEngine: .ytdlp),
            session("g1", step: .reading, bytes: 10, total: 100, waking: false, itemsDone: 1, itemsTotal: 4),
            session("g1", status: .ready),
        ], total: 4) { n, p in
            if n >= 2 { wakes.add(await MainActor.run { p.galleryRun?.waking ?? false }) }
        }
        #expect(wakes.all.first == true, "waking was not passed to the gallery run: \(wakes.all)")
        #expect(wakes.all.last == false)
    }
}

// MARK: - 6. The error table

struct ErrorTableTests {
    private func map(_ code: String, _ phase: ErrorPhase = .saving) -> PipelineFailure { mapFailure(code: code, during: phase) }

    @Test func theSitesAnswersMapToFriendlyFailures() {
        #expect(map("error.api.youtube.login") == .fetchFailed(code: "error.api.youtube.login"))
        #expect(map("error.api.youtube.login").fetchProblem == .loginRequired)
        #expect(map("error.api.content.post.private").fetchProblem == .isPrivate)
        #expect(map("error.api.content.video.private").fetchProblem == .isPrivate)
        #expect(map("error.api.content.post.age").fetchProblem == .ageRestricted)
        #expect(map("error.api.content.video.age").fetchProblem == .ageRestricted)
        #expect(map("error.api.content.video.unavailable").fetchProblem == .unavailable)
        #expect(map("error.api.content.post.unavailable").fetchProblem == .unavailable)
        #expect(map("error.api.fetch.empty").fetchProblem == .empty)
        #expect(map("error.webp.no_video").fetchProblem == .empty)
        #expect(map("error.api.fetch.fail").fetchProblem == .failed)
        #expect(map("error.api.youtube.token_expired") == .fetchFailed(code: "error.api.youtube.token_expired"))
    }

    @Test func aRateLimitIsABusyServer() {
        #expect(map("error.api.rate_exceeded") == .serverBusy)
        #expect(map("error.api.rate_limit") == .serverBusy)
    }

    @Test func noCodeOfTheExtensionsTableFallsThroughRaw() {
        // extension/src/lib/progress.ts FRIENDLY: every code there has words, here as a case of its own or a sentence
        let table = [
            "error.webp.no_video", "error.api.fetch.empty", "error.api.content.video.unavailable",
            "error.api.content.video.private", "error.api.content.video.age", "error.api.youtube.login",
            "error.studio.busy", "error.studio.line_full", "error.studio.too_large", "error.studio.save_lost",
            "error.studio.expired", "error.studio.cancelled", "error.studio.not_found", "error.studio.not_video",
            "error.studio.upload_failed", "error.api.fetch.fail",
        ]
        #expect(table.count == 16)
        for code in table {
            let failure = map(code)
            switch failure {
            case .server(let raw):
                // a failure with no case of its own is allowed only as the line (its own sentence in `Copy`) or a code with a
                // sentence of its own
                let ok = raw == PipelineFailure.lineFullCode || ServerProblem(code: raw) != .other
                #expect(ok, "\(code) falls through to a raw server code")
            default:
                break
            }
        }
        #expect(map("error.studio.save_lost") == .server(code: "error.studio.save_lost"))
        #expect(ServerProblem(code: "error.studio.save_lost") == .saveLost)
        #expect(ServerProblem(code: "error.studio.cancelled") == .cancelled)
        #expect(ServerProblem(code: "error.studio.not_found") == .notFound)
        #expect(ServerProblem(code: "error.studio.upload_failed") == .uploadFailed)
        #expect(ServerProblem(code: "error.something.new") == .other)
    }

    @Test func tryAgainOnlyWhereItCanHelp() {
        #expect(!map("error.api.content.post.private").isRetryable)
        #expect(!map("error.api.content.post.age").isRetryable)
        #expect(!map("error.api.youtube.login").isRetryable)
        #expect(!map("error.api.content.video.unavailable").isRetryable)
        #expect(!map("error.api.fetch.empty").isRetryable)
        #expect(map("error.api.fetch.fail").isRetryable)
        #expect(map("error.api.fetch.rate").isRetryable)
        #expect(map("error.studio.busy").isRetryable)
        #expect(!PipelineFailure.keyInvalid.isRetryable && !PipelineFailure.tooLarge(limit: 1).isRetryable)
    }

    @Test func everyFailureHasACode() {
        #expect(PipelineFailure.fetchFailed(code: "error.api.fetch.fail").code == "error.api.fetch.fail")
        #expect(PipelineFailure.unreachable.code == "error.app.offline")
        #expect(PipelineFailure.expired.code == "error.studio.expired")
        #expect(PipelineFailure.server(code: "http.502").code == "http.502")
    }
}

// MARK: - 7. The copy on this device

@MainActor
@Suite(.serialized)
struct LocalCopyTests {
    private let media = MediaInfo(name: "clip", duration: 5, width: 720, height: 1280, bytes: 1_000, isImage: false)

    /// A pipeline on a context that is not a preview, so keeping the original really runs.
    private func rig(keep: Bool = true, download: @escaping @Sendable (Int, URL) async throws -> URL) throws -> (Harness, Pipeline, PipelineContext) {
        let h = Harness(.happy)
        let base = h.ctx
        let ctx = PipelineContext(
            client: base.client, capabilities: base.capabilities, settings: base.settings, store: base.store, jobs: base.jobs,
            tools: base.tools, clock: h.clock, photos: base.photos, clipboard: base.clipboard, intake: base.intake, isPreview: false)
        ctx.settings.keepVideosOnDevice = keep
        let attempts = Log<Int>()
        var stub = ScriptedClient(base: base.client)
        stub.downloadHook = { _, dest in try await download(attempts.add(1), dest) }
        ctx.client = stub
        return (h, Pipeline(context: ctx), ctx)
    }

    nonisolated private static func writeFile(_ dest: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PreviewMedia.placeholderBytes.write(to: dest)
        return dest
    }

    @Test func anOriginalThatDidNotComeSaysSoAndOffersARetry() async throws {
        let (h, p, ctx) = try rig { n, dest in
            if n == 1 { throw CobaltError.api(code: "error.studio.expired", httpStatus: 410) }
            return try Self.writeFile(dest)
        }
        p.keepOriginalInBackground(ctx.client, session: "sess1", media: media)
        #expect(p.localCopyState == .downloading(TransferProgress(bytes: 0, total: 1_000)))
        await h.drive(until: { p.localCopyState.isFailed })
        #expect(p.localCopyState == .failed(code: "error.studio.expired"))
        #expect(p.canRetryLocalCopy)
        #expect(p.keepRequest == nil, "the failed request is let go")

        p.retryLocalCopy()
        #expect(p.localCopyState == .downloading(TransferProgress(bytes: 0, total: 1_000)))
        await h.drive(until: { p.localCopyState == .savedOnDevice })
        #expect(p.localCopyState == .savedOnDevice)
        #expect(!p.canRetryLocalCopy)
        #expect(p.stored != nil)
    }

    @Test func keepingIsOffMeansNothingWasAsked() async throws {
        let (_, p, ctx) = try rig(keep: false) { _, dest in try Self.writeFile(dest) }
        p.keepOriginalInBackground(ctx.client, session: "sess1", media: media)
        #expect(p.localCopyState == .notRequested && p.keepRequest == nil)
    }

    @Test func theOfflineEngineCarriesTheOriginalWhenTheAppHasOne() async throws {
        let (h, p, ctx) = try rig { _, dest in try Self.writeFile(dest) }
        let downloads = OfflineDownloads(
            store: ctx.store, queue: OfflineQueue(directory: try makeTempDirectory()), transport: nil, clock: h.clock,
            client: { ctx.client })
        ctx.offlineDownloads = downloads
        p.keepOriginalInBackground(ctx.client, session: "sess2", media: media)
        #expect(downloads.states["s:sess2"] != nil, "the original is queued in the engine")
        await h.drive(until: { p.localCopyState == .savedOnDevice })
        #expect(p.localCopyState == .savedOnDevice)
        #expect(p.stored?.sessionID == "sess2")
        #expect(downloads.states["s:sess2"] == nil)
    }

    @Test func theOfflineEnginesFailureReachesTheRun() async throws {
        let (h, p, ctx) = try rig { _, _ in throw CobaltError.api(code: "error.studio.expired", httpStatus: 410) }
        let downloads = OfflineDownloads(
            store: ctx.store, queue: OfflineQueue(directory: try makeTempDirectory()), transport: nil, clock: h.clock,
            client: { ctx.client })
        ctx.offlineDownloads = downloads
        p.keepOriginalInBackground(ctx.client, session: "sess3", media: media)
        await h.drive(until: { p.localCopyState.isFailed })
        #expect(p.localCopyState == .failed(code: "error.studio.expired"))
        #expect(p.canRetryLocalCopy)
    }

    @Test func theOriginalsJobLandsAsASave() {
        let job = Pipeline.originalJob(session: "s9", media: media, link: nil, mediaID: nil, now: epoch)
        #expect(job.key == "s:s9" && job.aliases == ["s:s9"])
        #expect(job.origin == OfflineDownloads.saveOrigin, "the photos album copies it like any save made here")
        #expect(!job.isPulled)
        #expect(job.sources == [.studioSource(session: "s9")])
    }

    @Test func aWebpThatCouldNotBeStoredKeepsTheRunDoneAndSaysSo() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        var stub = ScriptedClient(base: h.ctx.client)
        let webpFetches = Log<Int>()
        stub.downloadHook = { file, _ in
            if case .open = file { webpFetches.add(1); throw CobaltError.network(.notConnectedToInternet) }
            throw CobaltError.invalidResponse(httpStatus: 500)
        }
        h.ctx.client = stub
        p.makeWebp()
        await h.driveToSettled()
        guard case .done = p.state else { Issue.record("expected .done, got \(p.state)"); return }
        #expect(p.localCopyState == .failed(code: "error.app.offline"))
        #expect(p.canRetryLocalCopy)
        #expect(webpFetches.count >= 1)
    }

    @Test func codesForWhatCanGoWrong() {
        #expect(Pipeline.localCopyCode(CobaltError.api(code: "error.studio.expired", httpStatus: 410)) == "error.studio.expired")
        #expect(Pipeline.localCopyCode(CobaltError.invalidResponse(httpStatus: 502)) == "http.502")
        #expect(Pipeline.localCopyCode(CobaltError.network(.timedOut)) == "error.app.offline")
        #expect(Pipeline.localCopyCode(URLError(.notConnectedToInternet)) == "error.app.offline")
        #expect(Pipeline.localCopyCode(CocoaError(.fileWriteOutOfSpace)) == "error.app.disk_full")
        #expect(Pipeline.localCopyCode(OfflineFailure.gone) == "error.studio.expired")
        #expect(Pipeline.localCopyCode(OfflineFailure.full) == "error.app.disk_full")
        #expect(Pipeline.localCopyCode(OfflineFailure.other(503)) == "http.503")
        struct Odd: Error {}
        #expect(Pipeline.localCopyCode(Odd()) == "error.app.local_copy_failed")
    }
}
