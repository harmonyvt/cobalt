import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Regression tests for the review of the core (polling, run tokens, key binding, failure phase,
// retries, handoffs, progress, file names). Every one runs on the virtual clock or on stubs: no
// network, no real sleeping.

// MARK: - Stubs

/// A cheap thread-safe log.
final class Log<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    @discardableResult func add(_ item: T) -> Int { items.withLock { $0.append(item); return $0.count } }
    var all: [T] { items.withLock { $0 } }
    var count: Int { items.withLock { $0.count } }
}

/// Parks callers until opened; not cancellation-aware (a request already on the wire).
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }
    var opened: Bool { isOpen }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        for w in all { w.resume() }
    }
}

/// The preview client with the calls a test cares about replaced.
struct ScriptedClient: CobaltClient {
    var base: any CobaltClient
    var sessionHook: (@Sendable (String, Int) async throws -> StudioSession)?
    var renderHook: (@Sendable (String, RenderRequest) async throws -> String)?
    var renderStatusHook: (@Sendable (String, String, Int) async throws -> RenderStatus)?
    var publishSessionHook: (@Sendable (String) async throws -> HostedFile)?
    var resolveHook: (@Sendable (URL) async throws -> CobaltResult)?
    var downloadHook: (@Sendable (RemoteFile, URL) async throws -> URL)?
    var downloadProgressHook: (@Sendable (RemoteFile, URL, @escaping @Sendable (TransferProgress) -> Void) async throws -> URL)?
    var publishItemHook: (@Sendable (String) async throws -> HostedFile)?
    var startTokenHook: (@Sendable (String, LiveEnvironment) async throws -> Void)?
    var runHook: (@Sendable (LiveRunRegistration) async throws -> LiveRunReply)?
    var relayHook: (@Sendable (UUID, LiveContentState) async throws -> Void)?
    var endHook: (@Sendable (UUID) async throws -> Void)?
    var libraryHook: (@Sendable () async throws -> LibraryPage)?
    var openStudioHook: (@Sendable (String) async throws -> StudioCreated)?
    var deleteMediaHook: (@Sendable (String) async throws -> Void)?
    var deletePostHook: (@Sendable (String) async throws -> PostDeleteResult)?
    var setNotifyHook: (@Sendable (String, NotifyOptIn) async throws -> Void)?
    var cancelNotifyHook: (@Sendable (String) async throws -> Void)?

    var baseURL: URL { base.baseURL }
    func capabilities() async -> Capabilities { await base.capabilities() }
    func resolve(_ link: URL) async throws -> CobaltResult {
        if let resolveHook { return try await resolveHook(link) }
        return try await base.resolve(link)
    }
    func createStudio(link: URL) async throws -> StudioCreated { try await base.createStudio(link: link) }
    func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated {
        try await base.createStudio(url: url, options: options)
    }
    func upload(
        file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await base.upload(file: file, name: name, contentType: contentType, progress: progress)
    }
    func session(_ id: String, wait: Int) async throws -> StudioSession {
        if let sessionHook { return try await sessionHook(id, wait) }
        return try await base.session(id, wait: wait)
    }
    func sourceURL(session id: String) -> URL { base.sourceURL(session: id) }
    func render(session id: String, _ request: RenderRequest) async throws -> String {
        if let renderHook { return try await renderHook(id, request) }
        return try await base.render(session: id, request)
    }
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus {
        if let renderStatusHook { return try await renderStatusHook(id, job, wait) }
        return try await base.renderStatus(session: id, job: job, wait: wait)
    }
    func publish(session id: String) async throws -> HostedFile {
        if let publishSessionHook { return try await publishSessionHook(id) }
        return try await base.publish(session: id)
    }
    func publish(item id: String) async throws -> HostedFile {
        if let publishItemHook { return try await publishItemHook(id) }
        return try await base.publish(item: id)
    }
    func openStudio(item id: String) async throws -> StudioCreated {
        if let openStudioHook { return try await openStudioHook(id) }
        return try await base.openStudio(item: id)
    }
    func library(cursor: String?, limit: Int) async throws -> LibraryPage {
        if let libraryHook { return try await libraryHook() }
        return try await base.library(cursor: cursor, limit: limit)
    }
    func deleteMedia(name: String) async throws {
        if let deleteMediaHook { return try await deleteMediaHook(name) }
        try await base.deleteMedia(name: name)
    }
    func deletePost(anchor itemID: String) async throws -> PostDeleteResult {
        if let deletePostHook { return try await deletePostHook(itemID) }
        return try await base.deletePost(anchor: itemID)
    }
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {
        if let startTokenHook { return try await startTokenHook(token, environment) }
        try await base.registerLiveStartToken(token, environment: environment)
    }
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply {
        if let runHook { return try await runHook(r) }
        return try await base.registerLiveRun(r)
    }
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws {
        if let relayHook { return try await relayHook(run, state) }
        try await base.relayLiveState(run: run, state)
    }
    func endLiveRun(_ run: UUID) async throws {
        if let endHook { return try await endHook(run) }
        try await base.endLiveRun(run)
    }
    func liveSelftest() async throws -> LiveSelftest { try await base.liveSelftest() }
    func setNotify(session id: String, _ optIn: NotifyOptIn) async throws {
        if let setNotifyHook { return try await setNotifyHook(id, optIn) }
        try await base.setNotify(session: id, optIn)
    }
    func cancelNotify(session id: String) async throws {
        if let cancelNotifyHook { return try await cancelNotifyHook(id) }
        try await base.cancelNotify(session: id)
    }
    func download(
        _ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        if let downloadProgressHook { return try await downloadProgressHook(file, destination, progress) }
        if let downloadHook { return try await downloadHook(file, destination) }
        return try await base.download(file, to: destination, progress: progress)
    }
}

