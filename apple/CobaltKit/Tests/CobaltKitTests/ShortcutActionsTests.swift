import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The Shortcuts actions (CONTRACT-PARALLEL.md section 15, tests 15.7): link parsing, options, the errors that queue
// nothing, partial acceptance, `stillLocal`, `via: .shortcut` never focused, the line notify rule, wait-until-saved,
// uploads, Make webp (clamps, size, an expired session reopened, the stop paths) and the entity lookups. All on the
// preview server and a virtual clock.

// MARK: - Support

/// What the preview "server" created, for a library that lists exactly those saves.
final class CreatedSaves: Sendable {
    private let list = Mutex<[(id: String, link: URL?)]>([])
    func add(_ id: String, link: URL?) { list.withLock { $0.append((id, link)) } }
    var all: [(id: String, link: URL?)] { list.withLock { $0 } }
}

/// Library reads and session reads, counted.
final class ReadLog: Sendable {
    private let state = Mutex((library: 0, sessions: [String]()))
    func library() { state.withLock { $0.library += 1 } }
    func session(_ id: String) { state.withLock { $0.sessions.append(id) } }
    var libraryCalls: Int { state.withLock { $0.library } }
    var sessionCalls: [String] { state.withLock { $0.sessions } }
}

/// The renders asked for, in order.
final class RenderLog: Sendable {
    private let list = Mutex<[(session: String, request: RenderRequest)]>([])
    func add(_ session: String, _ request: RenderRequest) { list.withLock { $0.append((session, request)) } }
    var all: [(session: String, request: RenderRequest)] { list.withLock { $0 } }
}

/// The preview client with the calls a test cares about replaced, and every call the queue and the line need forwarded
/// (`ScriptedClient` forwards `createStudio(link:)` only, which would hide `queue: true`).
struct ForwardingClient: CobaltClient {
    var base: PreviewClient
    var capsHook: (@Sendable (inout Capabilities) -> Void)?
    var createHook: (@Sendable (URL) throws -> Void)?
    var libraryHook: (@Sendable () -> LibraryPage)?
    var created = CreatedSaves()
    var renders = RenderLog()
    var reads = ReadLog()

    var baseURL: URL { base.baseURL }
    func capabilities() async -> Capabilities {
        var caps = await base.capabilities()
        capsHook?(&caps)
        return caps
    }
    func resolve(_ link: URL) async throws -> CobaltResult { try await base.resolve(link) }
    func createStudio(link: URL) async throws -> StudioCreated { try await createStudio(link: link, public: nil, queue: false, title: nil) }
    func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated {
        try await createStudio(link: link, public: makePublic, queue: false, title: nil)
    }
    func createStudio(link: URL, public makePublic: Bool?, queue: Bool, title: String?) async throws -> StudioCreated {
        try createHook?(link)
        let made = try await base.createStudio(link: link, public: makePublic, queue: queue, title: title)
        created.add(made.id, link: link)
        return made
    }
    func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult {
        try await base.upload(file: file, name: name, contentType: contentType, progress: progress)
    }
    func upload(file: URL, name: String, contentType: String, public makePublic: Bool?, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult {
        try await base.upload(file: file, name: name, contentType: contentType, public: makePublic, progress: progress)
    }
    func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?, queue: Bool, title: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await base.upload(file: file, name: name, contentType: contentType, public: makePublic, queue: queue, title: title, progress: progress)
    }
    func session(_ id: String, wait: Int) async throws -> StudioSession {
        reads.session(id)
        return try await base.session(id, wait: wait)
    }
    func sourceURL(session id: String) -> URL { base.sourceURL(session: id) }
    func render(session id: String, _ request: RenderRequest) async throws -> String {
        renders.add(id, request)
        return try await base.render(session: id, request)
    }
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus {
        try await base.renderStatus(session: id, job: job, wait: wait)
    }
    func publish(session id: String) async throws -> HostedFile { try await base.publish(session: id) }
    func publish(item id: String) async throws -> HostedFile { try await base.publish(item: id) }
    func openStudio(item id: String) async throws -> StudioCreated { try await base.openStudio(item: id) }
    func openStudio(item id: String, queue: Bool) async throws -> StudioCreated { try await base.openStudio(item: id, queue: queue) }
    func library(cursor: String?, limit: Int) async throws -> LibraryPage { try await library(cursor: cursor, limit: limit, v2: false) }
    func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage {
        reads.library()
        if let libraryHook { return libraryHook() }
        return try await base.library(cursor: cursor, limit: limit, v2: v2)
    }
    func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange {
        try await base.setVisibility(item: id, public: makePublic)
    }
    func cancelQueued(session id: String) async throws -> QueueCancel { try await base.cancelQueued(session: id) }
    func cancelQueued(session id: String, job: String) async throws -> QueueCancel { try await base.cancelQueued(session: id, job: job) }
    func line() async throws -> ServerLineSnapshot { try await base.line() }
    func setLineNotify() async throws -> Int { try await base.setLineNotify() }
    func cancelLineNotify() async throws { try await base.cancelLineNotify() }
    func deleteMedia(name: String) async throws { try await base.deleteMedia(name: name) }
    func deletePost(anchor itemID: String) async throws -> PostDeleteResult { try await base.deletePost(anchor: itemID) }
    func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { try await base.setTitle(anchor: itemID, title) }
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { try await base.registerLiveRun(r) }
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
    func endLiveRun(_ run: UUID) async throws {}
    func liveSelftest() async throws -> LiveSelftest { try await base.liveSelftest() }
    func setNotify(session id: String, _ optIn: NotifyOptIn) async throws { try await base.setNotify(session: id, optIn) }
    func cancelNotify(session id: String) async throws { try await base.cancelNotify(session: id) }
    func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL {
        try await base.download(file, to: destination, progress: progress)
    }
}

