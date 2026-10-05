import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

// Instant share (CONTRACT-SHARE-QUICK.md section 9): the extension queues `POST /studio` with a
// URLSession upload and goes; the app learns the session from the system's wake or from
// `GET /studio/recent`, and keeps the original. The transports are fakes; one test drives the real
// foreground transport against a loopback server.

private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let base = URL(string: "https://api.capybaraharmony.com")!
private let sid = "aB3dE6gH9jK2mN5pQ8sTuV"
private let created = Data(#"{"status":"success","id":"aB3dE6gH9jK2mN5pQ8sTuV","url":"https://cobalt.capybaraharmony.com/studio/aB3dE6gH9jK2mN5pQ8sTuV"}"#.utf8)

private func link(_ s: String = "https://www.instagram.com/p/Dc2QA4ng-US/") -> LinkInfo { LinkInfo(URL(string: s)!)! }

// MARK: - A save transport you drive by hand

final class FakeSaveTransport: SaveTransport, @unchecked Sendable {
    struct Upload: Sendable { var task: Int; var request: URLRequest; var body: Data; var label: String; var identifier: String }
    final class Session: SaveSession, @unchecked Sendable {
        let identifier: String
        weak var events: (any SaveEvents)?
        private let lock = NSLock()
        private var _uploads: [Upload] = []
        /// Answers the upload inline (the foreground transport's delegate would, later): status or error code.
        var autoAnswer: (@Sendable (Upload) -> Answer?)?
        enum Answer: Sendable { case status(Int, Data), error(Int) }

        init(identifier: String, events: any SaveEvents) { self.identifier = identifier; self.events = events }

        var uploads: [Upload] { lock.withLock { _uploads } }

        func upload(_ request: URLRequest, from file: URL, label: String) -> Int {
            let body = (try? Data(contentsOf: file)) ?? Data()
            let item = lock.withLock { () -> Upload in
                let u = Upload(task: _uploads.count + 1, request: request, body: body, label: label, identifier: identifier)
                _uploads.append(u)
                return u
            }
            switch autoAnswer?(item) {
            case .status(let status, let data): events?.saveResponded(identifier: identifier, task: item.task, label: label, status: status, body: data)
            case .error(let code): events?.saveFailed(identifier: identifier, task: item.task, label: label, code: code)
            case nil: break
            }
            return item.task
        }

        func registered() async {}
        func waitForEvents(timeout: Double) async {}
    }

    let background: Bool
    private let lock = NSLock()
    private var _sessions: [String: Session] = [:]
    var autoAnswer: (@Sendable (Upload) -> Session.Answer?)?

    init(background: Bool) { self.background = background }

    func session(identifier: String, events: any SaveEvents) -> any SaveSession {
        lock.withLock {
            if let hit = _sessions[identifier] { hit.events = events; return hit }
            let made = Session(identifier: identifier, events: events)
            made.autoAnswer = autoAnswer
            _sessions[identifier] = made
            return made
        }
    }

    var sessions: [Session] { lock.withLock { Array(_sessions.values) } }
    var uploads: [Upload] { sessions.flatMap(\.uploads) }
}

private func bodyJSON(_ upload: FakeSaveTransport.Upload) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: upload.body) as? [String: Any])
}

private func client(key: String? = key) -> HTTPCobaltClient { HTTPCobaltClient(baseURL: base, apiKey: { key }) }

// MARK: - The request

