import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md wave 2 (K2): "keep offline" as a background download. The session is a fake you drive by
// hand (progress, finish, failure with resume data), the queue ledger and the store are real files in temp
// directories, the clock is virtual. One suite runs the real delegate against a loopback server.

// MARK: - A session you drive by hand

final class FakeOfflineTransport: OfflineTransport, @unchecked Sendable {
    final class Session: OfflineSession, @unchecked Sendable {
        struct Task: Equatable { var id: Int; var request: URLRequest?; var resumeData: Data?; var label: String }
        let identifier: String
        weak var events: (any OfflineDownloadEvents)?
        private let lock = NSLock()
        private var _tasks: [Task] = []
        private var _live: Set<Int> = []
        private var _cancelled: [Int] = []
        private var _next = 0

        init(identifier: String, events: any OfflineDownloadEvents) {
            self.identifier = identifier
            self.events = events
        }

        var tasks: [Task] { lock.withLock { _tasks } }
        var liveIDs: Set<Int> { lock.withLock { _live } }
        var cancelled: [Int] { lock.withLock { _cancelled } }
        var resumed: [Data] { lock.withLock { _tasks.compactMap(\.resumeData) } }
        var urls: [String] { lock.withLock { _tasks.compactMap { $0.request?.url?.absoluteString } } }

        func start(_ request: URLRequest, label: String) -> Int {
            lock.withLock {
                _next += 1
                _tasks.append(Task(id: _next, request: request, resumeData: nil, label: label))
                _live.insert(_next)
                return _next
            }
        }

        func resume(_ data: Data, label: String) -> Int {
            lock.withLock {
                _next += 1
                _tasks.append(Task(id: _next, request: nil, resumeData: data, label: label))
                _live.insert(_next)
                return _next
            }
        }

        func liveTasks() async -> [Int: String] {
            lock.withLock {
                var out: [Int: String] = [:]
                for t in _tasks where _live.contains(t.id) { out[t.id] = t.label }
                return out
            }
        }

        func waitForEvents(timeout: Double) async {}

        func cancel(task id: Int) { lock.withLock { _live.remove(id); _cancelled.append(id) } }

        // what the system does

        func progress(task id: Int, bytes: Int64, total: Int64?) {
            guard let task = lock.withLock({ _tasks.first { $0.id == id } }) else { return }
            events?.progress(task: id, label: task.label, bytes: bytes, total: total)
        }

        func respond(task id: Int, status: Int, body: Data) {
            guard let task = lock.withLock({ _tasks.first { $0.id == id } }) else { return }
            lock.withLock { _ = _live.remove(id) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-offline-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("CFNetworkDownload.tmp")
            try? body.write(to: file)
            events?.finished(task: id, label: task.label, status: status, file: file)
            try? FileManager.default.removeItem(at: dir)         // the system deletes what the delegate left
        }

        func fail(task id: Int, domain: String = NSURLErrorDomain, code: Int, resumeData: Data? = nil) {
            guard let task = lock.withLock({ _tasks.first { $0.id == id } }) else { return }
            lock.withLock { _ = _live.remove(id) }
            events?.failed(task: id, label: task.label, domain: domain, code: code, resumeData: resumeData)
        }

        /// The task vanished without telling anyone (a lost session).
        func lose(task id: Int) { lock.withLock { _ = _live.remove(id) } }
    }

    private let lock = NSLock()
    private var _sessions: [String: Session] = [:]
    private var _created: [String] = []

    func session(identifier: String, events: any OfflineDownloadEvents) -> any OfflineSession {
        lock.withLock {
            if let hit = _sessions[identifier] { hit.events = events; return hit }       // whoever asks last receives the events
            let made = Session(identifier: identifier, events: events)
            _sessions[identifier] = made
            _created.append(identifier)
            return made
        }
    }

    func session(_ identifier: String) -> Session? { lock.withLock { _sessions[identifier] } }
    var created: [String] { lock.withLock { _created } }
}

// MARK: - The rig

private let apiBase = URL(string: "https://api.capybaraharmony.com")!
private func body(_ n: Int = 2_000) -> Data { Data(repeating: 9, count: n) }

@MainActor
final class DownloadRig {
    let rig: OfflineRig
    let store: OfflineStore
    let transport = FakeOfflineTransport()
    let queue: OfflineQueue
    let clock = VirtualClock()
    let client = HTTPCobaltClient(baseURL: apiBase, apiKey: { "KEY-1234" })
    private(set) var engine: OfflineDownloads!
    var landed = 0
    var notNew: [[String]] = []

    init(store external: OfflineStore? = nil) throws {
        rig = try OfflineRig()
        store = external ?? rig.store()
        queue = OfflineQueue(directory: rig.sync)
        engine = makeEngine()
    }

    /// An engine over the same queue, store and sessions (what the next launch builds).
    func makeEngine(transport: FakeOfflineTransport? = nil) -> OfflineDownloads {
        let engine = OfflineDownloads(
            store: store, queue: queue, transport: transport ?? self.transport, clock: clock, client: { [client] in client })
        engine.markNotNew = { [weak self] keys in self?.notNew.append(keys) }
        engine.landed = { [weak self] in self?.landed += 1 }
        return engine
    }

    var session: FakeOfflineTransport.Session? { transport.session(OfflineDownloads.sessionIdentifier) }

    /// A kept record whose file was then removed: the record, poster and flipbook stay.
    func evicted(
        session sid: String? = "S1", name: String = "clip", kind: StoredVideo.Kind = .original, remote: URL? = nil
    ) async throws -> StoredVideo {
        let v = try await rig.save(store, name, kind: kind, session: sid, link: OfflineRig.instagram, remote: remote, keep: true)
        #expect(await store.removeOfflineCopy(v.id))
        return try #require(store.videos.first { $0.id == v.id })
    }

    func job(
        key: String, target: OfflineJob.Target, sources: [OfflineSource] = [.libraryItem(id: "F1")], bytes: Int64? = 2_000,
        aliases: [String]? = nil
    ) -> OfflineJob {
        OfflineJob(key: key, aliases: aliases ?? [key], target: target, sources: sources, expectedBytes: bytes, fileName: "clip.mp4")
    }

    func existingJob(
        _ v: StoredVideo, key: String = "f:F1", sources: [OfflineSource] = [.libraryItem(id: "F1")], aliases: [String]? = nil
    ) -> OfflineJob {
        job(key: key, target: .existing(id: v.id), sources: sources, aliases: aliases)
    }