private func session(_ id: String, _ status: SessionStatus, error: String? = nil) -> StudioSession {
    StudioSession(
        id: id, status: status, link: nil, service: nil, title: status == .ready ? "instagram_Dd7P496wolG" : nil,
        duration: status == .ready ? 14.77 : nil, width: status == .ready ? 720 : nil, height: status == .ready ? 1280 : nil,
        bytes: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_600_000),
        errorCode: error, renders: [], step: nil, stepBytes: nil, stepTotal: nil, waking: nil)
}

@MainActor
private func pump(_ h: Harness, rounds: Int = 60) async {
    for _ in 0..<rounds {
        await h.settle()
        h.clock.advance()
    }
    await h.settle()
}

@MainActor
private func isRendering(_ p: Pipeline) -> Bool {
    if case .rendering = p.state { return true }
    return false
}

// MARK: - 1. Polling is paced

@MainActor
@Suite(.serialized)
struct PollPacingTests {
    @Test func thirtyImmediateSavingRepliesTakeAtLeastTheBackoffSchedule() async throws {
        let h = Harness(.happy)
        let starts = Log<Double>()
        let clock = h.clock
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in
            let n = starts.add(clock.elapsed)
            return session(id, n >= 30 ? .ready : .saving)            // "saving" at once, every time
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.drive(until: { h.isTerminalOrReady() }, maxVirtualSeconds: 1_000)
        #expect(h.pipeline.state == .ready)

        let t = starts.all
        #expect(t.count == 30)
        let gaps = zip(t.dropFirst(), t).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 1 - 1e-9 }, "polls started less than 1 s apart: \(gaps)")
        #expect(gaps == [1, 2, 4, 8] + Array(repeating: 10, count: 25), "\(gaps)")
        #expect(t.last! - t.first! >= 265)                           // 1 + 2 + 4 + 8 + 25 × 10
    }

    @Test func aChangingReplyKeepsTheOneSecondPace() async throws {
        let h = Harness(.happy)
        let starts = Log<Double>()
        let clock = h.clock
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in
            let n = starts.add(clock.elapsed)
            var s = session(id, n >= 12 ? .ready : .saving)
            s.step = .storing
            s.stepBytes = Int64(n) * 1_000                           // moves every time
            s.stepTotal = 100_000
            return s
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.drive(until: { h.isTerminalOrReady() }, maxVirtualSeconds: 1_000)
        let gaps = zip(starts.all.dropFirst(), starts.all).map { $0 - $1 }
        #expect(starts.count == 12 && gaps.allSatisfy { abs($0 - 1) < 1e-9 }, "\(gaps)")
    }

    @Test func aLongPollThatWaitedIsNeverBackedOff() async throws {
        // The healthy server: every reply is held for the whole `wait`. Nothing to slow down.
        let h = Harness(.happy)
        let starts = Log<Double>()
        let clock = h.clock
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, wait in
            let n = starts.add(clock.elapsed)
            if n < 8 { try await clock.sleep(seconds: Double(wait)) }
            return session(id, n >= 8 ? .ready : .saving)
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.drive(until: { h.isTerminalOrReady() }, maxVirtualSeconds: 1_000)
        let gaps = zip(starts.all.dropFirst(), starts.all).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 1) < 1e-9 }, "\(gaps)")
    }
}

// MARK: - 2. The upload poll belongs to its run