@Suite struct InstantShareRequestTests {
    @Test func theRequestIsTheStudioCreateWithPublicOriginAndTheHarkOptIn() throws {
        let (request, body) = try client().shareSaveRequest(link: URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/")!, label: "instagram · Dc2QA4ng-US")
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://api.capybaraharmony.com/studio")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Api-Key \(key)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["url"] as? String == "https://www.instagram.com/p/Dc2QA4ng-US/")
        #expect(json["public"] as? Bool == true && json["origin"] as? String == "share")
        let notify = try #require(json["notify"] as? [String: Any])
        #expect(notify["on"] as? [String] == ["saved", "failed"] && notify["label"] as? String == "instagram · Dc2QA4ng-US")
        #expect(Set(json.keys) == ["url", "public", "origin", "notify"])
    }

    @Test func withoutAKeyForThisServerNothingIsBuilt() {
        #expect(throws: CobaltError.noAPIKey) { try client(key: nil).shareSaveRequest(link: link().url, label: "x") }
    }

    @Test func theLabelKeepsTheServersRule() {
        #expect(InstantShareEngine.label(for: link()) == "instagram · Dc2QA4ng-US")
        let weird = LinkInfo(URL(string: "https://x.com/i/status/%0Aab%09cd")!)!
        #expect(!InstantShareEngine.label(for: weird).unicodeScalars.contains { $0.properties.generalCategory == .control })
        let long = LinkInfo(URL(string: "https://example.com/" + String(repeating: "a", count: 200))!)!
        #expect(InstantShareEngine.label(for: long).count == 60)
        #expect(InstantShareEngine.label(for: LinkInfo(URL(string: "https://example.com")!)!) == "example · example.com")
    }

    @Test func serverCapabilityFlagIsRead() {
        let json = #"{"server":"cobalt-cloudflare","features":{"studio":true,"create_notify":true}}"#
        #expect(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8))?.createNotify == true)
        #expect(HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{"studio":true}}"#.utf8))?.createNotify == false)
    }

    @Test func theSaveSessionIsOwnedByTheAppsBackgroundHook() {
        let id = UUID()
        let name = BackgroundSessionID.save(job: id)
        #expect(name == "com.capybaraharmony.cobalt.bg.save.\(id.uuidString.lowercased())")
        #expect(AppModel.ownsBackgroundSession(name) && BackgroundSessionID.isSave(name))
        #expect(!BackgroundSessionID.isSave(BackgroundSessionID.app) && !BackgroundSessionID.isSave(BackgroundSessionID.share(job: id)))
    }
}

// MARK: - The engine

@Suite struct InstantShareEngineTests {
    private func engine(_ transport: FakeSaveTransport, wait: Double = 2) throws -> InstantShareEngine {
        InstantShareEngine(transport: transport, directory: try makeTempDirectory(), foregroundWait: wait, registerWait: 0.2)
    }

    @Test func backgroundQueuesTheUploadAndDoesNotWaitForTheServer() async throws {
        let transport = FakeSaveTransport(background: true)                    // never answers
        let job = UUID()
        let started = Date()
        let result = await (try engine(transport)).enqueue(link: link(), client: client(), job: job)
        #expect(result == .saved)
        #expect(Date().timeIntervalSince(started) < 1, "no wait for an answer")
        let upload = try #require(transport.uploads.first)
        #expect(transport.uploads.count == 1 && upload.identifier == BackgroundSessionID.save(job: job))
        #expect(upload.label == "https://www.instagram.com/p/Dc2QA4ng-US/", "the link rides along as the task description, for the app's wake")
        #expect(upload.request.url?.path == "/studio" && upload.request.httpMethod == "POST")
        let json = try bodyJSON(upload)
        #expect(json["origin"] as? String == "share" && json["public"] as? Bool == true)
    }

    @Test func noKeyQueuesNothing() async throws {
        let transport = FakeSaveTransport(background: true)
        let result = await (try engine(transport)).enqueue(link: link(), client: client(key: nil), job: UUID())
        #expect(result == .failed(.noKey) && transport.uploads.isEmpty && transport.sessions.isEmpty)
    }

    @Test func aFolderThatCannotBeWrittenIsCouldNotStart() async throws {
        let transport = FakeSaveTransport(background: true)
        let blocker = try makeTempFile("not-a-folder")
        let engine = InstantShareEngine(transport: transport, directory: blocker.appendingPathComponent("saves"))
        #expect(await engine.enqueue(link: link(), client: client(), job: UUID()) == .failed(.couldNotStart))
        #expect(transport.uploads.isEmpty)
    }