@MainActor
final class FakeShortcutClipboard: ShortcutClipboard {
    var value: String?
    func text() -> String? { value }
}

@MainActor
final class ShortcutFakeActivity: AppActivity {
    var isActive = true
}

struct ShortcutTimedOut: Error {}

/// A preview app whose server holds the line, a Shortcuts action set over it, and a virtual clock to drive.
@MainActor
struct ShortcutRig {
    let rig: LineRig
    let base: PreviewClient
    let wrapper: ForwardingClient
    let actions: ShortcutActions
    let clipboard = FakeShortcutClipboard()
    let activity = ShortcutFakeActivity()

    /// `notify`: the server has the Hark bridge. `active`: cobalt is the active app.
    init(_ mode: LinePreviewMode = .server, notify: Bool = true, active: Bool = true, tweak: ((inout ForwardingClient) -> Void)? = nil) {
        let rig = LineRig(mode)
        let base = rig.ctx.client as! PreviewClient
        var wrapper = ForwardingClient(base: base)
        wrapper.capsHook = { caps in if notify { caps.notifyBridge = true } }
        tweak?(&wrapper)
        rig.ctx.client = wrapper
        activity.isActive = active
        rig.ctx.background.activity = activity
        self.rig = rig
        self.base = base
        self.wrapper = wrapper
        self.actions = ShortcutActions(model: rig.app, clipboard: clipboard)
    }

    var queue: JobQueue { rig.queue }
    var ctx: PipelineContext { rig.ctx }
    var server: PreviewServer { base.server }
    var calls: [String] { server.lineCalls }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    /// Runs `operation` while virtual time moves, until it answers (or `maxVirtualSeconds` pass).
    func run<T: Sendable>(
        maxVirtualSeconds: Double = 120, _ operation: @escaping @MainActor () async throws -> T
    ) async -> Result<T, Error> {
        var result: Result<T, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await operation()) } catch { result = .failure(error) }
        }
        await rig.drive(until: { result != nil }, maxVirtualSeconds: maxVirtualSeconds)
        if result == nil { task.cancel(); await rig.drive(until: { result != nil }, maxVirtualSeconds: 5) }
        await task.value
        return result ?? .failure(ShortcutTimedOut())
    }
}

/// A saved video of the library fixture: the post `PrEvIeWsession0000000a1`'s, newest.
private let fixtureLatestVideoPost = "Dd55fEyN1Yy"

/// A library page that lists, as saved posts, what the "server" created (a public hosted copy and a private original).
private func libraryListing(_ created: CreatedSaves, now: Date) -> LibraryPage {
    let posts = created.all.enumerated().map { index, save -> LibraryPost in
        func file(_ id: String, _ kind: LibraryFile.Kind, _ source: LibraryFile.Source, url: String?, type: String, at when: Date) -> LibraryFile {
            LibraryFile(
                id: id, kind: kind, source: source, name: "instagram_\(save.id)", url: url.flatMap(URL.init(string:)),
                contentType: type, bytes: 4_000_000, width: 720, height: 1280, duration: 14.8, createdAt: when,
                mediaName: nil, deletable: false)
        }
        let when = now.addingTimeInterval(Double(index))
        return LibraryPost(
            id: save.id, service: "instagram", link: save.link, title: "instagram_\(save.id)", duration: 14.8, width: 720,
            height: 1280, createdAt: when, session: nil, files: [
                file("\(save.id)-pub", .public, .host, url: "https://media.capybaraharmony.com/\(save.id).mp4", type: "video/mp4", at: when),
                file("\(save.id)-src", .private, .saved, url: nil, type: "video/mp4", at: when.addingTimeInterval(-5)),
            ])
    }
    return LibraryPage(posts: posts, postCount: posts.count, fileCount: posts.count * 2, publicBytes: 0, privateBytes: 0, next: nil)
}

// MARK: - Parsing

@MainActor
struct ShortcutLinkParsingTests {
    private func actions(clipboard: String? = nil) -> (ShortcutActions, FakeShortcutClipboard) {
        let rig = ShortcutRig()
        rig.clipboard.value = clipboard
        return (rig.actions, rig.clipboard)
    }

    @Test func oneURLIsOneLink() throws {
        let (a, _) = actions()
        #expect(try a.resolveLinks(["https://www.instagram.com/reel/Dd7P496wolG/"]) == [linkA])
    }

    @Test func textWithThreeLinksYieldsThree() throws {
        let (a, _) = actions()
        let text = "look at \(linkA.absoluteString), then \(linkB.absoluteString)\n\(linkC.absoluteString)."
        #expect(try a.resolveLinks([text]) == [linkA, linkB, linkC])
    }

    @Test func aListOfStringsIsReadInOrderAndRepeatsAreFoldedAcrossInputs() throws {
        let (a, _) = actions()
        let found = try a.resolveLinks([linkB.absoluteString, "again \(linkB.absoluteString) and \(linkA.absoluteString)", linkB.absoluteString])
        #expect(found == [linkB, linkA])
    }

    @Test func atMostTwentyLinksAreTaken() throws {
        let (a, _) = actions()
        let text = (1...30).map { "https://example.com/post/\($0)" }.joined(separator: " ")
        let found = try a.resolveLinks([text])
        #expect(found.count == 20 && found.first?.lastPathComponent == "1" && found.last?.lastPathComponent == "20")
        // across several inputs too
        let many = (1...30).map { "https://example.com/clip/\($0)" }
        #expect(try a.resolveLinks(many).count == 20)
    }

