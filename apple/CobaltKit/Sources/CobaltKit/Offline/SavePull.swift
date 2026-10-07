import Foundation
import Observation

/// The Mac's "saves made anywhere land in the folder" (CONTRACT-OFFLINE.md 13.8, 13.9): a check against the server's
/// library at launch, on every activation and every 5 minutes while the app runs, that downloads what was saved since "keep
/// new saves offline" was turned on, through the engine of "keep offline" (`OfflineDownloads`, origin `pulled`), kept, into
/// the Mac folder.
///
/// What it fetches: a library file is a candidate when it was created after the baseline (`PullLedger.enabledAt`), the
/// ledger has never decided it (`done`), its rendition in the merged `MediaItem` has no local record at all (a record,
/// with or without a file, means this Mac saved, kept, pulled or was told to forget it), its session is not in flight here
/// (deferred, not decided), and there is somewhere to fetch it from. A candidate is written `done` in the same step it is
/// handed over; done is forever, whatever happens to the file after.
///
/// What it does not do: check while the app is closed (the app quits when its window closes), fetch while paused (see
/// `Paused`), or fetch the library that existed when the pull was first turned on.
///
/// Platform-neutral CobaltKit; `isAvailable` is true where the store's root is the Mac's folder (`.macFolder`) only.
@MainActor @Observable
public final class SavePull {
    /// Why the pull is not checking. `waiting`: one check found more new saves than it fetches unasked
    /// (`SavePull.defaultMassLimit`); `status.waiting` says how many, and `downloadWaiting()` / `skipWaiting()` answer. `diskLow`: the
    /// folder's disk has less than `SavePull.minFreeBytes` free.
    public enum Paused: Sendable, Equatable { case keepOff, folderUnreachable, auth, noServer, waiting, diskLow }

    public struct Status: Sendable, Equatable {
        public var available: Bool
        public var lastChecked: Date?
        public var paused: Paused?
        /// downloads under way that this pull started
        public var pulling: Int
        /// new saves held back by the mass-pull brake, waiting for "download them" or "skip" (0: none)
        public var waiting: Int

        public init(available: Bool = false, lastChecked: Date? = nil, paused: Paused? = nil, pulling: Int = 0, waiting: Int = 0) {
            self.available = available
            self.lastChecked = lastChecked
            self.paused = paused
            self.pulling = pulling
            self.waiting = waiting
        }
    }

    // MARK: - Seams

    /// What a check reads and calls. `AppModel` wires the live ones (`wire(_:)`); tests pass their own.
    struct Environment {
        var capabilities: @MainActor () -> Capabilities
        var keepOn: @MainActor () -> Bool
        /// One library request: the page after `cursor` (nil = the newest) of at most `limit` posts.
        var page: @MainActor (_ cursor: String?, _ limit: Int) async throws -> LibraryPage
        /// A studio session this app still follows or holds (13.9 layer 1).
        var holdsSession: @MainActor (String) -> Bool
        /// A file upload is on the wire from this Mac (its library row may exist before the run knows its id).
        var uploadsInFlight: @MainActor () -> Bool
        /// The library ids of uploads this Mac's runs made.
        var ownUploads: @MainActor () -> [String]
        /// The library the baseline belongs to.
        var serverID: @MainActor () -> String
        /// The key that is in use (a refusal is sticky until it changes).
        var apiToken: @MainActor () -> String?
        /// Free bytes on the folder's disk (nil: unknown, so never "low").
        var freeBytes: @MainActor () -> Int64? = { nil }
    }