    @Test func foregroundWaitsForTheAnswerAndReportsIt() async throws {
        for (answer, expected) in [
            (FakeSaveTransport.Session.Answer.status(201, created), InstantShare.Result.saved),
            (.status(401, Data()), .failed(.rejected(status: 401))),
            (.status(503, Data()), .failed(.rejected(status: 503))),
            (.error(NSURLErrorNotConnectedToInternet), .failed(.unreachable)),
            (.error(NSURLErrorTimedOut), .failed(.unreachable)),
        ] {
            let transport = FakeSaveTransport(background: false)
            transport.autoAnswer = { _ in answer }
            let dir = try makeTempDirectory()
            let engine = InstantShareEngine(transport: transport, directory: dir, foregroundWait: 2)
            let job = UUID()
            #expect(await engine.enqueue(link: link(), client: client(), job: job) == expected)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(job.uuidString.lowercased()).json").path), "the body file is removed once the answer is in")
        }
    }

    @Test func foregroundWithNoAnswerInTimeStillCountsAsSaved() async throws {
        let transport = FakeSaveTransport(background: false)                   // never answers
        let engine = InstantShareEngine(transport: transport, directory: try makeTempDirectory(), foregroundWait: 0.15)
        let started = Date()
        #expect(await engine.enqueue(link: link(), client: client(), job: UUID()) == .saved)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func theRealForegroundTransportUploadsFromAFileAndReadsTheAnswer() async throws {
        let server = try await LoopbackServer.start { request in
            if request.method == "POST", request.path == "/studio" { return .json(String(decoding: created, as: UTF8.self), status: 201) }
            return .init(status: 404)
        }
        defer { server.stop() }
        let loopback = HTTPCobaltClient(baseURL: server.base, apiKey: { key })
        let engine = InstantShareEngine(transport: URLSessionSaveTransport(mode: .foreground), directory: try makeTempDirectory(), foregroundWait: 5)
        #expect(await engine.enqueue(link: link(), client: loopback, job: UUID()) == .saved)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/studio" && request.headers["authorization"] == "Api-Key \(key)")
        #expect(request.headers["content-type"] == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["origin"] as? String == "share" && (json["notify"] as? [String: Any])?["label"] as? String == "instagram · Dc2QA4ng-US")

        // and a refusal comes back as one
        let refusing = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401) }
        defer { refusing.stop() }
        let engine2 = InstantShareEngine(transport: URLSessionSaveTransport(mode: .foreground), directory: try makeTempDirectory(), foregroundWait: 5)
        let denied = await engine2.enqueue(link: link(), client: HTTPCobaltClient(baseURL: refusing.base, apiKey: { key }), job: UUID())
        #expect(denied == .failed(.rejected(status: 401)))
    }
}

// MARK: - What was shared

@Suite struct InstantIntakeTests {
    private func item(_ providers: [NSItemProvider], text: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        if let text { item.attributedContentText = NSAttributedString(string: text) }
        return item
    }

    @Test func aUrlAttachmentIsTheLink() async {
        let provider = NSItemProvider(item: URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/")! as NSURL, typeIdentifier: UTType.url.identifier)
        #expect(await ShareInbox.loadLinkOnly([item([provider])]) == .link(URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/")!))
    }

    @Test func aLinkInTextIsTheLink() async {
        let provider = NSItemProvider(object: "look at this https://x.com/i/status/21054, nice" as NSString)
        #expect(await ShareInbox.loadLinkOnly([item([provider])]) == .link(URL(string: "https://x.com/i/status/21054")!))
        #expect(await ShareInbox.loadLinkOnly([item([], text: "https://example.com/a")]) == .link(URL(string: "https://example.com/a")!))
    }

    @Test func aLinkWinsOverAMovieAndAMovieAloneNeedsTheSheet() async {
        let movie = NSItemProvider(item: URL(fileURLWithPath: "/tmp/clip.mov") as NSURL, typeIdentifier: UTType.movie.identifier)
        let url = NSItemProvider(item: URL(string: "https://x.com/i/status/1")! as NSURL, typeIdentifier: UTType.url.identifier)
        #expect(await ShareInbox.loadLinkOnly([item([movie, url])]) == .link(URL(string: "https://x.com/i/status/1")!))
        #expect(await ShareInbox.loadLinkOnly([item([movie])]) == .file)
    }

    @Test func nothingUsableIsNone() async {
        let junk = NSItemProvider(object: "no link here" as NSString)
        #expect(await ShareInbox.loadLinkOnly([item([junk])]) == .none)
        #expect(await ShareInbox.loadLinkOnly([]) == .none)
    }
}

// MARK: - The app: the wake, the foreground, the notifications

/// What the app told the owner; filled from the fetcher's seams.
private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var _failures: [(URL?, Int?)] = []
    private var _cleared = 0
    var failures: [(URL?, Int?)] { lock.withLock { _failures } }
    var cleared: Int { lock.withLock { _cleared } }
    func failed(_ link: URL?, _ status: Int?) { lock.withLock { _failures.append((link, status)) } }
    func clear() { lock.withLock { _cleared += 1 } }
}