@MainActor
@Suite(.serialized)
struct UploadPollOwnershipTests {
    @Test func aReplacedUploadRunNeverWritesIntoTheNextOne() async throws {
        let h = Harness(.happy)
        let gate = Gate()
        let polls = Log<Int>()
        let clock = h.clock
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in
            polls.add(1)
            // a long poll that honours cancellation, until the "server" is ready
            while !(await gate.opened) { try await clock.sleep(seconds: 1) }
            return session(id, .ready)
        }
        h.ctx.client = stub
        let p = h.pipeline
        p.start(file: try makeTempFile("clip.mov"))
        await h.drive(until: { p.frames.compactMap { $0 }.count == Pipeline.frameCount && polls.count >= 1 })
        #expect(p.sessionID != nil)

        p.reset()                                                    // the owner starts something else
        await gate.open()
        await pump(h)
        #expect(p.state == .idle && p.media == nil && p.sessionID == nil, "stale poll wrote into the new run: \(String(describing: p.media))")
    }
}

// MARK: - 3. A key belongs to its server

@MainActor
@Suite(.serialized)
struct KeyBindingTests {
    private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
    private let link = URL(string: pastedLink)!

    private func settings(keychain: Keychain = .memory()) -> Settings {
        Settings(defaults: UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!, keychain: keychain)
    }

    /// Mirrors `AppModel.live`'s factory: the client's key is looked up for its own server.
    private func client(_ s: Settings, recorder: Log<URLRequest>) -> HTTPCobaltClient {
        let server = s.serverURL
        let keychain = s.keychain
        for host in ["api.capybaraharmony.com", "other.example"] {
            StubProtocol.install(host: host) { request in
                recorder.add(request)
                return (200, ["content-type": "application/json"], Data(#"{"status":"error","error":{"code":"error.api.generic"}}"#.utf8))
            }
        }
        return HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) }, session: StubProtocol.session())
    }

    @Test func pastingAnotherInstanceNeverSendsTheOwnersKeyThere() async throws {
        let s = settings()
        try s.setAPIKey(pasted: key)
        #expect(s.hasAPIKey && s.apiKey() == key)

        let home = Log<URLRequest>()
        _ = try? await client(s, recorder: home).resolve(link)
        #expect(home.all.last?.value(forHTTPHeaderField: "Authorization") == "Api-Key \(key)")

        try s.setServer(pasted: "https://other.example/some/path")
        #expect(!s.hasAPIKey && s.apiKey() == nil)
        let foreign = Log<URLRequest>()
        let c = client(s, recorder: foreign)
        _ = try? await c.resolve(link)                               // optional key: nothing to attach
        #expect(foreign.count == 1 && foreign.all[0].value(forHTTPHeaderField: "Authorization") == nil)
        await #expect(throws: CobaltError.noAPIKey) { _ = try await c.createStudio(link: link) }   // keyed route: refused before any request
        await #expect(throws: CobaltError.noAPIKey) { _ = try await c.library(cursor: nil, limit: 10) }
        #expect(foreign.count == 1)
        _ = await c.capabilities()                                   // the probes carry no key either
        #expect(foreign.all.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        // the key was kept, and counts again when the original server is back
        s.resetServer()
        #expect(s.hasAPIKey && s.apiKey() == key)
        let back = Log<URLRequest>()
        _ = try? await client(s, recorder: back).resolve(link)
        #expect(back.all.last?.value(forHTTPHeaderField: "Authorization") == "Api-Key \(key)")
    }

    @Test func aKeyPastedForAnotherServerBelongsToThatServerOnly() throws {
        let s = settings()
        try s.setServer(pasted: "https://other.example:8443")
        try s.setAPIKey(pasted: key)
        #expect(s.hasAPIKey)
        try s.setServer(pasted: "https://other.example")             // same host, other port: another service
        #expect(!s.hasAPIKey)
        try s.setServer(pasted: "https://OTHER.example:8443")        // host names do not care about case
        #expect(s.hasAPIKey)
        s.resetServer()
        #expect(!s.hasAPIKey && s.apiKey() == nil)
        s.clearAPIKey()
        try s.setServer(pasted: "https://other.example:8443")
        #expect(!s.hasAPIKey)                                        // cleared for good
    }

    @Test func aKeySavedByAnEarlierBuildBelongsToTheDefaultServer() throws {
        let keychain = Keychain.memory()
        try keychain.set(key, for: "api-key")                        // no host record: the old layout
        let s = settings(keychain: keychain)
        #expect(s.hasAPIKey && s.apiKey() == key)
        try s.setServer(pasted: "https://other.example")
        #expect(!s.hasAPIKey && s.apiKey() == nil)
        // and a Settings opened later (the share extension) agrees
        let extensionSide = Settings(defaults: s.defaults, keychain: keychain)
        #expect(!extensionSide.hasAPIKey && extensionSide.serverURL.host == "other.example")
    }
}