    /// The cadence of the tick (13.8): every 5 minutes, tolerance 60 s.
    static let interval: TimeInterval = 300
    static let tolerance: TimeInterval = 60
    /// A quiet check asks for this many posts.
    static let quietLimit = 5
    /// A busier walk pages by this many.
    static let pageLimit = 30
    /// At most this many pages per check (13.8). What a capped check did not reach is a backlog the next check carries on from.
    static let defaultMaxPages = 10
    /// A walk starts this far below the watermark (inserts can arrive out of order; `done` dedupes).
    static let overlap: TimeInterval = 10 * 60
    /// More new saves than this in one check are not fetched unasked (wave M review S5): the owner says "download them" or "skip".
    static let defaultMassLimit = 20
    /// The pull pauses while the folder's disk has less than this free (wave M review, nits).
    static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// A new baseline is checked against the server's own dates only by a check this soon after it (S2): later, a save made on
    /// another device in the meantime would be mistaken for one that already existed.
    static let calibrationWindow: TimeInterval = 120

    // MARK: - State

    @ObservationIgnored private let store: OfflineStore?
    @ObservationIgnored private let ledger: PullLedger?
    @ObservationIgnored private let downloads: OfflineDownloads?
    @ObservationIgnored private let clock: any PipelineClock
    @ObservationIgnored private let scheduler: (any PullScheduling)?
    @ObservationIgnored private let maxPages: Int
    @ObservationIgnored private let massLimit: Int
    @ObservationIgnored private var env: Environment?
    @ObservationIgnored private var tick: (any PullCancelling)?
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var hasChecked = false
    @ObservationIgnored private var lastPaused: Paused?
    @ObservationIgnored private var pulledKeys: Set<String> = []
    /// The first page the calibration read, which the walk then uses as its own first request.
    @ObservationIgnored private var firstPage: LibraryPage?
    var previewStatus: Status?

    /// The mass-pull brake as the ledger holds it (cached: `status` is read on every redraw).
    private var brake: PullBrake?
    /// The folder's disk is under `minFreeBytes` (measured at the start of every check).
    private var diskLow = false

    /// When the last check finished against the server.
    public private(set) var lastChecked: Date?
    /// A 401/403 from the library: the key it was refused with. The pull does not ask again until the key changes (or
    /// `resume()`).
    private var refusedToken: String?

    public var status: Status {
        if let previewStatus { return previewStatus }
        guard let store, store.rootMode == .macFolder else { return Status(available: false) }
        return Status(
            available: true, lastChecked: lastChecked, paused: pauseReason(), pulling: pullingCount, waiting: brake?.saves ?? 0)
    }

    public var isAvailable: Bool { status.available }

    init(
        store: OfflineStore, ledger: PullLedger? = nil, downloads: OfflineDownloads? = nil, clock: any PipelineClock = SystemClock(),
        scheduler: (any PullScheduling)? = nil, environment: Environment? = nil, maxPages: Int = SavePull.defaultMaxPages,
        massLimit: Int = SavePull.defaultMassLimit
    ) {
        self.maxPages = maxPages
        self.massLimit = massLimit
        self.store = store
        self.ledger = ledger
        self.downloads = downloads
        self.clock = clock
        self.scheduler = scheduler
        self.env = environment
        let stored = ledger?.read()
        self.lastChecked = stored?.lastCheck
        self.brake = stored?.brake
        refreshPulledKeys()
        downloads?.endedGone = { [weak self] job in self?.endedGone(job) }
    }

    private init(preview: Status) {
        self.store = nil
        self.ledger = nil
        self.downloads = nil
        self.clock = SystemClock()
        self.scheduler = nil
        self.maxPages = Self.defaultMaxPages
        self.massLimit = Self.defaultMassLimit
        self.previewStatus = preview
    }

    /// `AppModel` hands over what a check needs to read (it exists only after the model does).
    func wire(_ environment: Environment) {
        guard previewStatus == nil else { return }
        env = environment
    }

    // MARK: - Starting

    /// The 5 minute tick, while the app runs. A no-op where the pull is not available, and when already running.
    public func start() {
        guard previewStatus == nil, tick == nil, store?.rootMode == .macFolder, let scheduler else { return }
        tick = scheduler.start(interval: Self.interval, tolerance: Self.tolerance) { [weak self] in
            // the system calls this on its own queue: hop to the main actor explicitly
            Task { @MainActor in await self?.check() }
        }
    }

    public func stop() {
        tick?.cancel()
        tick = nil
    }