    @Test func noInputReadsTheClipboard() throws {
        let (a, _) = actions(clipboard: "copied: \(linkC.absoluteString)")
        #expect(try a.resolveLinks([]) == [linkC])
        #expect(try a.resolveLinks(["", "   "]) == [linkC], "blank strings are no input")
    }

    @Test func noLinkIsAnError() {
        let (a, _) = actions(clipboard: nil)
        #expect(throws: ShortcutError.noLink) { try a.resolveLinks([]) }
        #expect(throws: ShortcutError.noLink) { try a.resolveLinks(["just some words, no link"]) }
        // input with no link in it never falls back to the clipboard
        let (b, _) = actions(clipboard: linkA.absoluteString)
        #expect(throws: ShortcutError.noLink) { try b.resolveLinks(["just some words"]) }
    }
}

// MARK: - Save links

@MainActor
struct ShortcutSaveLinksTests {
    @Test func linksGoToTheServersLineAsShortcutJobsAndNeverTakeTheFocus() async throws {
        let t = ShortcutRig(.server)
        let outcome = try await t.run { try await t.actions.saveLinks([linkA.absoluteString, linkB.absoluteString]) }.get()
        #expect(outcome.saves.count == 2 && outcome.failures.isEmpty && outcome.total == 2 && !outcome.isPartial)
        #expect(t.queue.jobs.count == 2 && t.queue.jobs.allSatisfy { $0.via == .shortcut && $0.origin == .shortcut })
        #expect(t.queue.focusedID == nil, "a Shortcut never focuses, even on a quiet screen (5.8)")
        #expect(t.count("POST /") == 0, "no checking the link first: the server resolves it")
        #expect(t.calls.filter { $0.hasPrefix("POST /studio queue=true") }.count == 2)
        // the id is the post key: the session id of a saved link
        #expect(outcome.saves.map(\.id) == t.queue.jobs.compactMap { $0.pipeline.sessionID })
        #expect(outcome.saves[0].service == "instagram" && outcome.saves[0].link == linkA)
    }