// MARK: - 4. Failure phase

@MainActor
@Suite(.serialized)
struct FailurePhaseTests {
    @Test func theCodeMapCarriesThePhase() {
        #expect(!mapFailure(code: "error.studio.save_lost", during: .saving).keepsTrim)
        #expect(mapFailure(code: "error.studio.save_lost", during: .rendering) == .renderLost && PipelineFailure.renderLost.keepsTrim)
        #expect(!mapFailure(code: "error.something.new", during: .saving).keepsTrim)
        #expect(mapFailure(code: "error.webp.encode_failed", during: .rendering).keepsTrim)
        #expect(pipelineFailure(from: CobaltError.invalidResponse(httpStatus: 500), during: .rendering)?.keepsTrim == true)
        #expect(pipelineFailure(from: CobaltError.invalidResponse(httpStatus: 500), during: .saving)?.keepsTrim == false)
        #expect(!PipelineFailure.fetchFailed(code: "x").keepsTrim && !PipelineFailure.unreachable.keepsTrim)
    }

    @Test func aSaveLostWhileSavingOffersNoMakeItAgain() async throws {
        let h = Harness(.happy)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in session(id, .error, error: "error.studio.save_lost") }
        h.ctx.client = stub
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .failed(.server(code: "error.studio.save_lost")))
        guard case .failed(let f) = p.state else { return }
        #expect(!f.keepsTrim)
        p.makeWebp()
        #expect(p.state == .failed(f))                               // nothing to make again
    }

    @Test func aServerErrorWhileRenderingKeepsTheTrim() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.renderStatusHook = { _, _, _ in .failed(code: "error.webp.encode_failed") }
        h.ctx.client = stub
        p.makeWebp()
        await h.driveToSettled()
        guard case .failed(let f) = p.state else { Issue.record("expected a failure, got \(p.state)"); return }
        #expect(f == .server(code: "render.error.webp.encode_failed") && f.keepsTrim)
        p.makeWebp()                                                 // "make it again" is offered, and works
        #expect(isRendering(p))
    }
}

// MARK: - 5. Retries

@MainActor
@Suite(.serialized)
struct RetryTests {
    @Test func aGatewayThatIsBrieflyDownIsRetriedWhilePolling() async throws {
        let h = Harness(.happy)
        let calls = Log<Int>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in
            let n = calls.add(1)
            switch n {
            case 1: throw CobaltError.invalidResponse(httpStatus: 502)
            case 2: throw CobaltError.api(code: "error.studio.unavailable", httpStatus: 503)
            case 3: throw CobaltError.invalidResponse(httpStatus: 504)
            default: break
            }
            return session(id, .ready)
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready && calls.count == 4)
        #expect(h.clock.elapsed >= 3)                                // 3 × 1 s between the tries
    }

    @Test func theBudgetIsFiveRetriesThenTheRunFails() async throws {
        let h = Harness(.happy)
        let calls = Log<Int>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { _, _ in calls.add(1); throw CobaltError.invalidResponse(httpStatus: 503) }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.server(code: "http.503")) && calls.count == 6)
    }

    @Test func otherStatusesAreNotRetried() async throws {
        #expect(Pipeline.isTransient(.invalidResponse(httpStatus: 502)) && Pipeline.isTransient(.api(code: "x", httpStatus: 504)))
        #expect(Pipeline.isTransient(.network(.timedOut)))
        #expect(!Pipeline.isTransient(.network(.cancelled)) && !Pipeline.isTransient(.invalidResponse(httpStatus: 500)))
        #expect(!Pipeline.isTransient(.api(code: "error.studio.not_found", httpStatus: 404)) && !Pipeline.isTransient(.noAPIKey))
    }

    @Test func thePostThatStartsARenderIsNeverRetried() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        let posts = Log<Int>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.renderHook = { _, _ in posts.add(1); throw CobaltError.invalidResponse(httpStatus: 503) }
        h.ctx.client = stub
        p.makeWebp()
        await h.driveToSettled()
        #expect(posts.count == 1)
        #expect(p.state == .failed(.server(code: "render.http.503")))
    }
}

// MARK: - 6, 11. Handoffs