    func newJob(
        key: String = "f:N1", sources: [OfflineSource] = [.libraryItem(id: "N1")], created: Date = Date(timeIntervalSince1970: 1_700_000_000),
        session: String? = "PST1", mediaID: String? = nil, title: String? = nil, kind: StoredVideo.Kind = .original, remote: URL? = nil
    ) -> OfflineJob {
        job(key: key, target: .new(OfflineJob.NewRecord(
            kind: kind, media: MediaInfo(name: "post", duration: 5, width: 720, height: 1280, bytes: nil, isImage: false),
            sessionID: session, link: OfflineRig.instagram, remoteURL: remote, publicURL: nil, createdAt: created, title: title,
            mediaID: mediaID)), sources: sources)
    }

    /// Everything the engine did on the main actor after the last delegate callback.
    func settled(_ condition: @MainActor () -> Bool) async -> Bool { await eventually(3, condition) }
}

// MARK: - The engine

@MainActor
@Suite(.serialized)
struct OfflineDownloadsTests {
    @Test func theSessionIsTheContractsAndOwnsNothingOfTheOriginalsFetchers() {
        #expect(OfflineDownloads.sessionIdentifier == "com.capybaraharmony.cobalt.bg.offline")
        #expect(AppModel.ownsBackgroundSession(OfflineDownloads.sessionIdentifier))
        #expect(OfflineDownloads.sessionIdentifier != BackgroundSessionID.app)
    }

    // MARK: queue, progress, landing

    @Test func downloadsStartInQueueOrderAndShowAsWaitingUntilBytesArrive() async throws {
        let t = try DownloadRig()
        let a = try await t.evicted(session: "SA", name: "a"), b = try await t.evicted(session: "SB", name: "b")
        let c = try await t.evicted(session: "SC", name: "c")
        t.engine.enqueue([
            t.existingJob(a, key: "f:A", sources: [.libraryItem(id: "A")]),
            t.existingJob(b, key: "f:B", sources: [.libraryItem(id: "B")]),
            t.existingJob(c, key: "f:C", sources: [.libraryItem(id: "C")]),
        ])
        #expect(t.queue.all().map(\.key) == ["f:A", "f:B", "f:C"])
        #expect(t.session?.tasks.map(\.label) == ["f:A", "f:B", "f:C"], "started in the order asked")
        #expect(t.session?.urls.map { URL(string: $0)?.path } == ["/library/items/A/file", "/library/items/B/file", "/library/items/C/file"])
        for key in ["f:A", "f:B", "f:C"] { #expect(t.engine.states[key] == .waiting) }
        #expect(t.engine.summary.left == 3 && t.engine.summary.bytes == 0 && t.engine.summary.total == 6_000)

        t.session?.progress(task: 1, bytes: 500, total: 2_000)
        #expect(await t.settled { t.engine.states["f:A"] == .downloading(TransferProgress(bytes: 500, total: 2_000)) })
        #expect(t.engine.states["f:B"] == .waiting, "a task with no bytes yet is still waiting")
        #expect(t.engine.summary.left == 3 && t.engine.summary.bytes == 500)
    }

    @Test func aFinishedDownloadLandsKeptInTheVisibleFolderOnTheExistingRecord() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let task = try #require(t.session?.tasks.first)
        #expect(task.request?.value(forHTTPHeaderField: "Authorization") == "Api-Key KEY-1234", "a private copy is asked for with the key")
        #expect(task.request?.httpMethod == "GET")
        t.session?.progress(task: task.id, bytes: 700, total: 2_000)
        t.session?.respond(task: task.id, status: 200, body: body())

        #expect(await t.settled { t.store.videos.first { $0.id == v.id }?.isOffline == true && t.engine.states["f:F1"] == nil })
        let landed = try #require(t.store.videos.first { $0.id == v.id })
        #expect(landed.place == .offline && landed.keep && landed.bytes == 2_000)
        #expect(landed.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(t.rig.visibleFiles().count == 1 && t.rig.cacheFiles().isEmpty)
        #expect(t.store.videos.filter { $0.id == v.id }.count == 1, "no duplicate record")
        #expect(t.queue.all().isEmpty && !t.queue.hasResume(key: "f:F1"))
        #expect(t.landed >= 1)
        #expect(t.notNew.contains(["s:S1"]), "the photos and folder keys are marked before the file lands")
        t.rig.checkInvariants()
    }

    @Test func aPostOnlyMediaLandsAsANewRecordJoinedToItsPostWithTheServersDate() async throws {
        let t = try DownloadRig()
        let page = PreviewData.libraryPage(now: t.clock.now())
        let post = try #require(page.posts.first { $0.id == "Dd55fEyN1Yy" })
        let item = try #require(MediaItem.merge(local: nil, post: post))
        let r = try #require(item.video)
        let job = try #require(OfflineSources.job(for: r, in: item, mediaBase: URL(string: "https://media.capybaraharmony.com/"), now: t.clock.now()))
        guard case .new(let n) = job.target else { Issue.record("expected a new record"); return }
        #expect(n.sessionID == "PrEvIeWsession0000000a1" && n.link == post.link && n.createdAt == r.createdAt)

        t.engine.enqueue([job])
        let task = try #require(t.session?.tasks.first)
        t.session?.respond(task: task.id, status: 200, body: body(3_000))
        #expect(await t.settled { !t.store.videos.isEmpty && t.queue.all().isEmpty })
        let video = try #require(t.store.videos.first)
        #expect(video.isOffline && video.place == .offline && video.kind == .original)
        #expect(video.createdAt == r.createdAt, "the server's date, so an old post does not jump to the front of the orbit")
        #expect(video.link == post.link && video.sessionID == "PrEvIeWsession0000000a1")
        let local = try #require(t.store.media.first)
        #expect(MediaItem.joins(local, post), "kept media is one with its post")
        #expect(t.notNew == [["s:PrEvIeWsession0000000a1"]])
        t.rig.checkInvariants()
    }

    @Test func aNewRecordJoinsTheMediaItWasStartedFromAndCarriesItsTitle() async throws {
        let t = try DownloadRig()
        let original = try await t.rig.save(t.store, "clip", session: "S1", link: OfflineRig.instagram, keep: true)
        let webpURL = URL(string: "https://media.capybaraharmony.com/aBcDeFgHiJ.webp")!
        t.engine.enqueue([t.newJob(sources: [.open(webpURL)], session: "S1", mediaID: original.mediaID, title: "cat loop", kind: .webp, remote: webpURL)])
        let task = try #require(t.session?.tasks.first)
        #expect(task.request?.value(forHTTPHeaderField: "Authorization") == nil, "a public file is never sent the key")
        t.session?.respond(task: task.id, status: 200, body: body())
        #expect(await t.settled { t.store.videos.count == 2 && t.queue.all().isEmpty })
        #expect(t.store.media.count == 1, "joined to the media that was kept already")
        #expect(t.store.media.first?.customTitle == "cat loop")
    }