    @Test func aSingleLinkOnAQuietScreenIsStillNotFocused() async throws {
        let t = ShortcutRig(.server)
        _ = try await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }.get()
        #expect(t.queue.focusedID == nil && t.queue.jobs.count == 1)
    }

    @Test func aQueuedSaveSaysSoAndHasTheServersAnswerAsItsState() async throws {
        let t = ShortcutRig(.serverBusyWithShare)
        let outcome = try await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }.get()
        #expect(outcome.saves[0].state == .queued, "a share holds the helper: this one waits in the line")
    }

    @Test func theTitleIsUsedWithExactlyOneLink() async throws {
        let one = ShortcutRig(.server)
        let outcome = try await one.run { try await one.actions.saveLinks([linkA.absoluteString], title: "  the good part ") }.get()
        #expect(one.calls.contains("POST /studio queue=true title=the good part"))
        #expect(outcome.saves[0].title == "the good part")

        let many = ShortcutRig(.server)
        _ = try await many.run { try await many.actions.saveLinks([linkA.absoluteString, linkB.absoluteString], title: "ignored") }.get()
        #expect(many.calls.filter { $0.contains("title=ignored") }.isEmpty)
        #expect(many.calls.filter { $0.hasSuffix("title=-") }.count == 2)
    }

    @Test func theVisibilityBecomesThePublicFlag() async throws {
        for (visibility, setting, expected) in [
            (ShortcutVisibility.public, false, "create public"),
            (.private, true, "create -"),
            (.appDefault, true, "create public"),
            (.appDefault, false, "create -"),
        ] {
            let t = ShortcutRig(.server)
            t.rig.app.settings.newSavesPublic = setting
            _ = try await t.run { try await t.actions.saveLinks([linkA.absoluteString], visibility: visibility) }.get()
            #expect(t.base.visibilityState.saves == [expected], "\(visibility) with the setting \(setting)")
        }
        #expect(ShortcutVisibility.public.makePublic == true && ShortcutVisibility.private.makePublic == false)
        #expect(ShortcutVisibility.appDefault.makePublic == nil, "app default follows Settings")
    }

    @Test func theClipboardIsReadWhenNothingIsGiven() async throws {
        let t = ShortcutRig(.server)
        t.clipboard.value = linkB.absoluteString
        let outcome = try await t.run { try await t.actions.saveLinks([]) }.get()
        #expect(outcome.saves.count == 1 && outcome.saves[0].link == linkB)
    }

    // MARK: errors that queue nothing

    @Test func notSignedInQueuesNothing() async {
        let t = ShortcutRig(.server)
        t.ctx.settings.clearAPIKey()
        let result = await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }
        #expect(throws: ShortcutError.notSignedIn) { try result.get() }
        #expect(t.queue.jobs.isEmpty && t.calls.isEmpty)
    }

    @Test func aRefusedKeyQueuesNothing() async {
        let t = ShortcutRig(.server) { $0.capsHook = { $0.key = .invalid } }
        let result = await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }
        #expect(throws: ShortcutError.keyRefused) { try result.get() }
        #expect(t.queue.jobs.isEmpty && t.calls.isEmpty)
    }

    @Test func anUnreachableServerQueuesNothing() async {
        let t = ShortcutRig(.server) { $0.capsHook = { $0 = .unknown } }
        let result = await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }
        #expect(throws: ShortcutError.serverUnreachable) { try result.get() }
        #expect(t.queue.jobs.isEmpty && t.calls.isEmpty)
    }

    @Test func aServerWithNoLineIsRefusedUnlessTheOwnerContinuedInTheForeground() async throws {
        let t = ShortcutRig(.off)
        let refused = await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }
        #expect(throws: ShortcutError.oldServer) { try refused.get() }
        #expect(t.queue.jobs.isEmpty && t.calls.isEmpty, "nothing was added")

        let ready = try await t.run { try await t.actions.prepare() }.get()
        #expect(ready.hasLine == false)
        // the intent asked to continue in the foreground and was not refused: the device's line runs it
        let outcome = try await t.run { try await t.actions.saveLinks([linkA.absoluteString], allowDeviceLine: true) }.get()
        #expect(outcome.saves.count == 1 && t.queue.jobs.count == 1)
        #expect(t.calls.contains("POST /studio queue=false title=-"), "no queue on a server that holds no line")
    }

    @Test func noLinkIsAnErrorAndQueuesNothing() async {
        let t = ShortcutRig(.server)
        let result = await t.run { try await t.actions.saveLinks(["nothing here"]) }
        #expect(throws: ShortcutError.noLink) { try result.get() }
        #expect(t.queue.jobs.isEmpty)
    }

    @Test func aFullLineIsTheLinesWordsWithItsLimit() async {
        let t = ShortcutRig(.serverFull)
        let result = await t.run { try await t.actions.saveLinks([linkA.absoluteString, linkB.absoluteString]) }
        #expect(throws: ShortcutError.lineFull(max: 50)) { try result.get() }
    }

    // MARK: partial and late

    @Test func someLinksFailingKeepsTheOthersAndSaysWhichFailed() async throws {
        let t = ShortcutRig(.server) {
            $0.createHook = { link in
                if link == linkB { throw CobaltError.api(code: "error.studio.line_full", httpStatus: 429) }
            }
        }
        let outcome = try await t.run { try await t.actions.saveLinks([linkA, linkB, linkC].map(\.absoluteString)) }.get()
        #expect(outcome.isPartial && outcome.total == 3)
        #expect(outcome.saves.count == 2 && outcome.saves.map(\.link) == [linkA, linkC])
        #expect(outcome.failures == [ShortcutFailure(label: "x · 2105435404002562056", error: .lineFull(max: 50))])
    }

    @Test func aLinkTheServerHasNotAnsweredForWithinTheTimeoutComesBackQueuedWithNoId() async throws {
        let t = ShortcutRig(.deviceBusy(seconds: 100_000))
        let started = t.rig.clock.elapsed
        let outcome = try await t.run { try await t.actions.saveLinks([linkA.absoluteString], allowDeviceLine: true) }.get()
        let waited = t.rig.clock.elapsed - started
        #expect(waited >= ShortcutActions.acceptTimeout && waited < ShortcutActions.acceptTimeout + 10)
        #expect(outcome.saves.count == 1 && outcome.saves[0].state == .queued)
        #expect(outcome.saves[0].id == t.queue.jobs[0].id.uuidString, "no post key yet: the job's id stands in")
        #expect(t.queue.jobs.count == 1, "the job goes on in the app; the ledger sends it again on the next launch")
    }

    // MARK: the line notify rule (15.2.5)

    @Test func leavingWorkOnTheServerWithTheAppAwayLeavesOneMessageToHark() async throws {
        let t = ShortcutRig(.server, active: false)
        _ = try await t.run { try await t.actions.saveLinks([linkA.absoluteString, linkB.absoluteString]) }.get()
        await t.ctx.notify.settled()
        #expect(t.count("PUT line/notify") == 1, "one summary for both, not one per link")
        #expect(t.server.notifyCalls.isEmpty)
    }

    @Test func nothingIsRegisteredWhileCobaltIsOnScreen() async throws {
        let t = ShortcutRig(.server, active: true)
        _ = try await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }.get()
        await t.ctx.notify.settled()
        #expect(t.count("PUT line/notify") == 0)
    }

    @Test func nothingIsRegisteredWhenTheActionWaitsOrOpensCobalt() async throws {
        for follow in [ShortcutActions.FollowUp.wait, .open] {
            let t = ShortcutRig(.server, active: false)
            _ = try await t.run { try await t.actions.saveLinks([linkA.absoluteString], then: follow) }.get()
            await t.ctx.notify.settled()
            #expect(t.count("PUT line/notify") == 0, "\(follow)")
        }
    }

    @Test func aServerWithoutTheNotifyBridgeSendsNothing() async throws {
        let t = ShortcutRig(.server, notify: false, active: false)
        _ = try await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }.get()
        await t.ctx.notify.settled()
        #expect(t.count("PUT line/notify") == 0)
    }
}

// MARK: - Wait until saved

@MainActor
struct ShortcutWaitTests {
    @Test func waitingReturnsFinishedSavesWithTheirPublicLinksAndProgressOnlyGrows() async throws {
        let created = CreatedSaves()
        let t = ShortcutRig(.server) {
            $0.created = created
            $0.libraryHook = { libraryListing(created, now: Date(timeIntervalSince1970: 1_800_000_000)) }
        }
        var steps: [(Int64, Int64)] = []
        let saved = try await t.run {
            let outcome = try await t.actions.saveLinks(
                [linkA, linkB].map(\.absoluteString), visibility: .public, then: .wait)
            return try await t.actions.waitUntilSaved(outcome, progress: { steps.append(($0, $1)) })
        }.get()
        #expect(saved.saves.count == 2 && saved.saves.allSatisfy { $0.state == .saved })
        let ids = saved.saves.map(\.id)
        #expect(saved.saves.map(\.publicLink) == ids.map { URL(string: "https://media.capybaraharmony.com/\($0).mp4") })
        #expect(saved.saves.allSatisfy { $0.duration == 14.8 && $0.hasVideo })
        #expect(steps.first?.0 == 0 && steps.last?.0 == 2 && steps.allSatisfy { $0.1 == 2 })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0 <= $1.0 }, "never goes back")
        #expect(t.count("PUT line/notify") == 0, "the action waited itself: nothing registered")
    }