@MainActor
@Suite(.serialized)
struct HandoffTests {
    private func handoff(_ h: Harness, age: TimeInterval = 0, session: String = "elsewhere") -> SharedJob {
        let job = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: session, media: nil, trim: nil,
            stage: .ready, wantsTrim: true, pickedUp: false, updatedAt: h.clock.now().addingTimeInterval(-age))
        h.app.jobs.upsert(job)
        return job
    }

    private func url(_ job: SharedJob) -> URL { URL(string: "cobalt-apple://job/\(job.id.uuidString)")! }

    @Test func aHandoffNeverCancelsARunningRender() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        p.makeWebp()
        #expect(isRendering(p))
        let own = p.sessionID
        let job = handoff(h)

        h.app.open(url(job))
        #expect(isRendering(p) && p.sessionID == own)
        #expect(h.app.jobs.all().first { $0.id == job.id }?.pickedUp == false)       // left for later
        await h.app.pickUpSharedJobs()
        #expect(isRendering(p) && p.sessionID == own)

        await h.driveToSettled()
        guard case .done = p.state else { Issue.record("the render should have finished, got \(p.state)"); return }
    }

    @Test func foregroundingNeverReplacesAResultButOpeningTheJobLinkDoes() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        p.makeWebp()
        await h.driveToSettled()
        guard case .done(let result) = p.state else { Issue.record("expected .done, got \(p.state)"); return }
        let job = handoff(h)

        await h.app.pickUpSharedJobs()                               // foregrounding
        #expect(p.state == .done(result) && p.sessionID != "elsewhere")
        #expect(h.app.jobs.all().first { $0.id == job.id }?.pickedUp == false)

        h.app.open(url(job))                                         // the owner tapped the notification
        #expect(p.sessionID == "elsewhere")
        #expect(h.app.jobs.all().first { $0.id == job.id }?.pickedUp == true)
    }

    @Test func aFailureOrAnIdleScreenTakesAFreshHandoff() async throws {
        let h = Harness(.happy)
        let job = handoff(h, age: 60)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.sessionID == "elsewhere")
        #expect(h.app.jobs.all().first { $0.id == job.id }?.pickedUp == true)
    }

    @Test func aHandoffOlderThanThirtyMinutesIsIgnored() async throws {
        let h = Harness(.happy)
        let stale = handoff(h, age: SharedJobStore.handoffMaxAge + 60)
        #expect(h.app.jobs.nextHandoff(now: h.clock.now()) == nil)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.state == .idle && h.pipeline.sessionID == nil)
        #expect(h.app.jobs.all().first { $0.id == stale.id }?.pickedUp == false)

        let fresh = handoff(h, age: SharedJobStore.handoffMaxAge - 60, session: "fresh")
        #expect(h.app.jobs.nextHandoff(now: h.clock.now())?.id == fresh.id)
        // the age is the writer's `updatedAt`, measured against the caller's now
        #expect(h.app.jobs.nextHandoff(now: h.clock.now().addingTimeInterval(120)) == nil)
        // the notification's own link still opens an old one
        h.app.open(url(stale))
        #expect(h.pipeline.sessionID == "elsewhere")
    }
}

// MARK: - 7. Swiping the sheet away

@MainActor
@Suite(.serialized)
struct ShareDismissTests {
    @Test func theCoreSaysWhenClosingHasWorkToSave() async throws {
        let h = Harness(.shortClip)
        let pipeline = Pipeline(context: h.ctx)
        let core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: FakeNotifier())
        #expect(!core.isRendering)
        pipeline.start(link: URL(string: shortLink)!)
        #expect(!core.isRendering)                                   // fetching: swiping away just stops
        await h.drive(until: { pipeline.state == .ready })
        #expect(!core.isRendering)
        pipeline.makeWebp()
        #expect(core.isRendering)                                    // the controller makes the sheet modal now
        await h.drive(until: { if case .done = pipeline.state { return true } else { return false } })
        #expect(!core.isRendering)                                   // and lets go again
    }
}

// MARK: - 8. Progress throttle

@MainActor
@Suite(.serialized)
struct ProgressThrottleTests {
    @Test func aThousandCallbacksInASecondDeliverAboutTen() {
        let clockTime = Mutex(0.0)
        let seen = Log<TransferProgress>()
        let throttle = ProgressThrottle(now: { clockTime.withLock { $0 } }) { seen.add($0) }
        for i in 0..<1_000 {
            clockTime.withLock { $0 = Double(i) / 1_000 }
            throttle.send(TransferProgress(bytes: Int64(i), total: nil))
        }
        #expect(seen.count >= 9 && seen.count <= 11, "delivered \(seen.count)")
        throttle.flush()                                             // the last one held back still goes out
        #expect(seen.all.last?.bytes == 999)
    }