    @Test func aCachedFileIsNotDownloadedAgainByTheEngineWhenItIsAlreadyKept() async throws {
        let t = try DownloadRig()
        let v = try await t.rig.save(t.store, "clip", session: "S1", keep: true)       // kept, file here
        t.engine.enqueue([t.existingJob(v)])
        await t.engine.reconcile()
        #expect(t.queue.all().isEmpty, "a landing finished in another process: nothing to fetch")
    }

    // MARK: sources

    @Test func eachSourceThatSaysNotHereMovesToTheNextAndTheLastOneIsGone() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        let hosted = URL(string: "https://media.capybaraharmony.com/PrEvIeW011.mp4")!
        t.engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1"), .open(hosted), .studioSource(session: "S1")])])
        let s = try #require(t.session)
        s.respond(task: 1, status: 404, body: Data(#"{"error":{"code":"error.library.not_found"}}"#.utf8))
        #expect(await t.settled { s.tasks.count == 2 })
        #expect(s.tasks[1].request?.url == hosted)
        #expect(s.tasks[1].request?.value(forHTTPHeaderField: "Authorization") == nil)
        s.respond(task: 2, status: 410, body: Data())
        #expect(await t.settled { s.tasks.count == 3 })
        #expect(s.tasks[2].request?.url?.path == "/studio/S1/source")
        #expect(s.tasks[2].request?.value(forHTTPHeaderField: "Authorization") == nil, "the studio source needs no key")
        #expect(t.queue.entry("f:F1")?.sourceIndex == 2)
        s.respond(task: 3, status: 409, body: Data())
        #expect(await t.settled { t.engine.states["f:F1"] == .failed(.gone) })
        #expect(s.tasks.count == 3, "nothing is left to try")
        await t.engine.reconcile()
        #expect(s.tasks.count == 3 && t.engine.states["f:F1"] == .failed(.gone), "gone stays gone until the owner retries")
    }

    @Test func aRefusedKeyIsAuthAndIsNeverRetried() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1"), .studioSource(session: "S1")])])
        let s = try #require(t.session)
        s.respond(task: 1, status: 401, body: Data())
        #expect(await t.settled { t.engine.states["f:F1"] == .failed(.auth) })
        await t.engine.reconcile()
        #expect(s.tasks.count == 1, "no other source, no retry: the key is wrong")
        // the retry is the same action
        t.engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1")])])
        #expect(s.tasks.count == 2 && t.engine.states["f:F1"] == .waiting)
        s.respond(task: 2, status: 403, body: Data())
        #expect(await t.settled { t.engine.states["f:F1"] == .failed(.auth) })
    }

    @Test func aFullDiskIsFullAndIsNotRetriedUntilTheOwnerAsks() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        s.fail(task: 1, domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(await t.settled { t.engine.states["f:F1"] == .failed(.full) })
        await t.engine.reconcile()
        #expect(s.tasks.count == 1)
        t.engine.enqueue([t.existingJob(v)])
        #expect(s.tasks.count == 2, "retry")
    }

    @Test func aNetworkLossWaitsAndTheNextForegroundRestartsItUpToFiveTimes() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        for attempt in 1...5 {
            s.fail(task: attempt, code: NSURLErrorNotConnectedToInternet)
            if attempt < 5 {
                #expect(await t.settled { t.queue.entry("f:F1")?.state == .queued && t.queue.entry("f:F1")?.tries == attempt })
                #expect(t.engine.states["f:F1"] == .waiting)
                #expect(s.tasks.count == attempt, "not restarted by itself")
                await t.engine.reconcile()
                #expect(s.tasks.count == attempt + 1, "the foreground restarts it")
            }
        }
        #expect(await t.settled { t.engine.states["f:F1"] == .failed(.unreachable) })
        await t.engine.reconcile()
        #expect(s.tasks.count == 5)
    }