    @Test func aSaveThatFailsOnTheServerIsAFailureNotAResult() async throws {
        let t = ShortcutRig(.server)
        let outcome = try await t.run {
            let handed = try await t.actions.saveLinks([linkA, linkPrivate].map(\.absoluteString), then: .wait)
            return try await t.actions.waitUntilSaved(handed)
        }.get()
        #expect(outcome.saves.count == 1 && outcome.saves[0].link == linkA)
        #expect(outcome.failures.count == 1 && outcome.failures[0].afterHandOver)
        #expect(outcome.failures[0].error == .failed(.fetchFailed(code: "error.api.fetch.empty")))
        #expect(outcome.isPartial)
    }

    @Test func everySaveFailingThrowsTheFirstFailure() async {
        let t = ShortcutRig(.server)
        let result = await t.run {
            let handed = try await t.actions.saveLinks([linkPrivate].map(\.absoluteString), then: .wait)
            return try await t.actions.waitUntilSaved(handed)
        }
        #expect(throws: ShortcutError.failed(.fetchFailed(code: "error.api.fetch.empty"))) { try result.get() }
    }

    @Test func stopCancelsWhatIsQueuedAndLeavesWhatRunsToHark() async throws {
        // a share holds the helper for 15 s: the first link runs behind it, the second waits behind that
        let t = ShortcutRig(.serverBusyWithShare, active: false)
        let cancel = ShortcutCancel()
        var phase = 0
        let task = Task { @MainActor () -> Result<ShortcutSaveOutcome, Error> in
            do {
                let handed = try await t.actions.saveLinks([linkA, linkB].map(\.absoluteString), then: .wait)
                phase = 1
                return .success(try await t.actions.waitUntilSaved(handed, cancel: cancel))
            } catch { return .failure(error) }
        }
        await t.rig.drive(until: { phase == 1 }, maxVirtualSeconds: 20)
        await t.rig.run(for: 15.5)                                   // the share ended at 15 s: link A runs (until 17.4), link B waits behind it
        cancel.cancel()
        var result: Result<ShortcutSaveOutcome, Error>?
        let waiter = Task { @MainActor in result = await task.value }
        await t.rig.drive(until: { result != nil }, maxVirtualSeconds: 60)
        await waiter.value
        #expect(throws: CancellationError.self) { try result?.get() }
        let cancels = t.calls.filter { $0.hasPrefix("DELETE line ") }
        #expect(cancels.count == 2, "both were asked to cancel: B was queued, A's turn had come (409 started)")
        await t.ctx.notify.settled()
        #expect(t.count("PUT line/notify") == 1, "the one that started finishes on the server and is announced")
        #expect(t.queue.notice == nil)
    }
}

// MARK: - Upload

@MainActor
struct ShortcutUploadTests {
    @Test func aFileURLIsCopiedBeforeTheActionReturnsAndSentWithQueueAndTitle() async throws {
        let t = ShortcutRig(.server)
        let source = try makeTempFile("clip.mov", bytes: 200_000)
        let outcome = try await t.run {
            let outcome = try await t.actions.uploadFiles([ShortcutFile(name: "clip.mov", source: .url(source))], title: "my clip")
            try? FileManager.default.removeItem(at: source)              // the system's temporary file goes as soon as the action returns
            return outcome
        }.get()
        #expect(t.calls.contains("PUT /studio/upload queue=true title=my clip"))
        #expect(outcome.saves.count == 1 && outcome.saves[0].id == "PrEvIeWupload0001", "the item id is the post key")
        #expect(outcome.saves[0].title == "my clip" && outcome.saves[0].hasVideo)
        #expect(t.queue.jobs[0].via == .shortcut && t.queue.focusedID == nil)
        // the upload carries on from the inbox copy
        await t.rig.drive(until: { t.rig.allSettled() }, maxVirtualSeconds: 120)
        guard case .ready = t.queue.jobs[0].pipeline.state else { Issue.record("\(t.queue.jobs[0].pipeline.state)"); return }
    }

    @Test func rawDataIsWrittenToTheInboxAndSent() async throws {
        let t = ShortcutRig(.server)
        let outcome = try await t.run {
            try await t.actions.uploadFiles([ShortcutFile(name: "from shortcuts.mp4", source: .data(Data(repeating: 3, count: 50_000)))])
        }.get()
        #expect(outcome.saves.count == 1 && outcome.saves[0].title == "from shortcuts")
        #expect(t.calls.contains("PUT /studio/upload queue=true title=-"))
    }

    @Test func aFileOverTheLimitIsRefusedBeforeAByteIsSent() async {
        let t = ShortcutRig(.server) { $0.capsHook = { $0.notifyBridge = true; $0.limits.maxUploadBytes = 1_000 } }
        let result = await t.run {
            try await t.actions.uploadFiles([ShortcutFile(name: "big.mp4", source: .data(Data(repeating: 1, count: 2_000)))])
        }
        #expect(throws: ShortcutError.fileTooLarge(limit: 1_000)) { try result.get() }
        #expect(t.calls.isEmpty && t.queue.jobs.isEmpty, "nothing sent, nothing added")
    }