    @Test func theFinalValueIsAlwaysDelivered() {
        let clockTime = Mutex(0.0)
        let seen = Log<TransferProgress>()
        let throttle = ProgressThrottle(now: { clockTime.withLock { $0 } }) { seen.add($0) }
        throttle.send(TransferProgress(bytes: 0, total: 100))
        throttle.send(TransferProgress(bytes: 50, total: 100))       // 0 ms later: held
        throttle.send(TransferProgress(bytes: 100, total: 100))      // 0 ms later but complete: delivered
        #expect(seen.all.map(\.bytes) == [0, 100])
        throttle.flush()
        #expect(seen.count == 2)                                     // nothing left to flush after the final value
    }

    @Test func theRelayHopsToTheMainActorOnceAndAppliesTheLastValue() async throws {
        let applied = Log<Int>()
        let relay = MainActorRelay<Int> { applied.add($0) }
        for i in 0..<1_000 { relay.push(i) }                         // synchronously, before the main actor can run
        try await Task.sleep(for: .milliseconds(50))
        #expect(applied.all.last == 999 && applied.count <= 2, "applied \(applied.count) times")
        relay.push(1_000)
        try await Task.sleep(for: .milliseconds(50))
        #expect(applied.all.last == 1_000)
    }

    @Test func aRealDownloadThrottlesAndStillEndsOnTheTotal() async throws {
        let payload = Data(repeating: 9, count: 6_000_000)
        let server = try await LoopbackServer.start { _ in
            .init(status: 200, headers: ["content-type": "video/mp4"], body: payload)
        }
        defer { server.stop() }
        let c = HTTPCobaltClient(baseURL: server.base, apiKey: { nil })
        let seen = Log<TransferProgress>()
        let started = ProcessInfo.processInfo.systemUptime
        _ = try await c.download(.open(server.base.appendingPathComponent("tunnel")), to: try makeTempDirectory().appendingPathComponent("a.mp4")) { seen.add($0) }
        let seconds = max(0.1, ProcessInfo.processInfo.systemUptime - started)
        #expect(seen.all.last == TransferProgress(bytes: 6_000_000, total: 6_000_000))
        #expect(Double(seen.count) <= seconds * 10 + 3, "\(seen.count) callbacks in \(seconds) s")
    }
}

// MARK: - 9. File names

@MainActor
@Suite(.serialized)
struct FileNameTests {
    @Test func hostileNamesBecomePlainComponents() {
        #expect(SafeFileName.clean("..") == nil && SafeFileName.clean(".") == nil && SafeFileName.clean("") == nil)
        #expect(SafeFileName.clean("...") == nil && SafeFileName.clean("  ") == nil && SafeFileName.clean("\u{7}\u{1B}") == nil && SafeFileName.clean("\u{0}") == "_")
        #expect(SafeFileName.clean("a/b\\c:d.mp4") == "a_b_c_d.mp4")
        #expect(SafeFileName.clean("../../etc/passwd") == "_._.._etc_passwd")
        #expect(SafeFileName.clean("clip\n\u{1B}[2J.mp4") == "clip[2J.mp4")
        #expect(SafeFileName.clean("invoice\u{202E}4pm.exe") == "invoice4pm.exe")
        #expect(SafeFileName.clean(".hidden.mp4") == "_hidden.mp4")
        #expect(SafeFileName.clean("café 🎬.mp4") == "café 🎬.mp4")
        let long = String(repeating: "a", count: 500) + ".mp4"
        let capped = SafeFileName.clean(long)
        #expect(capped?.count == SafeFileName.maxLength && capped?.hasSuffix(".mp4") == true)
        for raw in ["a", "..", "../x", "x/..", String(repeating: "é", count: 300)] {
            let name = SafeFileName.clean(raw, fallback: "file")
            #expect(name != "." && name != ".." && !name.contains("/") && name.utf8.count <= 255)
        }
    }