    @Test func aServerErrorIsATryNotAFailureAndAnotherSourceIsNotTried() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1"), .studioSource(session: "S1")])])
        let s = try #require(t.session)
        s.respond(task: 1, status: 503, body: Data())
        #expect(await t.settled { t.queue.entry("f:F1")?.state == .queued })
        await t.engine.reconcile()
        #expect(s.tasks.count == 2 && s.tasks[1].request?.url?.path == "/library/items/F1/file", "the same place again")
    }

    // MARK: resume

    @Test func aFailureThatCarriesResumeDataRestartsFromIt() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        let resume = Data("RESUME-DATA".utf8)
        s.fail(task: 1, code: NSURLErrorNetworkConnectionLost, resumeData: resume)
        #expect(await t.settled { t.queue.entry("f:F1")?.state == .queued })
        #expect(t.queue.resumeData(key: "f:F1") == resume, "kept on disk next to the ledger")

        await t.engine.reconcile()
        #expect(s.tasks.count == 2)
        #expect(s.tasks[1].resumeData == resume && s.tasks[1].request == nil, "restarted with the data, not a fresh request")
        #expect(s.resumed == [resume])
        #expect(!t.queue.hasResume(key: "f:F1"), "used once")
        s.respond(task: 2, status: 206, body: body())
        #expect(await t.settled { t.store.videos.first { $0.id == v.id }?.isOffline == true })
    }

    @Test func theSystemCancellingTheAppsTasksKeepsTheirResumeData() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        // the owner swiped the app away: the system cancels the task and hands over what it has
        s.fail(task: 1, code: NSURLErrorCancelled, resumeData: Data("R".utf8))
        #expect(await t.settled { t.queue.entry("f:F1")?.state == .queued && t.queue.hasResume(key: "f:F1") })
        #expect(t.engine.states["f:F1"] == .waiting)
    }

    @Test func aNewSourceDropsTheResumeDataOfTheOldOne() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1"), .studioSource(session: "S1")])])
        let s = try #require(t.session)
        t.queue.saveResume(Data("OLD".utf8), key: "f:F1")
        s.respond(task: 1, status: 404, body: Data())
        #expect(await t.settled { s.tasks.count == 2 })
        #expect(s.tasks[1].resumeData == nil, "a resume belongs to the request that made it")
    }

    // MARK: cancel

    @Test func stopDownloadingCancelsTheTaskAndDropsTheEntryAndItsResumeData() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v, aliases: ["f:F1", "l:\(v.id)"])])
        let s = try #require(t.session)
        t.queue.saveResume(Data("R".utf8), key: "f:F1")
        t.engine.cancel(keys: ["l:\(v.id)"])                      // by any alias
        #expect(s.cancelled == [1])
        #expect(t.queue.all().isEmpty && !t.queue.hasResume(key: "f:F1"))
        #expect(t.engine.states.isEmpty && t.engine.summary.left == 0)
        // the cancel's own failure arrives afterwards and says nothing
        s.fail(task: 1, code: NSURLErrorCancelled)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(t.engine.states.isEmpty && t.queue.all().isEmpty)
        #expect(t.store.videos.first { $0.id == v.id }?.place == nil, "no file appeared")
    }

    @Test func aCancelledPostOnlyMediaLeavesNoLocalRecord() async throws {
        let t = try DownloadRig()
        t.engine.enqueue([t.newJob()])
        t.engine.cancel(keys: ["f:N1"])
        #expect(t.store.videos.isEmpty && t.queue.all().isEmpty)
        // a task that finishes after the cancel is dropped, not landed
        let s = try #require(t.session)
        s.respond(task: 1, status: 200, body: body())
        try? await Task.sleep(for: .milliseconds(30))
        #expect(t.store.videos.isEmpty)
    }

    @Test func stopAllCancelsEverythingThatIsGoingAndLeavesFailuresAlone() async throws {
        let t = try DownloadRig()
        t.engine.enqueue([t.newJob(key: "f:N1"), t.newJob(key: "f:N2", sources: [.libraryItem(id: "N2")], session: "PST2")])
        let s = try #require(t.session)
        s.respond(task: 2, status: 401, body: Data())
        #expect(await t.settled { t.engine.states["f:N2"] == .failed(.auth) })
        t.engine.cancelAll()
        #expect(s.cancelled == [1])
        #expect(t.engine.states["f:N1"] == nil && t.engine.states["f:N2"] == .failed(.auth))
    }

    // MARK: a new launch

    @Test func aFreshProcessReattachesToTheLiveTaskWithoutStartingAnotherOne() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        #expect(s.tasks.count == 1)

        let second = t.makeEngine()                                 // the next launch: same ledger, same system session
        #expect(second.states["f:F1"] == .waiting, "known before anything runs")
        await second.reconcile()
        #expect(s.tasks.count == 1, "re-attached to the running task: no duplicate")
        if case .downloading(_, let task, _) = t.queue.entry("f:F1")?.state { #expect(task == 1) } else { Issue.record("expected the same running task") }

        // the new process hears the finish
        s.progress(task: 1, bytes: 100, total: 2_000)
        #expect(await t.settled { second.states["f:F1"] == .downloading(TransferProgress(bytes: 100, total: 2_000)) })
        s.respond(task: 1, status: 200, body: body())
        #expect(await t.settled { t.store.videos.first { $0.id == v.id }?.isOffline == true })
    }

    @Test func aTaskTheSystemLostIsStartedAgainFromTheForeground() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        s.lose(task: 1)
        await t.makeEngine().reconcile()
        #expect(s.tasks.count == 2)
        if case .downloading(_, let task, _) = t.queue.entry("f:F1")?.state { #expect(task == 2) } else { Issue.record("expected a running task") }
    }

    @Test func aFileThatArrivedWhileTheAppWasGoneIsLandedByTheNextReconcile() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        // the delegate moved the file and wrote `arrived`; the process died before landing it
        let inbox = t.store.inboxURL(for: "clip.mp4")
        try body(2_500).write(to: inbox)
        t.queue.update("f:F1", now: t.clock.now()) { $0.state = .arrived(file: inbox) }
        await t.makeEngine().reconcile()
        let landed = try #require(t.store.videos.first { $0.id == v.id })
        #expect(landed.isOffline && landed.bytes == 2_500)
        #expect(t.queue.all().isEmpty)
    }

    @Test func anArrivedFileTheInboxSweepTookIsFetchedAgain() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        t.queue.update("f:F1", now: t.clock.now()) { $0.state = .arrived(file: URL(fileURLWithPath: "/nonexistent/clip.mp4")) }
        await t.engine.reconcile()
        #expect(t.session?.tasks.count == 2, "started again")
    }

    @Test func aRecordRemovedWhileItDownloadedLeavesNoFileBehind() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        await t.store.remove(v.id)
        t.session?.respond(task: 1, status: 200, body: body())
        #expect(await t.settled { t.queue.all().isEmpty })
        #expect(t.store.videos.isEmpty && t.rig.visibleFiles().isEmpty && t.rig.cacheFiles().isEmpty)
        let inbox = t.rig.hidden.appendingPathComponent("inbox")
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: inbox.path))?.filter { $0.hasSuffix(".mp4") } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func failedEntriesStayForTheRetryAndAreForgottenAfterAWeek() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        t.session?.respond(task: 1, status: 401, body: Data())
        #expect(await t.settled { t.engine.states["f:F1"] == .failed(.auth) })
        let relaunch = t.makeEngine()
        #expect(relaunch.states["f:F1"] == .failed(.auth), "still there after a relaunch")
        t.clock.jump(by: OfflineQueue.failedRetention + 60)
        await relaunch.reconcile()
        #expect(t.queue.all().isEmpty)
    }

    // MARK: the delegate side

    @Test func theSinkNeverTouchesTheMainActorAndDropsWhatCamePastACancel() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        let s = try #require(t.session)
        // callbacks from the system's own queue (a plain GCD queue, not the main actor)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                s.progress(task: 1, bytes: 10, total: 100)
                s.fail(task: 1, code: NSURLErrorCancelled, resumeData: nil)
                c.resume()
            }
        }
        #expect(await t.settled { t.queue.entry("f:F1")?.state == .queued })
        // a finish for a task the entry has moved past is deleted, never landed
        t.queue.update("f:F1", now: t.clock.now()) { $0.state = .downloading(session: "x", task: 9, since: t.clock.now()) }
        s.respond(task: 1, status: 200, body: body())
        try? await Task.sleep(for: .milliseconds(30))
        #expect(t.store.videos.first { $0.id == v.id }?.place == nil)
    }

    @Test func progressIsThrottledButTheLastValueAlwaysGoesThrough() async throws {
        let log = Mutex<[Int64]>([])
        let sink = OfflineEventSink(queue: OfflineQueue(directory: try makeTempDirectory()), inboxRoot: try makeTempDirectory(), now: { Date() }) { event in
            if case .progress(_, _, let p) = event { log.withLock { $0.append(p.bytes) } }
        }
        for n in 1...200 { sink.progress(task: 1, label: "k", bytes: Int64(n), total: 1_000) }
        sink.progress(task: 1, label: "k", bytes: 1_000, total: 1_000)
        let seen = log.withLock { $0 }
        #expect(seen.first == 1 && seen.last == 1_000)
        #expect(seen.count < 10, "about 4 a second, not one per chunk")
    }

    @Test func aRestartedDownloadReportsItsOwnTaskNotTheOldOnes() {
        let seen = Mutex<[Int]>([])
        let sink = OfflineEventSink(queue: OfflineQueue(directory: (try? makeTempDirectory()) ?? URL(fileURLWithPath: "/tmp")), inboxRoot: URL(fileURLWithPath: "/tmp"), now: { Date() }) { event in
            if case .progress(_, let task, _) = event { seen.withLock { $0.append(task) } }
        }
        sink.progress(task: 1, label: "k", bytes: 10, total: 100)
        sink.progress(task: 2, label: "k", bytes: 5, total: 100)        // the same rendition, started again before the first was told it ended
        #expect(seen.withLock { $0 } == [1, 2])
    }

    @Test func aCancelledEntryNeverHoldsAFileTheSinkMoved() async throws {
        let queue = OfflineQueue(directory: try makeTempDirectory())
        let inbox = try makeTempDirectory()
        let events = Mutex<[String]>([])
        let sink = OfflineEventSink(queue: queue, inboxRoot: inbox, now: { Date() }) { event in
            switch event {
            case .arrived: events.withLock { $0.append("arrived") }
            case .httpFailed(_, _, let status): events.withLock { $0.append("http \(status)") }
            case .failed: events.withLock { $0.append("failed") }
            case .progress: break
            }
        }
        let file = try makeTempFile("x.tmp", bytes: 10)
        sink.finished(task: 1, label: "gone", status: 200, file: file)               // no entry for it
        #expect(!FileManager.default.fileExists(atPath: file.path) && events.withLock { $0 }.isEmpty)
        sink.finished(task: 1, label: "gone", status: 404, file: try makeTempFile("y.tmp", bytes: 10))
        #expect(events.withLock { $0 } == ["http 404"])
    }
}