@MainActor
private struct SharesRig {
    let rig: FetcherRig
    let saves = FakeSaveTransport(background: true)
    let told = Told()

    init(keep: Bool = true, recent: [StudioSession] = [], info: StudioSession? = nil) throws {
        rig = try FetcherRig()
        let fetcher = rig.fetcher
        fetcher.saveTransport = saves
        fetcher.discoversShares = true
        fetcher.serverURL = { base }
        fetcher.keepsOriginals = { keep }
        fetcher.recentShares = { recent }
        fetcher.sessionInfo = { _ in info }
        let told = told
        fetcher.instantFailed = { link, status in told.failed(link, status) }
        fetcher.clearInstantNotifications = { told.clear() }
        if let dir = try? makeTempDirectory() { fetcher.savesDirectory = { dir } }
    }

    var fetcher: OriginalFetcher { rig.fetcher }

    /// What the system delivers when it wakes the app for the extension's session.
    func deliver(status: Int?, body: Data = created, error: Int? = nil, label: String = "https://www.instagram.com/p/Dc2QA4ng-US/") {
        if let error { fetcher.saveAnswers.saveFailed(identifier: "x", task: 1, label: label, code: error) }
        else { fetcher.saveAnswers.saveResponded(identifier: "x", task: 1, label: label, status: status ?? 0, body: body) }
    }
}

private func session(_ id: String = sid, status: SessionStatus = .saving, title: String? = nil, link: String? = "https://www.instagram.com/p/Dc2QA4ng-US/") -> StudioSession {
    StudioSession(
        id: id, status: status, link: link, service: "instagram", title: title, duration: status == .ready ? 12.5 : nil,
        width: status == .ready ? 720 : nil, height: status == .ready ? 1280 : nil, bytes: status == .ready ? 4_000_000 : nil,
        createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400), errorCode: nil, renders: [])
}