    @Test func theInboxNeverResolvesOutsideItsFolder() throws {
        let store = OfflineStore(root: try makeTempDirectory(), tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
        let inbox = store.root.appendingPathComponent("inbox", isDirectory: true).standardizedFileURL
        for raw in ["..", ".", "", "../..", "a/../../b", "/", "...", "\u{0}", "x/../..", String(repeating: "z", count: 1_000)] {
            let url = store.inboxURL(for: raw)
            let dir = url.deletingLastPathComponent().standardizedFileURL
            #expect(url.lastPathComponent != ".." && url.lastPathComponent != "." && !url.lastPathComponent.isEmpty, "\(raw)")
            #expect(dir.deletingLastPathComponent().path == inbox.path, "\(raw) -> \(url.path)")      // inbox/<8 chars>/<name>
            #expect(url.standardizedFileURL.path.hasPrefix(dir.path + "/"))
        }
    }

    @Test func aDownloadNeverRemovesADirectory() async throws {
        StubProtocol.install(host: "files.example") { _ in (200, ["content-type": "video/mp4"], Data(repeating: 1, count: 100)) }
        let c = HTTPCobaltClient(baseURL: URL(string: "https://files.example")!, apiKey: { nil }, session: StubProtocol.session())
        let dir = try makeTempDirectory()
        let keep = dir.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: keep)
        await #expect(throws: (any Error).self) {
            _ = try await c.download(.open(URL(string: "https://files.example/tunnel")!), to: dir, progress: { _ in })
        }
        #expect(FileManager.default.fileExists(atPath: dir.path) && FileManager.default.fileExists(atPath: keep.path))

        let file = dir.appendingPathComponent("a.mp4")                // a plain file of that name is replaced, as before
        try Data("old".utf8).write(to: file)
        let saved = try await c.download(.open(URL(string: "https://files.example/tunnel")!), to: file, progress: { _ in })
        #expect(try Data(contentsOf: saved).count == 100)
    }

    @Test func aServerFilenameOfDotDotNeverReachesTheFileSystem() async throws {
        let h = Harness(.plainCobalt)
        let destinations = Log<URL>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.resolveHook = { _ in .file(url: URL(string: "https://tunnel.example/x")!, filename: "..") }
        stub.downloadHook = { _, dest in
            destinations.add(dest)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PreviewMedia.placeholderBytes.write(to: dest)
            return dest
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        let dest = try #require(destinations.all.first)
        let inbox = h.ctx.store.root.appendingPathComponent("inbox", isDirectory: true).standardizedFileURL
        #expect(dest.lastPathComponent != ".." && dest.lastPathComponent == "instagram_Dd7P496wolG.mp4")
        #expect(dest.deletingLastPathComponent().standardizedFileURL.deletingLastPathComponent().path == inbox.path)
        #expect(FileManager.default.fileExists(atPath: inbox.path))
        if case .savedLocally(let video) = h.pipeline.state { #expect(video.name == "instagram_Dd7P496wolG") }
        else { Issue.record("expected .savedLocally, got \(h.pipeline.state)") }
    }

    @Test func aSharedMovieNamedDotDotKeepsItsExtensionOnly() {
        let temp = URL(fileURLWithPath: "/tmp/QuickTime movie.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: "..") == "QuickTime movie.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: "../../x") == "_._.._x.mov")
    }
}

// MARK: - 10. Stale runs never touch the clipboard

@MainActor
@Suite(.serialized)
struct StaleRunTests {
    @Test func aHostFinishingAfterTheRunWasReplacedChangesNothing() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        let gate = Gate()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.publishSessionHook = { _ in
            await gate.wait()                                        // a request already on the wire: cancellation does not stop it
            return HostedFile(url: URL(string: "https://media.capybaraharmony.com/stale.mp4")!, bytes: 1, contentType: "video/mp4", itemID: nil)
        }
        h.ctx.client = stub
        p.hostOriginal()
        while await gate.waiting == 0 { await h.settle(); h.clock.advance() }
        #expect(p.hosting == .working)

        p.reset()
        await gate.open()
        await pump(h, rounds: 20)
        #expect(h.clipboard.copies.isEmpty, "a stale run copied to the clipboard: \(h.clipboard.copies)")
        #expect(p.hostedURL == nil && p.hosting == .idle && p.state == .idle)
    }

    @Test func theOriginalFinishedAfterTheRunWasReplacedIsNotAttachedToTheNewRun() async throws {
        let h = Harness(.happy)
        let gate = Gate()
        // a store whose poster step parks: `add` is in flight while the run is replaced
        struct GatedTools: MediaTools {
            var base: any MediaTools
            var gate: Gate
            func probe(file: URL) async -> MediaInfo? { await base.probe(file: file) }
            func imageInfo(file: URL) -> MediaInfo? { base.imageInfo(file: file) }
            func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
                base.frames(of: input, duration: duration, count: count)
            }
            func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
                await gate.wait()
                return false
            }
        }
        let tools = GatedTools(base: h.ctx.tools, gate: gate)
        let store = OfflineStore(root: try makeTempDirectory(), tools: tools)
        let ctx = PipelineContext(
            client: h.ctx.client, capabilities: h.ctx.capabilities, settings: h.ctx.settings, store: store, jobs: h.ctx.jobs,
            tools: tools, clock: h.clock, photos: h.ctx.photos, clipboard: h.ctx.clipboard, intake: h.ctx.intake, isPreview: false)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: pastedLink)!)
        var spins = 0
        while await gate.waiting == 0, spins < 400 { await h.settle(); h.clock.advance(); spins += 1 }
        #expect(await gate.waiting == 1, "the original never reached the store")

        p.reset()
        await gate.open()
        await pump(h, rounds: 20)
        #expect(p.stored == nil && p.state == .idle)
    }
}