// MARK: - The queue ledger

@MainActor
struct OfflineQueueTests {
    private func job(_ key: String, aliases: [String]? = nil) -> OfflineJob {
        OfflineJob(
            key: key, aliases: aliases ?? [key],
            target: .existing(id: "r1"), sources: [.libraryItem(id: "x"), .open(URL(string: "https://media.capybaraharmony.com/a.webp")!), .studioSource(session: "S")],
            expectedBytes: 10, fileName: "a.mp4")
    }

    @Test func theLedgerRoundTripsEveryStateThroughItsFile() throws {
        let dir = try makeTempDirectory()
        let queue = OfflineQueue(directory: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        queue.enqueue(job("a"), now: now)
        queue.enqueue(job("b"), now: now)
        queue.enqueue(job("c"), now: now)
        queue.enqueue(job("d"), now: now)
        queue.update("b", now: now) { $0.state = .downloading(session: "s", task: 4, since: now) }
        queue.update("c", now: now) { $0.state = .arrived(file: URL(fileURLWithPath: "/tmp/x.mp4")) }
        queue.update("d", now: now) { $0.state = .failed(.other(503)) }
        let reread = OfflineQueue(directory: dir).all()
        #expect(reread.map(\.key) == ["a", "b", "c", "d"])
        #expect(reread[1].state == .downloading(session: "s", task: 4, since: now))
        #expect(reread[2].state == .arrived(file: URL(fileURLWithPath: "/tmp/x.mp4")))
        #expect(reread[3].state == .failed(.other(503)))
        #expect(reread[0].job.sources.count == 3)
        #expect(OfflineQueue(directory: dir).url.lastPathComponent == "offline-queue.json")
    }

    @Test func theSameRenditionIsOneEntryWhateverKeyAsksAndAFailedOneIsRevived() throws {
        let queue = OfflineQueue(directory: try makeTempDirectory())
        let now = Date()
        #expect(queue.enqueue(job("f:A", aliases: ["f:A", "l:1"]), now: now).isNew)
        #expect(!queue.enqueue(job("l:1"), now: now).isNew, "known under another key")
        #expect(!queue.enqueue(job("f:A"), now: now).isNew)
        #expect(queue.all().count == 1)
        queue.update("f:A", now: now) { $0.state = .failed(.gone); $0.sourceIndex = 2; $0.tries = 4 }
        let revived = queue.enqueue(job("f:A"), now: now)
        #expect(revived.isNew && revived.entry.state == .queued && revived.entry.sourceIndex == 0 && revived.entry.tries == 0)
        #expect(queue.all().count == 1)
    }

    @Test func resumeDataLivesInItsOwnFolderAndGoesWithTheEntry() throws {
        let dir = try makeTempDirectory()
        let queue = OfflineQueue(directory: dir)
        queue.enqueue(job("f:A/../x"), now: Date())
        queue.saveResume(Data("D".utf8), key: "f:A/../x")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("offline-resume").path)
        #expect(files.count == 1 && files[0].hasSuffix(".data") && !files[0].contains("/") && !files[0].contains(":"))
        #expect(queue.resumeData(key: "f:A/../x") == Data("D".utf8))
        queue.remove("f:A/../x")
        #expect(!queue.hasResume(key: "f:A/../x") && queue.all().isEmpty)
    }
}

// MARK: - What to fetch from