@MainActor
@Suite(.serialized)
struct InstantShareAppTests {
    @Test func theWakeReadsTheAnswerAndQueuesTheOriginalWithAWaitingTask() async throws {
        let r = try SharesRig()
        r.deliver(status: 201)
        await r.fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))
        let entry = try #require(r.rig.pending.entry(sid))
        #expect(entry.link == URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/") && entry.media?.name == "Dc2QA4ng-US")
        #expect(entry.sourceWait && entry.sourceURL.absoluteString == "https://api.capybaraharmony.com/studio/\(sid)/source")
        let task = try #require(r.rig.session?.tasks.first)
        #expect(task.label == sid && task.request.url?.absoluteString.hasSuffix("/source?wait=90") == true, "the app's background session holds the request until the save is ready")
        #expect(r.told.failures.isEmpty)
    }

    @Test func aRefusedOrFailedRequestIsAFailureNotification() async throws {
        let r = try SharesRig()
        r.deliver(status: 401, body: Data(#"{"status":"error"}"#.utf8))
        r.deliver(status: nil, error: NSURLErrorNotConnectedToInternet)
        r.deliver(status: 201, body: Data("not json".utf8))
        r.deliver(status: nil, error: NSURLErrorCancelled)                      // our own cancel says nothing
        await r.fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))
        let failures = r.told.failures
        #expect(failures.map { $0.1 } == [401, nil, 201])
        #expect(failures.allSatisfy { $0.0 == URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/") })
        #expect(r.rig.pending.all().isEmpty && r.rig.session == nil)
    }

    @Test func keepOffQueuesNothing() async throws {
        let r = try SharesRig(keep: false)
        r.deliver(status: 201)
        await r.fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))
        #expect(r.rig.pending.all().isEmpty && r.rig.session == nil)
    }

    @Test func aSessionTheLedgerOrTheStoreHasIsLeftAlone() async throws {
        let r = try SharesRig()
        r.rig.handOff(sid)                                                       // the ledger already has it
        let before = r.rig.session?.tasks.count
        r.deliver(status: 201)
        await r.fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))
        #expect(r.rig.session?.tasks.count == before && r.rig.pending.all().count == 1)

        let stored = try SharesRig()
        _ = try await stored.rig.store.add(
            file: try makeTempFile("v.mp4"), kind: .original,
            media: MediaInfo(name: "v", duration: 3, width: 1, height: 1, bytes: 10, isImage: false),
            sessionID: sid, link: nil, remoteURL: nil, move: true)
        stored.deliver(status: 201)
        await stored.fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))
        #expect(stored.rig.pending.all().isEmpty, "already on this phone")
    }

    @Test func theForegroundAsksTheServerAndKeepsWhatItListsEvenWithoutAWake() async throws {
        let ready = session("rdyrdyrdyrdyrdyrdyrdyr", status: .ready, title: "a clip")
        let saving = session("savsavsavsavsavsavsavs", status: .saving)
        let failed = session("errerrerrerrerrerrerrer", status: .error)
        let r = try SharesRig(recent: [ready, saving, failed])
        await r.fetcher.reconcile()
        #expect(r.rig.pending.all().map(\.id).sorted() == ["rdyrdyrdyrdyrdyrdyrdyr", "savsavsavsavsavsavsavs"], "a failed save has nothing to keep")
        let readyEntry = try #require(r.rig.pending.entry("rdyrdyrdyrdyrdyrdyrdyr"))
        #expect(readyEntry.media == MediaInfo(name: "a clip", duration: 12.5, width: 720, height: 1280, bytes: 4_000_000, isImage: false))
        let tasks = try #require(r.rig.session?.tasks)
        let byLabel = Dictionary(uniqueKeysWithValues: tasks.map { ($0.label, $0.request.url?.absoluteString ?? "") })
        #expect(byLabel["rdyrdyrdyrdyrdyrdyrdyr"]?.hasSuffix("/source") == true, "a ready save is fetched plainly")
        #expect(byLabel["savsavsavsavsavsavsavs"]?.hasSuffix("/source?wait=90") == true, "a saving one is waited for")
        #expect(r.told.cleared == 1, "the extension's \"saving\" notifications are cleared in front")

        // a second foreground changes nothing
        await r.fetcher.reconcile()
        #expect(r.rig.pending.all().count == 2 && r.rig.session?.tasks.count == 2)
    }

    @Test func theMacNeverPullsThePhonesShares() async throws {
        let r = try SharesRig(recent: [session()])
        r.fetcher.discoversShares = false
        await r.fetcher.reconcile()
        #expect(r.rig.pending.all().isEmpty)
    }

    @Test func theForegroundDoesNothingWhenKeepIsOffOrTheServerHasNoRoute() async throws {
        let off = try SharesRig(keep: false, recent: [session()])
        await off.fetcher.reconcile()
        #expect(off.rig.pending.all().isEmpty)
        let none = try SharesRig(recent: [])                                      // no key, an older server, nothing shared
        await none.fetcher.reconcile()
        #expect(none.rig.pending.all().isEmpty && none.rig.session == nil)
    }

    @Test func aLandedOriginalTakesTheSessionsTitleWhenTheLedgerOnlyKnewTheLink() async throws {
        let r = try SharesRig(info: session(status: .ready, title: "the real title"))
        r.deliver(status: 201)
        await r.fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))
        let task = try #require(r.rig.session?.tasks.first)
        r.rig.session?.respond(task: task.id, status: 200, body: Data(repeating: 9, count: 3_000))
        #expect(await eventually { r.rig.store.videos.contains { $0.sessionID == sid && $0.kind == .original } })
        let video = try #require(r.rig.store.videos.first { $0.sessionID == sid })
        #expect(video.name == "the real title" && video.duration == 12.5)
    }

    @Test func oldRequestBodiesAreSweptAndNewOnesKept() throws {
        let r = try SharesRig()
        let dir = r.fetcher.savesDirectory()
        let old = dir.appendingPathComponent("old.json"), fresh = dir.appendingPathComponent("fresh.json"), other = dir.appendingPathComponent("keep.txt")
        for url in [old, fresh, other] { try Data("{}".utf8).write(to: url) }
        let past = Date().addingTimeInterval(-3 * 86_400)
        for url in [old, other] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path) }
        r.fetcher.pruneSaveFiles()
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path) && FileManager.default.fileExists(atPath: other.path))
    }

    @Test func theSessionIdIsOnlyTakenFromAWellFormedBody() {
        #expect(OriginalFetcher.sessionID(in: created) == sid)
        for bad in ["", "{}", #"{"id":"short"}"#, #"{"id":"aB3dE6gH9jK2mN5pQ8sT/../"}"#, #"{"id":7}"#, "[]"] {
            #expect(OriginalFetcher.sessionID(in: Data(bad.utf8)) == nil, "\(bad)")
        }
    }
}