    // MARK: - Settings changes

    /// "keep new saves offline" changed. Off forgets the baseline; on takes a new one (saves made while it was off are not
    /// fetched) and checks.
    func keepChanged(_ on: Bool) {
        guard previewStatus == nil, store?.rootMode == .macFolder, let ledger, let env else { return }
        if on {
            ledger.rebaseline(now: clock.now(), server: env.serverID())
            brake = nil
            refusedToken = nil
            Task { @MainActor in await self.check() }
        } else {
            ledger.disarm()
            brake = nil
        }
    }

    /// Another server is another library: a new baseline, nothing it holds is fetched.
    func serverChanged() {
        guard previewStatus == nil, store?.rootMode == .macFolder, let ledger, let env else { return }
        refusedToken = nil
        if env.keepOn() { ledger.rebaseline(now: clock.now(), server: env.serverID()) }
        brake = nil
        lastPaused = .noServer                                       // the new server's answer runs the next check
    }

    /// Uploads this Mac's runs made (library ids): remembered, never fetched back.
    func noteOwnUploads(_ ids: [String]) {
        guard previewStatus == nil, store?.rootMode == .macFolder, !ids.isEmpty else { return }
        ledger?.noteOwn(ids, now: clock.now())
    }

    /// The server answered (or the key changed): a check that was waiting on it runs.
    func capabilitiesChanged() {
        guard previewStatus == nil, store?.rootMode == .macFolder, let env else { return }
        if let refused = refusedToken, refused != (env.apiToken() ?? "") { refusedToken = nil }
        guard !hasChecked || lastPaused == .noServer || lastPaused == .auth else { return }
        Task { @MainActor in await self.check() }
    }

    /// Settings opened: an auth pause is lifted and the library is asked once more.
    public func resume() async {
        refusedToken = nil
        await check()
    }

    /// "download them" (S5): the saves a check held back are fetched by the next check, which runs now.
    public func downloadWaiting() async { await answerBrake(.download) }

    /// "skip" (S5): the saves a check held back are never fetched (a save made after them still is).
    public func skipWaiting() async { await answerBrake(.skip) }

    private func answerBrake(_ choice: PullBrake.Choice) async {
        guard previewStatus == nil, let ledger, brake != nil else { return }
        ledger.chooseBrake(choice)
        brake = ledger.read().brake
        await check()
    }

    // MARK: - Pausing

    private func pauseReason() -> Paused? {
        guard let env, let store else { return .noServer }
        if !env.keepOn() { return .keepOff }
        if store.rootState != .ready { return .folderUnreachable }
        let caps = env.capabilities()
        if caps.key == .invalid { return .auth }
        if let refused = refusedToken, refused == (env.apiToken() ?? "") { return .auth }
        if caps.key == .missing { return .noServer }
        if caps.kind == .unreachable && caps.key == .unknown { return .noServer }       // never reached the server
        if !caps.library { return .noServer }                                          // nothing to list
        if let brake, brake.choice == nil { return .waiting }                          // held back: the owner decides
        if diskLow { return .diskLow }
        return nil
    }

    private var pullingCount: Int {
        guard let downloads else { return 0 }
        var n = 0
        for key in pulledKeys {
            switch downloads.states[key] {
            case .waiting?, .downloading?: n += 1
            default: break
            }
        }
        return n
    }

    // MARK: - A check