// MARK: - Notification permission is asked in context

@MainActor
@Suite(.serialized)
struct NotificationPermissionTests {
    /// Waits (in real milliseconds) for the one-shot `Task` the context spawns.
    private func settleRequests(_ notifier: FakeNotifier, expecting n: Int) async {
        for _ in 0..<200 where notifier.authorizationRequests < n { try? await Task.sleep(for: .milliseconds(2)) }
        try? await Task.sleep(for: .milliseconds(10))
    }

    @Test func launchAndPlainRunsNeverAsk() async throws {
        let h = Harness(.happy)
        let notifier = FakeNotifier()
        h.ctx.notifier = notifier
        // everything the app does at launch and on foregrounding
        await h.app.refreshServer()
        await h.app.pickUpSharedJobs()
        h.app.open(URL(string: "cobalt-apple://open")!)
        h.pipeline.start(pastedText: "no link in here")              // not a run
        h.pipeline.start(link: URL(string: pastedLink)!)             // a first run, over the focus card
        await h.driveToSettled()
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        h.pipeline.reset()                                           // closing a run with nothing in flight
        await settleRequests(notifier, expecting: 1)
        #expect(notifier.authorizationRequests == 0)
    }

    @Test func aPickedFileIsNotAReasonEither() async throws {
        let h = Harness(.happy)
        let notifier = FakeNotifier()
        h.ctx.notifier = notifier
        h.pipeline.start(file: try makeTempFile("clip.mov"))
        await settleRequests(notifier, expecting: 1)
        #expect(notifier.authorizationRequests == 0)
    }

    @Test func closingARunWithWorkInFlightAsksOnceAndOnlyThen() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady(keeping: false)
        p.detach()                                                   // ready, nothing in flight: a plain reset
        await settleRequests(r.notifier, expecting: 1)
        #expect(r.notifier.authorizationRequests == 0)

        await r.toReady()
        p.makeWebp()
        await r.drive { p.renderJobID != nil }
        p.detach()                                                   // a render outlives the screen
        await settleRequests(r.notifier, expecting: 1)
        #expect(r.notifier.authorizationRequests == 1)
        await r.drive { r.ctx.background.isEmpty }

        await r.toReady()
        p.makeWebp()
        await r.drive { p.renderJobID != nil }
        p.detach()                                                   // the system asks once; so do we
        await settleRequests(r.notifier, expecting: 2)
        #expect(r.notifier.authorizationRequests == 1)
        await r.drive { r.ctx.background.isEmpty }
    }

    @Test func theShareSheetAsksOnlyWhenItClosesMidRender() async throws {
        let h = Harness(.shortClip)
        let notifier = FakeNotifier()
        let pipeline = Pipeline(context: h.ctx)
        let core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: notifier)
        pipeline.start(link: URL(string: shortLink)!)                // opening and running the sheet is not a reason
        await h.drive(until: { pipeline.state == .ready })
        await settleRequests(notifier, expecting: 1)
        #expect(notifier.authorizationRequests == 0)

        pipeline.makeWebp()
        await h.drive(until: { pipeline.renderJobID != nil })
        #expect(await core.close() == .continuesInBackground)
        #expect(notifier.authorizationRequests == 1)
        #expect(notifier.posts.map(\.kind) == [.stillMaking])
    }

    @Test func theShareSheetClosingAnywhereElseNeverAsks() async throws {
        let h = Harness(.shortClip)
        let notifier = FakeNotifier()
        let pipeline = Pipeline(context: h.ctx)
        let core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: notifier)
        pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { pipeline.state == .ready })
        #expect(await core.close() == .dismissed)
        #expect(notifier.authorizationRequests == 0)
    }

    /// `AppModel.live()` needs the real stores and notification center, so it cannot run here: pin
    /// the one thing it must not do (the old launch-time prompt) at the source.
    @Test func theLiveLaunchPathNeverRequestsAuthorization() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CobaltKit/Models/AppModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("requestAuthorization"), "AppModel must not ask for notification permission at launch")
        #expect(text.contains("ctx.notifier = SystemNotifier()"))
    }
}