    @Test func oneFileOverTheLimitRefusesTheWholeAction() async {
        let t = ShortcutRig(.server) { $0.capsHook = { $0.limits.maxUploadBytes = 1_000 } }
        let result = await t.run {
            try await t.actions.uploadFiles([
                ShortcutFile(name: "ok.mp4", source: .data(Data(repeating: 1, count: 100))),
                ShortcutFile(name: "big.mp4", source: .data(Data(repeating: 1, count: 5_000))),
            ])
        }
        #expect(throws: ShortcutError.fileTooLarge(limit: 1_000)) { try result.get() }
        #expect(t.calls.isEmpty && t.queue.jobs.isEmpty)
    }

    @Test func noFileIsAnError() async {
        let t = ShortcutRig(.server)
        let result = await t.run { try await t.actions.uploadFiles([]) }
        #expect(throws: ShortcutError.noFile) { try result.get() }
    }

    @Test func progressIsBytesSentAndReachesTheTotal() async throws {
        let t = ShortcutRig(.server)
        var steps: [(Int64, Int64)] = []
        let file = try makeTempFile("clip.mp4", bytes: 400_000)
        _ = try await t.run {
            try await t.actions.uploadFiles([ShortcutFile(name: "clip.mp4", source: .url(file))], progress: { steps.append(($0, $1)) })
        }.get()
        #expect(steps.first?.0 == 0 && steps.last?.0 == 400_000 && steps.allSatisfy { $0.1 == 400_000 })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0 <= $1.0 })
    }

    @Test func anImageHasNoSessionAndIsSavedWhenTheServerTakesIt() async throws {
        let t = ShortcutRig(.server)
        let outcome = try await t.run {
            let handed = try await t.actions.uploadFiles(
                [ShortcutFile(name: "photo.png", source: .data(Data(repeating: 9, count: 20_000)))], then: .wait)
            return try await t.actions.waitUntilSaved(handed)
        }.get()
        #expect(outcome.saves.count == 1 && outcome.saves[0].state == .saved && !outcome.saves[0].hasVideo)
    }

    @Test func stoppingAnUploadBeforeTheServerHasItCancelsIt() async throws {
        let t = ShortcutRig(.server)
        let cancel = ShortcutCancel()
        let file = try makeTempFile("clip.mp4", bytes: 40_000_000)       // 5 s of upload at the preview's 8 MB/s
        var result: Result<ShortcutSaveOutcome, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await t.actions.uploadFiles([ShortcutFile(name: "clip.mp4", source: .url(file))], cancel: cancel)) }
            catch { result = .failure(error) }
        }
        await t.rig.drive(until: {
            if case .uploading? = t.queue.jobs.first?.pipeline.state { return true } else { return false }
        }, maxVirtualSeconds: 10)
        await t.rig.run(for: 1)                                      // the bytes are going up
        cancel.cancel()
        // the cancel is the owner's: the action hears it through the token or the task
        task.cancel()
        await t.rig.drive(until: { result != nil }, maxVirtualSeconds: 60)
        await task.value
        #expect(throws: CancellationError.self) { try result?.get() }
        #expect(t.queue.jobs.isEmpty, "nothing was saved")
    }
}

// MARK: - Make webp

@MainActor
struct ShortcutMakeWebpTests {
    @Test func theWindowIsClampedToTheClipAndTheServersLimits() {
        let limits = Capabilities.Limits.fork
        // default length = the server's maximum, clamped to the clip
        #expect(ShortcutActions.webpWindow(start: 0, length: nil, duration: 37.4, limits: limits) == (0, 10))
        #expect(ShortcutActions.webpWindow(start: 0, length: nil, duration: 4.2, limits: limits) == (0, 4.2))
        #expect(ShortcutActions.webpWindow(start: 2, length: 30, duration: 5, limits: limits) == (2, 3))
        #expect(ShortcutActions.webpWindow(start: 0, length: 0.1, duration: 20, limits: limits) == (0, 0.5), "never below the minimum")
        #expect(ShortcutActions.webpWindow(start: -4, length: 3, duration: 20, limits: limits) == (0, 3))
        #expect(ShortcutActions.webpWindow(start: 99, length: 3, duration: 10, limits: limits) == (9.5, 0.5), "a start past the end is pulled back")
        #expect(ShortcutActions.webpWindow(start: 1.23456, length: 2.34567, duration: nil, limits: limits) == (1.235, 2.346), "no duration known: only the server's limits")
    }

    @Test func noSaveGivenMakesAWebpOfTheLatestSaveWithAVideo() async throws {
        let t = ShortcutRig(.server)
        var steps: [(Int64, Int64)] = []
        let url = try await t.run { try await t.actions.makeWebp(of: nil, progress: { steps.append(($0, $1)) }) }.get()
        #expect(url.pathExtension == "webp")
        #expect(t.calls.contains("POST render queue=true priority=-"), "queue, and no priority: nobody is looking at a Shortcut")
        #expect(t.wrapper.renders.all.map(\.session) == ["PrEvIeWsession0000000a1"], "the newest post of the library fixture")
        #expect(steps.first?.0 == 0 && steps.last?.0 == 100 && steps.allSatisfy { $0.1 == 100 })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        #expect(t.queue.jobs.isEmpty, "a render is not a job: renders exist only for the focused job")
    }

    @Test func theSizeDefaultsToSettingsAndOtherwiseIsWhatWasAsked() async throws {
        let t = ShortcutRig(.server)
        t.ctx.settings.webpWidth = 320
        _ = try await t.run { try await t.actions.makeWebp(of: nil, length: 4) }.get()
        _ = try await t.run { try await t.actions.makeWebp(of: nil, length: 4, size: .large) }.get()
        let asked = t.wrapper.renders.all
        #expect(asked.map(\.request.width) == [320, 480])
        #expect(asked.allSatisfy { $0.request.length == 4 && $0.request.start == 0 && !$0.request.notify && $0.request.priority == nil })
    }