@MainActor
struct OfflineSourcesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let base = URL(string: "https://media.capybaraharmony.com/")!

    private func post(_ id: String) throws -> LibraryPost {
        try #require(PreviewData.libraryPage(now: now).posts.first { $0.id == id })
    }

    @Test func aVideoTriesItsPrivateCopyThenTheHostedLinkThenTheSessionThenTheFirstUrl() throws {
        let p = try post("Dd55fEyN1Yy")                              // a public hosted mp4 and a private copy, session a1
        let item = try #require(MediaItem.merge(local: nil, post: p))
        let r = try #require(item.video)
        let sources = OfflineSources.sources(for: r, session: p.session, now: now)
        #expect(sources == [
            .libraryItem(id: "PrEvIeWitem000002"),
            .open(URL(string: "https://media.capybaraharmony.com/PrEvIeW011.mp4")!),
            .studioSource(session: "PrEvIeWsession0000000a1"),
        ])
    }

    @Test func anExpiredSessionIsNotTriedAndALocalRecordsFirstUrlComesLast() throws {
        var p = try post("Dd55fEyN1Yy")
        p.session?.expiresAt = now.addingTimeInterval(-60)
        let tunnel = URL(string: "https://api.capybaraharmony.com/tunnel?id=x")!
        let local = StoredVideo(
            id: "r1", kind: .original, fileURL: nil, posterURL: nil, name: "clip", duration: 1, width: 1, height: 1, bytes: 5,
            sessionID: "PrEvIeWsession0000000a1", link: p.link, remoteURL: tunnel, createdAt: now)
        let stored = try #require(StoredMedia(id: "r1", original: local, webps: []))
        let item = try #require(MediaItem.merge(local: stored, post: p))
        let sources = OfflineSources.sources(for: try #require(item.video), session: p.session, now: now)
        #expect(!sources.contains(.studioSource(session: "PrEvIeWsession0000000a1")), "the library says that session is over")
        #expect(sources.last == .open(tunnel))
        #expect(sources.first == .libraryItem(id: "PrEvIeWitem000002"))
    }

    @Test func aWebpUsesItsPublicUrlAndAPrivateOneUsesTheKeyedRoute() throws {
        let p = try post("2105435404002562056")
        let item = try #require(MediaItem.merge(local: nil, post: p))
        let webp = try #require(item.webps.first)
        #expect(OfflineSources.sources(for: webp, session: nil, now: now) == [.open(URL(string: "https://media.capybaraharmony.com/PrEvIeW002.webp")!)])

        var file = try #require(p.files.first { $0.role == .webp })
        file.wireVisibility = .private
        file.url = nil
        file.canToggleVisibility = true
        var privatePost = p
        privatePost.files = privatePost.files.map { $0.id == file.id ? file : $0 }
        let privateItem = try #require(MediaItem.merge(local: nil, post: privatePost))
        let privateWebp = try #require(privateItem.webps.first)
        #expect(OfflineSources.sources(for: privateWebp, session: nil, now: now) == [.libraryItem(id: file.id)])
    }

    @Test func aPlainSaveWithNoServerCopyHasNowhereToComeFromAndTheModelSaysSo() throws {
        let local = StoredVideo(
            id: "r1", kind: .original, fileURL: nil, posterURL: nil, name: "clip", duration: 1, width: 1, height: 1, bytes: 5,
            sessionID: nil, link: nil, remoteURL: nil, createdAt: now)
        let stored = try #require(StoredMedia(id: "r1", original: local, webps: []))
        let item = try #require(MediaItem.merge(local: stored, post: nil))
        let r = try #require(item.video)
        #expect(OfflineSources.sources(for: r, session: nil, now: now).isEmpty)
        #expect(OfflineSources.job(for: r, in: item, mediaBase: base, now: now) == nil)
        let h = Harness(.happy)
        #expect(h.app.offlineState(of: r) == .unavailable)
    }

    @Test func aPrivateWebpOfAPostKeptHereStillMatchesItsLibraryFileByName() throws {
        var p = try post("2105435404002562056")
        var file = try #require(p.files.first { $0.role == .webp })
        file.url = nil
        file.wireVisibility = .private
        file.canToggleVisibility = true
        file.mediaName = "PrEvIeW002.webp"
        p.files = p.files.map { $0.id == file.id ? file : $0 }
        let item = try #require(MediaItem.merge(local: nil, post: p))
        let r = try #require(item.webps.first)
        let job = try #require(OfflineSources.job(for: r, in: item, mediaBase: base, now: now))
        guard case .new(let n) = job.target else { Issue.record("expected new"); return }
        #expect(n.kind == .webp && n.remoteURL == URL(string: "https://media.capybaraharmony.com/PrEvIeW002.webp"))
        #expect(n.sessionID == (p.session?.id ?? p.id))
        // the record this makes is the same webp as the post's file
        #expect(MediaItem.isSameWebp(file, try #require(n.remoteURL)))
    }

    @Test func theKeyIsTheServersFileIdElseTheRecordsAndEveryAliasIsKnown() throws {
        let p = try post("Dd7P496wolG")
        let item = try #require(MediaItem.merge(local: nil, post: p))
        let r = try #require(item.video)
        #expect(OfflineKey.of(r) == "f:PrEvIeWitem000004")
        let local = StoredVideo(
            id: "rec1", kind: .original, fileURL: nil, posterURL: nil, name: "x", duration: 1, width: 1, height: 1, bytes: 5,
            sessionID: nil, link: nil, remoteURL: nil, createdAt: now)
        let bare = Rendition(id: "video", kind: .video, local: local, createdAt: now)
        #expect(OfflineKey.of(bare) == "l:rec1")
        var withFile = bare
        withFile.file = r.file
        #expect(OfflineKey.aliases(of: withFile) == ["f:PrEvIeWitem000004", "l:rec1"])
        let loose = Rendition(id: "video", kind: .video, createdAt: now)
        #expect(OfflineKey.of(loose) == "r:video")
    }

    @Test func theInboxNameCarriesTheRightExtension() throws {
        #expect(OfflineSources.inboxName("instagram_Dd55fEyN1Yy", ext: "mp4") == "instagram_Dd55fEyN1Yy.mp4")
        #expect(OfflineSources.inboxName("a.webp", ext: "webp") == "a.webp")
        #expect(OfflineSources.inboxName("", ext: "mp4") == "cobalt.mp4")
        let p = try post("2105435404002562056")
        let webp = try #require(MediaItem.merge(local: nil, post: p)?.webps.first)
        #expect(OfflineSources.fileExtension(of: webp) == "webp")
    }

    @Test func classifiesFailures() {
        #expect(OfflineSources.isGone(CobaltError.api(code: "error.studio.expired", httpStatus: 410)))
        #expect(OfflineSources.isGone(CobaltError.invalidResponse(httpStatus: 404)))
        #expect(!OfflineSources.isGone(CobaltError.network(.notConnectedToInternet)))
        #expect(!OfflineSources.isGone(CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)))
        #expect(OfflineSources.isDiskFull(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        #expect(OfflineSources.isDiskFull(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        #expect(OfflineSources.isDiskFull(CocoaError(.fileWriteOutOfSpace)))
        #expect(!OfflineSources.isDiskFull(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        #expect(OfflineSources.isNetworkLoss(NSURLErrorNotConnectedToInternet) && !OfflineSources.isNetworkLoss(NSURLErrorBadURL))
    }
}

// MARK: - The request

struct RemoteFileRequestsTests {
    private let client = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { "KEY-1" })

    @Test func theRequestIsWhatDownloadSends() throws {
        let item = try client.urlRequest(for: .libraryItem(id: "abc"))
        #expect(item.url?.absoluteString == "https://api.capybaraharmony.com/library/items/abc/file" && item.value(forHTTPHeaderField: "Authorization") == "Api-Key KEY-1")
        let studio = try client.urlRequest(for: .studioSource(session: "S1"))
        #expect(studio.url?.path == "/studio/S1/source" && studio.value(forHTTPHeaderField: "Authorization") == nil)
        let open = try client.urlRequest(for: .open(URL(string: "https://media.capybaraharmony.com/a.webp")!))
        #expect(open.url?.host == "media.capybaraharmony.com" && open.value(forHTTPHeaderField: "Authorization") == nil && open.httpMethod == "GET")
    }

    @Test func aKeyedRouteWithoutAKeyThrowsBeforeAnyRequest() {
        let keyless = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { nil })
        #expect(throws: CobaltError.noAPIKey) { try keyless.urlRequest(for: .libraryItem(id: "abc")) }
    }

    @Test func onlyTheRealClientHandsOverARequest() {
        #expect((client as any CobaltClient) is any RemoteFileRequests)
        #expect(!((PreviewClient(scenario: .happy) as any CobaltClient) is any RemoteFileRequests), "previews fetch in the foreground")
    }
}