// MARK: - Recent shares over the wire, and the notification copy

@Suite(.serialized) struct InstantShareWireTests {
    @Test func recentSharesAreDecodedAndKeyed() async throws {
        let body = #"""
        {"status":"success","now":1800000000000,"sessions":[
          {"status":"ready","id":"rdyrdyrdyrdyrdyrdyrdyr","link":"https://x.com/i/status/1","service":"x","title":"t","duration":9.6,"width":480,"height":560,"bytes":4096,
           "poster_url":null,"public_state":"ready","public_url":"https://media.capybaraharmony.com/aaaaaaaaaa.mp4","step":null,"step_bytes":null,"step_total":null,"waking":false,
           "created_at":1800000000000,"expires_at":1800600000000,"error":null,"renders":[]},
          {"nonsense":true}
        ]}
        """#
        let server = try await LoopbackServer.start { _ in .json(body) }
        defer { server.stop() }
        let sessions = try await HTTPCobaltClient(baseURL: server.base, apiKey: { key }).recentShares(since: Date(timeIntervalSince1970: 1_799_999_000), limit: 99)
        #expect(sessions.map(\.id) == ["rdyrdyrdyrdyrdyrdyrdyr"], "a malformed row never hides the others")
        #expect(sessions.first?.status == .ready && sessions.first?.title == "t")
        let request = try #require(server.requests.first)
        #expect(request.method == "GET" && request.path == "/studio/recent" && request.headers["authorization"] == "Api-Key \(key)")
        #expect(request.query.contains("since=1799999000000") && request.query.contains("limit=25"))
    }

    @Test func anOlderServerThrows() async throws {
        let server = try await LoopbackServer.start { _ in .init(status: 404) }
        defer { server.stop() }
        await #expect(throws: (any Error).self) { try await HTTPCobaltClient(baseURL: server.base, apiKey: { key }).recentShares() }
    }

    @Test func theNotificationsSayWhatTheyShould() {
        let job = UUID()
        let saving = Notifications.instantSavingRequest(job: job, label: "instagram · Dc2QA4ng-US")
        #expect(saving.content.title == "saving to cobalt" && saving.content.body == "instagram · Dc2QA4ng-US")
        #expect(saving.content.interruptionLevel == .passive && saving.content.userInfo["url"] as? String == Notifications.openURL)
        #expect(saving.identifier == "instant-\(job.uuidString.lowercased())" && saving.trigger == nil)
        let failed = Notifications.instantFailedRequest(link: URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/"), status: 401)
        #expect(failed.content.title == "cobalt couldn't start that save")
        #expect(failed.content.body == "instagram · Dc2QA4ng-US — the key was not accepted")
        #expect(Notifications.instantFailedReason(status: nil) == "the server could not be reached")
        #expect(Notifications.instantFailedReason(status: 503) == "the server was not available")
        #expect(Notifications.instantFailedReason(status: 429) == "the server was busy")
        // the test runner has no notification center: nothing here may reach it
        #expect(!Notifications.runsInApp)
    }
}