    /// One check, now (13.8): arms the baseline when this is the first one, walks the library newest first until it reaches
    /// what it has seen, and hands what is new to the download engine. Does nothing while paused, while another check
    /// runs, or on a platform without a folder. A network failure is not a pause: the next tick tries again.
    public func check() async {
        guard previewStatus == nil, let store, store.rootMode == .macFolder, let ledger, let downloads, let env else { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        hasChecked = true

        let now = clock.now()
        var file = ledger.read()
        if !env.keepOn() {
            if file.enabledAt != nil { ledger.disarm() }              // a switch off outside `keepChanged`: the next on rebaselines
            brake = nil
            lastPaused = .keepOff
            return
        }
        if file.enabledAt == nil || file.server != env.serverID() {
            ledger.rebaseline(now: now, server: env.serverID())       // the first check, or another library
            brake = nil
            file = ledger.read()
        }
        refreshPulledKeys()
        ledger.noteOwn(env.ownUploads(), now: now)
        measureDisk(env: env)
        if let paused = pauseReason() {
            lastPaused = paused
            return
        }
        lastPaused = nil

        do {
            guard let enabledAt = try await calibrated(file, now: now, env: env, ledger: ledger) else { return }
            try await walk(env: env, store: store, ledger: ledger, downloads: downloads, enabledAt: enabledAt)
        } catch is CancellationError {
            return
        } catch {
            failed(error, env: env, ledger: ledger)
        }
    }

    /// S2: the baseline was taken from the Mac's clock. A check right after it asks the library for its first page and raises the
    /// baseline to the newest file on it, so a Mac clock that runs behind the server's does not mistake the library's own last
    /// hour for new saves. Only a check within `calibrationWindow` of the baseline does: later, a save made on another device in
    /// the meantime would look like the library's own. The page is kept for the walk (one request, not two). Nil: the world moved
    /// while it ran (nothing is written).
    private func calibrated(_ file: PullFile, now: Date, env: Environment, ledger: PullLedger) async throws -> Date? {
        let enabledAt = file.enabledAt ?? now
        guard file.calibrate else { return enabledAt }
        guard now.timeIntervalSince(enabledAt) <= Self.calibrationWindow else {
            return ledger.calibrate(floor: nil) ?? enabledAt
        }
        let page = try await env.page(nil, Self.quietLimit)
        guard ledger.read().enabledAt == file.enabledAt, pauseReason() == nil else { return nil }
        var newest: Date?
        for post in page.posts {
            newest = max(newest ?? post.createdAt, post.createdAt)
            for f in post.files { newest = max(newest ?? f.createdAt, f.createdAt) }
        }
        firstPage = page
        return ledger.calibrate(floor: newest) ?? enabledAt
    }

    /// Reads the folder's free space (the volume of the root) once per check.
    private func measureDisk(env: Environment) {
        let low = env.freeBytes().map { $0 < Self.minFreeBytes } ?? false
        if low != diskLow { diskLow = low }
    }

    private func failed(_ error: Error, env: Environment, ledger: PullLedger) {
        var refused = false
        var problem = "network"
        switch error {
        case CobaltError.api(let code, let status):
            refused = status == 401 || status == 403 || code.hasPrefix("error.api.auth.")
            problem = refused ? "auth" : "server \(status)"
        case CobaltError.invalidResponse(let status):
            refused = status == 401 || status == 403
            problem = refused ? "auth" : "server \(status)"
        case CobaltError.noAPIKey:
            problem = "no key"
        default:
            break
        }
        if refused {
            refusedToken = env.apiToken() ?? ""
            lastPaused = .auth
        }
        ledger.setProblem(problem)
        Telemetry.log(.warn, .sync, "pull check failed", data: ["reason": .string(problem)])
    }

    // MARK: - The walk

    /// What a walk reads and writes.
    private struct Walk {
        var env: Environment
        var store: OfflineStore
        var ledger: PullLedger
        var downloads: OfflineDownloads
        var enabledAt: Date
        /// what the walk found worth fetching, handed to the engine only once the whole walk is known (the brake looks at all of it)
        var found: Found
    }

    /// One rendition to fetch.
    private struct Candidate {
        var job: OfflineJob
        var ids: [String]
        var at: Date
        var post: String
    }

    /// The candidates of one check, in walk order.
    @MainActor private final class Found {
        var candidates: [Candidate] = []
        var ids: Set<String> = []
    }

    /// One run down the library from `cursor` to a stop line.
    private struct Scan {
        /// reached the stop line, or the end of the library
        var complete = false
        /// where the next page would start, when the page budget ran out first
        var next: String?
        /// the first page that had a post held back (a backlog segment starts there again), when it was not the first
        var resume: String?
        var newest: Date?
        var deferred: Date?
        var skipped = 0
        var pages = 0
    }

    /// Newest first, down to the stop line (13.8): a quiet check is one request of 5 posts; while every post on a page is newer
    /// than the stop line the next page (30) is fetched, `maxPages` in all. The stop line is the baseline or the watermark less
    /// an overlap, whichever is later. What a capped walk did not reach is a backlog segment the next check carries on from, so
    /// a long absence is caught up over several checks and the newest saves are never waiting behind it.
    ///
    /// What it finds is gathered, not fetched, until the whole walk is done: more than `massLimit` saves at once are held back
    /// for the owner (S5), and nothing is written to the ledger but the brake (the watermark stays, so the walk that carries out
    /// the owner's answer finds them again).
    private func walk(
        env: Environment, store: OfflineStore, ledger: PullLedger, downloads: OfflineDownloads, enabledAt: Date
    ) async throws {
        let w = Walk(env: env, store: store, ledger: ledger, downloads: downloads, enabledAt: enabledAt, found: Found())
        let start = ledger.read()
        let stopLine = max(enabledAt, (start.watermark ?? .distantPast).addingTimeInterval(-Self.overlap))
        var budget = maxPages
        guard let top = try await scan(w, from: nil, limit: Self.quietLimit, stopLine: stopLine, budget: &budget) else { return }

        var segments = start.backlog
        if !top.complete, let next = top.next { segments.insert(PullSegment(cursor: next, floor: stopLine), at: 0) }
        var remaining: [PullSegment] = []
        var skipped = top.skipped, pages = top.pages
        var deferred = top.deferred != nil
        for segment in segments {
            guard budget > 0 else { remaining.append(segment); continue }
            guard let r = try await scan(w, from: segment.cursor, limit: Self.pageLimit, stopLine: segment.floor, budget: &budget) else { return }
            skipped += r.skipped
            pages += r.pages
            if r.deferred != nil { deferred = true }
            if let resume = r.resume { remaining.append(PullSegment(cursor: resume, floor: segment.floor)) }      // something is held
            else if !r.complete, let next = r.next { remaining.append(PullSegment(cursor: next, floor: segment.floor)) }
        }

        let now = clock.now()
        // the walk is over: what it found is fetched, skipped or held back
        let outcome = settle(w.found.candidates, ledger: ledger, downloads: downloads, brake: start.brake)
        if case .held(let held) = outcome {
            ledger.setBrake(held)
            brake = held
            ledger.finishCheck(now: now, watermark: nil, backlog: start.backlog, problem: nil, markSeen: true)
            lastChecked = now
            Telemetry.log(.info, .sync, "pull held back", data: ["saves": .int(held.saves), "files": .int(held.files)])
            return
        }
        if start.brake != nil { ledger.setBrake(nil); brake = nil }

        var watermark: Date?
        if var mark = top.newest {
            if let held = top.deferred { mark = min(mark, held.addingTimeInterval(-1)) }       // a held save is looked at again
            watermark = max(enabledAt, mark)
        }
        ledger.finishCheck(now: now, watermark: watermark, backlog: remaining, problem: nil, markSeen: true)
        lastChecked = now
        Telemetry.log(.info, .sync, "pull checked", data: [
            "pages": .int(pages), "queued": .int(outcome.queued), "skipped": .int(skipped + outcome.skipped), "complete": .bool(top.complete),
            "backlog": .int(remaining.count), "deferred": .bool(deferred)])
    }

    private enum Settled {
        case done(queued: Int, skipped: Int)
        case held(PullBrake)

        var queued: Int { if case .done(let q, _) = self { return q } else { return 0 } }
        var skipped: Int { if case .done(_, let s) = self { return s } else { return 0 } }
    }

    /// What a walk found: handed to the engine (the engine first, then the ledger, in one step: a crash between them can only
    /// re-offer a rendition the queue already holds, never lose one), or, when there are more saves than `massLimit` and the
    /// owner has not answered, held back. The owner's answer: "download them" fetches everything found; "skip" writes what was
    /// held (up to the newest file it held) as skipped and treats anything newer as a check of its own.
    private func settle(_ found: [Candidate], ledger: PullLedger, downloads: OfflineDownloads, brake answered: PullBrake?) -> Settled {
        var fetch = found
        var skipped = 0
        if answered?.choice == .skip, let upTo = answered?.upTo {
            for c in found where c.at <= upTo { ledger.record(c.ids, at: c.at, state: .skipped, why: "owner") }
            skipped = found.filter { $0.at <= upTo }.count
            fetch = found.filter { $0.at > upTo }
        }
        if answered?.choice != .download {
            let saves = Set(fetch.map(\.post)).count
            if saves > massLimit {
                return .held(PullBrake(saves: saves, files: fetch.count, upTo: fetch.map(\.at).max() ?? clock.now(), choice: nil))
            }
        }
        if !fetch.isEmpty {
            downloads.enqueue(fetch.map(\.job))
            for c in fetch { pulledKeys.insert(c.job.key) }
            for c in fetch { ledger.record(c.ids, at: c.at, state: .queued) }
        }
        return .done(queued: fetch.count, skipped: skipped)
    }

    /// Nil when the world moved while a request ran (a new baseline, a switch off, the folder gone): nothing is written.
    private func scan(_ w: Walk, from start: String?, limit firstLimit: Int, stopLine: Date, budget: inout Int) async throws -> Scan? {
        var s = Scan()
        var cursor = start
        var limit = firstLimit
        var prefetched = start == nil ? firstPage : nil              // the calibration already asked for the first page
        if start == nil { firstPage = nil }
        while true {
            guard budget > 0 else {
                s.next = cursor
                return s
            }
            let page: LibraryPage
            if let pre = prefetched {
                page = pre
                prefetched = nil
            } else {
                page = try await w.env.page(cursor, limit)
            }
            budget -= 1
            s.pages += 1
            guard w.ledger.read().enabledAt == w.enabledAt, pauseReason() == nil else { return nil }
            var heldHere = false
            for post in page.posts {
                s.newest = max(s.newest ?? post.createdAt, post.createdAt)
                if post.createdAt <= stopLine {
                    s.complete = true
                    return s
                }
                let r = evaluate(post, w, stopLine: stopLine)
                s.skipped += r.skipped
                if let d = r.deferredAt {
                    s.deferred = min(s.deferred ?? d, d)
                    heldHere = true
                }
            }
            if heldHere, s.resume == nil, let here = cursor { s.resume = here }
            guard let next = page.next, !page.posts.isEmpty else {
                s.complete = true
                return s
            }
            cursor = next
            limit = Self.pageLimit
        }
    }

    private struct PostResult {
        var skipped = 0
        var deferredAt: Date?
    }

    /// One post of the page: the renditions that are candidates are gathered for the walk's end; the ones this Mac already has
    /// (or made) are written `skipped`; the ones that wait for a session in flight change nothing.
    ///
    /// A file is a candidate only when it is newer than the walk's stop line (S1). The post is reached because its newest file is
    /// new, but the post's older files were seen by an earlier check (or are the library's own, from before the baseline): a file
    /// the owner removed from this Mac must not come back because its post got a new file.
    private func evaluate(_ post: LibraryPost, _ w: Walk, stopLine: Date) -> PostResult {
        let env = w.env, store = w.store, ledger = w.ledger, enabledAt = w.enabledAt
        var result = PostResult()
        let known = ledger.read()
        let local = store.media.first { MediaItem.joins($0, post) }
        guard let item = MediaItem.merge(local: local, post: post) else { return result }
        let now = clock.now()
        let held = holds(post, env: env)
        let mediaBase = env.capabilities().mediaBaseURL
        var settled: [(ids: [String], at: Date, why: String)] = []
        for r in item.renditions {
            guard let primary = r.file ?? r.hosted else { continue }             // only what the library lists
            let ids = r.serverFileIDs
            guard primary.createdAt > enabledAt, primary.createdAt > stopLine else { continue }      // from now on, and not seen before
            if ids.contains(where: { known.done[$0] != nil || w.found.ids.contains($0) }) { continue }       // decided, forever
            if r.local != nil {                                                  // 13.8: a record means seen here
                settled.append((ids, primary.createdAt, "local"))
                continue
            }
            let isUpload = primary.source == .upload
            if isUpload, known.own[primary.id] != nil {                          // 13.9: this Mac made it
                settled.append((ids, primary.createdAt, "own"))
                continue
            }
            if held || (isUpload && env.uploadsInFlight()) {                     // 13.9 layer 1: deferred, not decided
                result.deferredAt = min(result.deferredAt ?? primary.createdAt, primary.createdAt)
                continue
            }
            guard var job = OfflineSources.job(for: r, in: item, mediaBase: mediaBase, now: now) else { continue }
            job.origin = OfflineJob.pulledOrigin
            w.found.candidates.append(Candidate(job: job, ids: ids, at: primary.createdAt, post: post.id))
            w.found.ids.formUnion(ids)
        }
        for entry in settled { ledger.record(entry.ids, at: entry.at, state: .skipped, why: entry.why) }
        result.skipped = settled.count
        return result
    }

    /// 13.9 layer 1: a run of this app follows the post's session (a save, a render, an upload being read), or the post is
    /// the upload's own id while the run has it.
    private func holds(_ post: LibraryPost, env: Environment) -> Bool {
        if env.holdsSession(post.id) { return true }
        if let session = post.session, env.holdsSession(session.id) { return true }
        return false
    }

    // MARK: - Bookkeeping

    /// The queue's pulled entries (what `pulling` counts); a launch finds the ones a last run left.
    private func refreshPulledKeys() {
        guard let downloads else { return }
        pulledKeys = Set(downloads.queue.all().filter { $0.job.isPulled }.map(\.key))
    }

    /// A pulled download that ended `gone`: its ledger entry reads `skipped`.
    private func endedGone(_ job: OfflineJob) {
        guard job.isPulled, let ledger else { return }
        // the queue's keys are `f:<library file id>`; the ledger's are the bare ids
        ledger.markGone((job.aliases + [job.key]).compactMap { $0.hasPrefix("f:") ? String($0.dropFirst(2)) : nil })
    }

    // MARK: - Previews

    /// No disk, no network: for `#Preview`s and `AppModel.preview`.
    public static func preview(_ status: Status) -> SavePull { SavePull(preview: status) }

    /// Replaces a preview instance's status. No effect on the real one.
    public func setPreviewStatus(_ status: Status) {
        guard previewStatus != nil else { return }
        previewStatus = status
    }
}

// MARK: - The tick

/// What stops a tick.
@MainActor protocol PullCancelling: AnyObject { func cancel() }

/// Something that calls `fire` every `interval` seconds until cancelled. `fire` is `@Sendable`: the system calls it on its own
/// queue, and what it does is hop to the main actor.
@MainActor protocol PullScheduling {
    func start(interval: TimeInterval, tolerance: TimeInterval, fire: @escaping @Sendable () -> Void) -> any PullCancelling
}

/// The app's: a `Timer` on the main run loop with a tolerance, so the system may coalesce it (13.8; no power assertion, App Nap
/// may stretch it).
@MainActor
struct TimerScheduler: PullScheduling {
    private final class Tick: PullCancelling {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }

    func start(interval: TimeInterval, tolerance: TimeInterval, fire: @escaping @Sendable () -> Void) -> any PullCancelling {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return Tick(timer)
    }
}

/// A tick driven by a `PipelineClock`: tests run it on the virtual clock.
@MainActor
struct ClockScheduler: PullScheduling {
    let clock: any PipelineClock

    private final class Tick: PullCancelling {
        private let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    func start(interval: TimeInterval, tolerance: TimeInterval, fire: @escaping @Sendable () -> Void) -> any PullCancelling {
        let clock = clock
        return Tick(Task {
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: interval) } catch { return }
                guard !Task.isCancelled else { return }
                fire()
            }
        })
    }
}

// MARK: - AppModel

extension AppModel {
    /// "keep new saves offline": writes the setting. Turning it on takes a new baseline for the pull (13.8): saves made while
    /// it was off are not fetched; turning it off forgets the baseline.
    public func setKeepNewSaves(_ on: Bool) {
        let was = settings.keepVideosOnDevice
        settings.keepVideosOnDevice = on
        if was != on { savePull.keepChanged(on) }
    }

    /// Whether this session is in flight here and a download of it would be a second copy (13.9 layer 1): a run of the queue
    /// follows it (live, or finished but still fetching the original into the store: the library lists the post before the
    /// record lands), a detached run still has work on it, a share job of it is saving, rendering or uploading, or a pending
    /// original holds it.
    func holdsSession(_ id: String) -> Bool {
        func fetchingOriginal(_ p: Pipeline) -> Bool { p.sessionID == id && p.keepRequest != nil }
        if queue.jobs.contains(where: { ($0.isLive && $0.pipeline.sessionID == id) || fetchingOriginal($0.pipeline) }) { return true }
        if fetchingOriginal(queue.idlePipeline) { return true }
        if ctx.background.detached.contains(where: { $0.sessionID == id }) { return true }
        return store.sessionIsHeld?(id) == true
    }