// MARK: - The foreground path (a client that cannot hand over a request)

@MainActor
@Suite(.serialized)
struct OfflineForegroundTests {
    private func rig(_ hook: @escaping @Sendable (RemoteFile, URL) async throws -> URL) async throws -> (DownloadRig, OfflineDownloads) {
        let t = try DownloadRig()
        let h = Harness(.happy)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = hook
        let engine = OfflineDownloads(store: t.store, queue: t.queue, transport: nil, clock: t.clock, client: { stub })
        engine.markNotNew = { [weak t] keys in t?.notNew.append(keys) }
        return (t, engine)
    }

    @Test func aClientWithoutRequestsFetchesInTheForegroundAndLandsTheSame() async throws {
        let seen = Mutex<[RemoteFile]>([])
        let (t, engine) = try await rig { file, dest in
            seen.withLock { $0.append(file) }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_000).write(to: dest)
            return dest
        }
        let v = try await t.evicted()
        engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1"), .studioSource(session: "S1")])])
        #expect(await eventually { t.store.videos.first { $0.id == v.id }?.isOffline == true && t.queue.all().isEmpty })
        #expect(seen.withLock { $0 } == [.libraryItem(id: "F1")])
        #expect(t.store.videos.first { $0.id == v.id }?.bytes == 4_000)
        #expect(engine.states.isEmpty, "\(engine.states)")
        #expect(t.queue.all().isEmpty, "\(t.queue.all())")
    }

    @Test func aSourceThatSaysGoneMovesOnAndEveryoneGoneIsFailed() async throws {
        let seen = Mutex<[RemoteFile]>([])
        let (t, engine) = try await rig { file, _ in
            seen.withLock { $0.append(file) }
            throw CobaltError.api(code: "error.studio.expired", httpStatus: 410)
        }
        let v = try await t.evicted()
        engine.enqueue([t.existingJob(v, sources: [.libraryItem(id: "F1"), .studioSource(session: "S1")])])
        #expect(await eventually { engine.states["f:F1"] == .failed(.gone) })
        #expect(seen.withLock { $0 } == [.libraryItem(id: "F1"), .studioSource(session: "S1")])
    }

    @Test func foregroundFailuresMapLikeTheBackgroundOnes() async throws {
        let mode = Mutex<Int>(0)
        let (t, engine) = try await rig { _, _ in
            switch mode.withLock({ $0 }) {
            case 0: throw CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)
            case 1: throw CobaltError.network(.notConnectedToInternet)
            default: throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        let v = try await t.evicted()
        engine.enqueue([t.existingJob(v)])
        #expect(await eventually { engine.states["f:F1"] == .failed(.auth) })
        mode.withLock { $0 = 1 }
        engine.enqueue([t.existingJob(v)])
        #expect(await eventually { t.queue.entry("f:F1")?.state == .queued && t.queue.entry("f:F1")?.tries == 1 })
        #expect(engine.states["f:F1"] == .waiting)
        mode.withLock { $0 = 2 }
        await engine.reconcile()
        #expect(await eventually { engine.states["f:F1"] == .failed(.full) })
    }

    @Test func cancellingAForegroundFetchStopsItAndDropsTheEntry() async throws {
        let gate = Gate()
        let (t, engine) = try await rig { _, dest in
            await gate.wait()
            try Data(repeating: 1, count: 100).write(to: dest)
            return dest
        }
        let v = try await t.evicted()
        engine.enqueue([t.existingJob(v)])
        while await gate.waiting == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        engine.cancel(keys: ["f:F1"])
        await gate.open()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(t.store.videos.first { $0.id == v.id }?.place == nil && engine.states.isEmpty && t.queue.all().isEmpty)
    }
}

// MARK: - The real delegate on a real socket

@Suite(.serialized)
struct OfflineURLSessionTests {
    final class EventLog: OfflineDownloadEvents, Sendable {
        private let items = Mutex<[String]>([])
        private let progressed = Mutex<[Int64]>([])
        private let kept = Mutex<[Int: Data]>([:])
        var log: [String] { items.withLock { $0 } }
        var progress: [Int64] { progressed.withLock { $0 } }
        func file(_ task: Int) -> Data? { kept.withLock { $0[task] } }

        func progress(task: Int, label: String, bytes: Int64, total: Int64?) { progressed.withLock { $0.append(bytes) } }
        func finished(task: Int, label: String, status: Int, file: URL) {
            kept.withLock { $0[task] = try? Data(contentsOf: file) }
            items.withLock { $0.append("finished \(label) \(status)") }
        }
        func failed(task: Int, label: String, domain: String, code: Int, resumeData: Data?) {
            items.withLock { $0.append("failed \(label) \(code)") }
        }
        func eventsFinished() {}
    }

    private func wait(_ log: EventLog, for text: String) async -> Bool {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            if log.log.contains(where: { $0.hasPrefix(text) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func session(_ log: EventLog) -> any OfflineSession {
        URLSessionOfflineTransport { _ in .ephemeral }.session(identifier: "test.\(UUID().uuidString)", events: log)
    }

    @Test func progressAndTheFinishArriveOnTheDelegateQueueWithTheBytes() async throws {
        let payload = Data((0..<400_000).map { UInt8($0 % 251) })
        let server = try await LoopbackServer.start { _ in .init(status: 200, body: payload) }
        defer { server.stop() }
        let log = EventLog()
        let s = session(log)
        let task = s.start(URLRequest(url: server.base.appendingPathComponent("file")), label: "k1")
        #expect(await wait(log, for: "finished k1 200"))
        #expect(log.file(task) == payload, "the delegate saw the whole file before the system took it back")
        #expect(log.progress.last == Int64(payload.count))
    }

    @Test func aNon2xxAnswerIsReportedAsItsStatusAndAConnectionErrorAsAFailure() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"error":{"code":"error.library.not_found"}}"#, status: 404) }
        let log = EventLog()
        let s = session(log)
        _ = s.start(URLRequest(url: server.base.appendingPathComponent("nope")), label: "k404")
        #expect(await wait(log, for: "finished k404 404"))
        server.stop()
        _ = s.start(URLRequest(url: server.base.appendingPathComponent("again"), timeoutInterval: 2), label: "kdead")
        #expect(await wait(log, for: "failed kdead"))
    }

    @Test func theKeyDoesNotFollowARedirectToAnotherHost() async throws {
        let server = try await LoopbackServer.start { request in
            if request.path == "/start" {
                var r = LoopbackServer.Response(status: 302)
                r.headers["location"] = request.headers["host"].map { "http://localhost:\($0.split(separator: ":").last ?? "")/final" } ?? "/final"
                return r
            }
            return .init(status: 200, body: Data("ok".utf8))
        }
        defer { server.stop() }
        let log = EventLog()
        let s = session(log)
        var request = URLRequest(url: server.base.appendingPathComponent("start"))
        request.setValue("Api-Key SECRET", forHTTPHeaderField: "Authorization")
        _ = s.start(request, label: "kredir")
        #expect(await wait(log, for: "finished kredir 200"))
        let seen = server.requests
        #expect(seen.count == 2 && seen[0].headers["authorization"] == "Api-Key SECRET")
        #expect(seen[1].path == "/final" && seen[1].headers["authorization"] == nil, "another host never sees the key")
    }
}

// MARK: - Who asked (CONTRACT-OFFLINE.md 13.8): the pull's jobs on the same engine

@MainActor
@Suite(.serialized)
struct PulledOriginTests {
    private final class Seen: Sendable {
        let list = Mutex<[AddOrigin]>([])
        var all: [AddOrigin] { list.withLock { $0 } }
    }