    @Test func aGivenSaveIsFoundInTheLoadedLibrary() async throws {
        let t = ShortcutRig(.server)
        _ = try await t.run { try await t.actions.makeWebp(of: "2105435404002562056") }.get()
        #expect(t.wrapper.renders.all.map(\.session) == ["PrEvIeWsession0000000a3"])
    }

    @Test func anExpiredSessionIsReopenedWithQueueAndTheRenderWaitsForIt() async throws {
        let t = ShortcutRig(.server) {
            $0.libraryHook = {
                var page = PreviewData.libraryPage(now: Date(timeIntervalSince1970: 1_800_000_000))
                page.posts = page.posts.map { post in
                    var p = post
                    if var s = p.session { s.expiresAt = Date(timeIntervalSince1970: 1_000); p.session = s }
                    return p
                }
                return page
            }
        }
        t.rig.app.library.reset()
        let url = try await t.run { try await t.actions.makeWebp(of: nil) }.get()
        #expect(url.pathExtension == "webp")
        let reopen = t.calls.firstIndex { $0.hasPrefix("POST library/items/") && $0.hasSuffix("/studio queue=true") }
        let render = t.calls.firstIndex { $0.hasPrefix("POST render") }
        #expect(reopen != nil && render != nil && reopen! < render!, "reopened (queued) first, rendered once it was ready")
    }

    @Test func aSaveWithNoVideoIsRefused() async {
        let t = ShortcutRig(.server) {
            $0.libraryHook = {
                var page = PreviewData.libraryPage(now: Date(timeIntervalSince1970: 1_800_000_000))
                page.posts = page.posts.map { post in
                    var p = post
                    p.files = p.files.filter { $0.contentType == "image/webp" }       // only webps left
                    return p
                }
                return page
            }
        }
        t.rig.app.library.reset()
        let none = await t.run { try await t.actions.makeWebp(of: nil) }
        #expect(throws: ShortcutError.noVideo) { try none.get() }
        let named = await t.run { try await t.actions.makeWebp(of: "Dd7P496wolG") }
        #expect(throws: ShortcutError.noVideo) { try named.get() }
        #expect(t.calls.filter { $0.hasPrefix("POST render") }.isEmpty)
    }

    @Test func anUnknownSaveIsNotFound() async {
        let t = ShortcutRig(.server)
        let result = await t.run { try await t.actions.makeWebp(of: "nobody-has-this-one") }
        #expect(throws: ShortcutError.saveNotFound) { try result.get() }
    }

    // MARK: the stop paths (15.4, 15.6)

    @Test func stoppingWhileTheRenderIsStillQueuedCancelsIt() async throws {
        let t = ShortcutRig(.serverBusyWithShare, active: false)
        let cancel = ShortcutCancel()
        var result: Result<URL, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await t.actions.makeWebp(of: nil, cancel: cancel)) } catch { result = .failure(error) }
        }
        await t.rig.drive(until: { t.calls.contains { $0.hasPrefix("POST render") } }, maxVirtualSeconds: 20)
        await t.rig.run(for: 2)                                      // queued behind the share (15 s)
        cancel.cancel()
        await t.rig.drive(until: { result != nil }, maxVirtualSeconds: 30)
        await task.value
        #expect(throws: CancellationError.self) { try result?.get() }
        #expect(t.calls.contains { $0.hasPrefix("DELETE line ") && $0.contains("/") }, "DELETE …/render/<job>")
        await t.ctx.notify.settled()
        #expect(t.count("PUT line/notify") == 0, "cancelled: nothing to announce")
    }

    @Test func stoppingAfterTheRenderStartedLeavesItToHark() async throws {
        let t = ShortcutRig(.server, active: false)
        let cancel = ShortcutCancel()
        var result: Result<URL, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await t.actions.makeWebp(of: nil, cancel: cancel)) } catch { result = .failure(error) }
        }
        await t.rig.drive(until: { t.calls.contains { $0.hasPrefix("POST render") } }, maxVirtualSeconds: 20)
        await t.rig.run(for: 2)                                      // the helper is free: it started at once
        cancel.cancel()
        await t.rig.drive(until: { result != nil }, maxVirtualSeconds: 30)
        await task.value
        #expect(throws: CancellationError.self) { try result?.get() }
        #expect(t.calls.contains { $0.hasPrefix("DELETE line ") }, "asked to cancel: its turn had come (409)")
        await t.ctx.notify.settled()
        #expect(t.count("PUT line/notify") == 1, "it finishes on the server: the owner still hears of it")
    }
}

// MARK: - The CobaltSave entity

@MainActor
struct ShortcutEntityTests {
    @Test func aV2LibraryPostMapsToASave() throws {
        let posts = PreviewData.libraryPageV2(now: Date(timeIntervalSince1970: 1_800_000_000)).posts
        let post = try #require(posts.first { $0.files.contains { $0.role == .webp } && $0.files.contains { $0.role == .privateCopy } })
        let save = ShortcutSave(post: post)
        #expect(save.id == post.id && save.state == .saved)
        #expect(save.title == MediaTitle.text(MediaTitle.resolve(custom: post.customTitle, service: post.service, ref: post.ref, fileName: post.title)))
        #expect(save.link == post.link && save.service == post.service && save.duration == post.duration && save.created == post.createdAt)
        let webps = post.files.filter { $0.role == .webp }.sorted { $0.createdAt > $1.createdAt }.compactMap(\.url)
        #expect(save.webpLinks == webps && !webps.isEmpty, "newest first")
        #expect(save.hasVideo)
        let publicOriginal = post.files.first { $0.role != .webp && $0.isPublic && $0.url != nil }?.url
        #expect(save.publicLink == publicOriginal)
    }