    /// The library ids of the files this Mac's runs uploaded (`PUT /studio/upload` answers the new file's id, which is the
    /// post's key). An image upload leaves no record in the store that could say whose it is.
    var ownUploadIDs: [String] {
        queue.jobs.compactMap { $0.pipeline.uploadedItemID }
    }

    /// A run of this Mac has a file on the wire: the library may list it before the run is told its id.
    var uploadIsInFlight: Bool {
        queue.jobs.contains { job in
            if case .uploading = job.pipeline.state { return job.pipeline.uploadedItemID == nil }
            return false
        }
    }

    /// What a check reads: the settings, the capabilities, the library, the runs of this app.
    func pullEnvironment() -> SavePull.Environment {
        let ctx = ctx
        return SavePull.Environment(
            capabilities: { [weak self] in self?.capabilities ?? .unknown },
            keepOn: { [weak self] in self?.settings.keepVideosOnDevice ?? false },
            page: { cursor, limit in try await ctx.libraryPage(cursor: cursor, limit: limit) },
            holdsSession: { [weak self] id in self?.holdsSession(id) ?? false },
            uploadsInFlight: { [weak self] in self?.uploadIsInFlight ?? false },
            ownUploads: { [weak self] in self?.ownUploadIDs ?? [] },
            serverID: { [weak self] in self?.settings.serverURL.absoluteString ?? "" },
            apiToken: { [weak self] in
                guard let settings = self?.settings else { return nil }
                return Settings.apiKey(in: settings.keychain, forServer: settings.serverURL)
            },
            freeBytes: { [weak self] in self?.store.visibleRoot.flatMap { Self.freeBytes(at: $0) } })
    }

    /// Free bytes on the volume `url` is on (what the system would let an app use: purgeable space counts); nil when unknown.
    nonisolated static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map { Int64($0) }
    }

    /// Notes the uploads this Mac makes as they are accepted, so the pull never brings one back (an image upload leaves no
    /// record in the store that could say whose it is). A finished run stays in the queue for a few seconds, and every change
    /// to the queue's jobs (a run finishing included) is heard here; a check reads them too.
    func watchOwnUploads() {
        guard savePull.isAvailable else { return }                 // the iPhone has no pull to tell
        withObservationTracking {
            _ = queue.jobs
        } onChange: { [weak self] in
            // called as the change starts: look after it has been made, and listen again
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.savePull.noteOwnUploads(self.ownUploadIDs)
                self.watchOwnUploads()
            }
        }
    }
}