    private func origins(_ t: DownloadRig) -> Seen {
        let seen = Seen()
        t.store.onAdd = { _, origin in seen.list.withLock { $0.append(origin) } }
        return seen
    }

    @Test func aJobHasNoOriginUnlessThePullAsked() {
        let job = OfflineJob(
            key: "f:A", aliases: ["f:A"], target: .existing(id: "x"), sources: [.libraryItem(id: "A")], expectedBytes: nil, fileName: "a.mp4")
        #expect(job.origin == nil && !job.isPulled)
        var pulled = job
        pulled.origin = OfflineJob.pulledOrigin
        #expect(pulled.isPulled && OfflineJob.pulledOrigin == "pulled")
    }

    @Test func aQueueWrittenBeforeOriginsExistedStillDecodesAsTheOwnersKeepOffline() throws {
        let json = #"""
        {"key":"f:A","aliases":["f:A"],"target":{"existing":{"id":"x"}},"sources":[{"libraryItem":{"id":"A"}}],"fileName":"a.mp4"}
        """#
        let job = try JSONDecoder().decode(OfflineJob.self, from: Data(json.utf8))
        #expect(job.origin == nil && !job.isPulled)
        let record = try JSONDecoder().decode(
            OfflineJob.NewRecord.self,
            from: Data(#"{"kind":"original","media":{"name":"n","isImage":false},"createdAt":1,"sessionID":"s"}"#.utf8))
        #expect(record.postItems == nil)
        // and the new fields round-trip
        var again = job
        again.origin = "pulled"
        let back = try JSONDecoder().decode(OfflineJob.self, from: JSONEncoder().encode(again))
        #expect(back == again && back.isPulled)
    }

    @Test func aKeepOfflineDownloadLandsWithOriginKeepOfflineAndAPulledOneWithPulled() async throws {
        let t = try DownloadRig()
        let seen = origins(t)
        t.engine.enqueue([t.newJob(key: "f:K1", sources: [.libraryItem(id: "K1")], session: "KEEP")])
        var pulled = t.newJob(key: "f:P1", sources: [.libraryItem(id: "P1")], session: "PULL")
        pulled.origin = OfflineJob.pulledOrigin
        t.engine.enqueue([pulled])
        let s = try #require(t.session)
        for task in s.tasks { s.respond(task: task.id, status: 200, body: body()) }
        #expect(await eventually(15) { t.queue.all().isEmpty && t.store.videos.count == 2 })
        #expect(seen.all.sorted { "\($0)" < "\($1)" } == [.keepOffline, .pulled])
        #expect(t.store.videos.allSatisfy { $0.keep })
    }

    @Test func aPulledJobOnAnExistingRecordAttachesWithOriginPulled() async throws {
        let t = try DownloadRig()
        let seen = origins(t)
        let v = try await t.evicted()
        var job = t.existingJob(v)
        job.origin = OfflineJob.pulledOrigin
        t.engine.enqueue([job])
        let task = try #require(t.session?.tasks.first)
        t.session?.respond(task: task.id, status: 200, body: body())
        #expect(await eventually(15) { t.store.videos.first { $0.id == v.id }?.isOffline == true && t.queue.all().isEmpty })
        #expect(seen.all.last == .pulled)
    }

    @Test func theFirstItemOfAGalleryThatCarriesThePostsSizeIsFiledInTheGalleryFolder() async throws {
        let t = try DownloadRig()
        func item(_ id: String, postItems: Int?) -> OfflineJob {
            var job = t.job(key: "f:\(id)", target: .new(OfflineJob.NewRecord(
                kind: .original, media: MediaInfo(name: "01", duration: nil, width: 10, height: 10, bytes: nil, isImage: true),
                sessionID: "GAL-\(id)", link: URL(string: "https://www.instagram.com/p/DeKlsGCGZmx/"), remoteURL: nil, publicURL: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), title: nil, mediaID: nil, role: .item, itemIndex: 0,
                madeFrom: nil, madeSpec: nil, libraryID: id, postItems: postItems)),
                sources: [.libraryItem(id: id)])
            job.fileName = "01.jpg"
            return job
        }
        t.engine.enqueue([item("G3", postItems: 3), item("G1", postItems: nil)])
        let s = try #require(t.session)
        for task in s.tasks { s.respond(task: task.id, status: 200, body: body()) }
        #expect(await eventually(15) { t.queue.all().isEmpty && t.store.videos.count == 2 })
        let files = t.rig.visibleFiles()
        #expect(files.count == 2)
        #expect(files.filter { $0.contains("/") }.count == 1, "a gallery of 3 is a folder; the lone item (no size known) stays flat: \(files)")
    }

    @Test func onlyAFailureOfGoneCallsTheEndedHook() async throws {
        let t = try DownloadRig()
        let gone = Mutex<[String]>([])
        t.engine.endedGone = { job in gone.withLock { $0.append(job.key) } }
        let a = try await t.evicted(session: "SA", name: "a"), b = try await t.evicted(session: "SB", name: "b")
        t.engine.enqueue([
            t.existingJob(a, key: "f:A", sources: [.libraryItem(id: "A")]),
            t.existingJob(b, key: "f:B", sources: [.libraryItem(id: "B")]),
        ])
        let s = try #require(t.session)
        s.respond(task: 1, status: 404, body: Data())          // gone
        s.respond(task: 2, status: 401, body: Data())          // auth
        #expect(await eventually(15) { t.engine.states["f:A"] == .failed(.gone) && t.engine.states["f:B"] == .failed(.auth) })
        #expect(gone.withLock { $0 } == ["f:A"])
    }
}