    @Test func aCustomTitleWinsAndAnUploadHasNoService() throws {
        let uploads = PreviewData.uploadPosts(now: Date(timeIntervalSince1970: 1_800_000_000))
        let titled = ShortcutSave(post: uploads[0])
        #expect(titled.title == "crop editor, pinch and drag" && titled.service == nil && titled.link == nil)
        let plain = ShortcutSave(post: uploads[1])
        #expect(plain.title == "from photos · 4 oct" || plain.title.hasPrefix("from photos"))
    }

    @Test func aSessionMapsByItsStatus() {
        func session(_ status: SessionStatus, step: SaveStep? = nil) -> StudioSession {
            StudioSession(
                id: "SessionIdSessionIdSess", status: status, link: linkA.absoluteString, service: "instagram", title: nil,
                duration: 14.7, width: nil, height: nil, bytes: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_800_600_000), errorCode: nil, renders: [], step: step, stepBytes: nil,
                stepTotal: nil, waking: nil)
        }
        #expect(ShortcutSave(session: session(.ready)).state == .saved)
        #expect(ShortcutSave(session: session(.error)).state == .failed)
        #expect(ShortcutSave(session: session(.saving, step: .queued)).state == .queued)
        #expect(ShortcutSave(session: session(.saving, step: .fetching)).state == .saving)
        let s = ShortcutSave(session: session(.ready))
        #expect(s.id == "SessionIdSessionIdSess" && s.link == linkA && s.service == "instagram" && s.title == "instagram · Dd7P496wolG")
    }

    @Test func lookupGoesToTheLoadedLibraryThenTheSessionThenTheFirstPage() async throws {
        let created = CreatedSaves()
        let t = ShortcutRig(.server) {
            $0.created = created
            $0.libraryHook = { libraryListing(created, now: Date(timeIntervalSince1970: 1_800_000_000)) }
        }
        // 1. a post in the loaded library model: no request at all
        let loaded = t.rig.app.library.posts[0]
        let first = await t.actions.saves(for: [loaded.id])
        #expect(first.map(\.id) == [loaded.id])
        #expect(t.wrapper.reads.sessionCalls.isEmpty && t.wrapper.reads.libraryCalls == 0)

        // 2. a link save made through the server: `GET /studio/<id>`
        let outcome = try await t.run { try await t.actions.saveLinks([linkA.absoluteString]) }.get()
        let sid = outcome.saves[0].id
        let second = await t.actions.saves(for: [sid])
        #expect(second.first?.id == sid && second.first?.link == linkA)
        #expect(t.wrapper.reads.sessionCalls.contains(sid))
        #expect(t.wrapper.reads.libraryCalls == 0, "found at the session: the library was not asked")

        // 3. an id only the first library page knows (an upload's item id is no session)
        let created2 = created.all.count
        #expect(created2 == 1)
        let post = libraryListing(created, now: Date(timeIntervalSince1970: 1_800_000_000)).posts[0]
        let third = await t.actions.saves(for: ["unknown-id", post.id, loaded.id])
        #expect(third.map(\.id) == [post.id, loaded.id], "the order asked for, unknown ids dropped")
    }

    @Test func suggestionsAreTheFirstLibraryPage() async {
        let t = ShortcutRig(.server)
        let suggested = await t.actions.suggestedSaves()
        let page = PreviewData.libraryPage(now: t.rig.clock.now())
        #expect(suggested.count == page.posts.count && suggested.allSatisfy { $0.state == .saved })
        #expect(suggested.map(\.created) == suggested.map(\.created).sorted(by: >), "newest first")
    }
}

// MARK: - Get latest saves

@MainActor
struct ShortcutLatestSavesTests {
    @Test func theNewestSaveIsTheDefault() async throws {
        let t = ShortcutRig(.server)
        let saves = try await t.run { try await t.actions.latestSaves() }.get()
        #expect(saves.count == 1 && saves[0].id == fixtureLatestVideoPost)
    }

    @Test func countIsClampedToOneThroughTwenty() async throws {
        let t = ShortcutRig(.server)
        let all = try await t.run { try await t.actions.latestSaves(count: 99) }.get()
        #expect(all.count == PreviewData.libraryPage(now: t.rig.clock.now()).posts.count)
        #expect(all.map(\.created) == all.map(\.created).sorted(by: >))
        let one = try await t.run { try await t.actions.latestSaves(count: 0) }.get()
        #expect(one.count == 1)
    }

    @Test func kindFiltersVideosAndWebps() async throws {
        let t = ShortcutRig(.server)
        let webps = try await t.run { try await t.actions.latestSaves(count: 20, kind: .webps) }.get()
        #expect(!webps.isEmpty && webps.allSatisfy { !$0.webpLinks.isEmpty })
        let videos = try await t.run { try await t.actions.latestSaves(count: 20, kind: .videos) }.get()
        #expect(!videos.isEmpty && videos.allSatisfy(\.hasVideo))
    }

    @Test func notSignedInIsTheSameError() async {
        let t = ShortcutRig(.server)
        t.ctx.settings.clearAPIKey()
        let result = await t.run { try await t.actions.latestSaves() }
        #expect(throws: ShortcutError.notSignedIn) { try result.get() }
    }
}
