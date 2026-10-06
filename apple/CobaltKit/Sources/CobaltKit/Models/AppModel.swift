import Foundation
import Observation
import UserNotifications

public enum AppTab: String, Sendable, CaseIterable { case save, library, settings }

public enum PreviewScenario: String, Sendable, CaseIterable {
    case happy, coldStart, noLink, privatePost, tooBig, renderBusy, renderLost, picker, image,
         shortClip, plainCobalt, legacyFork, revokedKey, emptyOrbit
    /// The media with three webps, a webp-only media and a plain save (CONTRACT-MEDIA 4.4); a render
    /// adds a webp with a link of its own, and "delete everything" answers partial, then done.
    case renditions
    /// `.renditions` on an older deploy of this fork: no `features.delete_post`, so "delete everything"
    /// deletes the webps one by one (CONTRACT-MEDIA 1.12 (a)).
    case renditionsLegacy
    /// `.renditions` where the first `setTitle` for item `PrEvIeWitem000008` fails (rename revert path).
    case renameFails
    /// "keep offline" (CONTRACT-OFFLINE.md): a media kept in full, one kept in part (its video kept, its webp
    /// server-only), one downloading at 40 %, one that failed (gone), one that cannot be fetched (a plain save
    /// with no server copy), and Settings numbers for the two tiers.
    case offline
    /// Galleries (apple/CONTRACT-GALLERY.md; boards `Gallery-Paste`, `Gallery-Combine`): the server has `features.gallery`
    /// and `gallery_make`, and resolves a multi-item post. `galleryInstagram`: 10 photos (`instagram.com/p/Ddy0-gpGg5U`);
    /// `galleryX`: 4 photos of an X post; `galleryMixed`: 2 photos, a 12.4 s video and a 3.2 s gif; `galleryOne`: a single
    /// photo; `galleryPartial`: 10 photos of which the 7th cannot be fetched until `retryItems`; `galleryNoMake`: a server
    /// with `gallery` but not `gallery_make`; `galleryMakeFails`: 10 photos, and the first make fails
    /// (`error.webp.encode_failed`), the second works.
    case galleryInstagram, galleryX, galleryMixed, galleryOne, galleryPartial, galleryNoMake, galleryMakeFails
}

public struct ServerSummary: Sendable, Equatable {
    public var host: String                               // "api.capybaraharmony.com"
    public var kind: ServerKind
    public var version: String?
    public var features: [String]                         // ["studio", "library"] (feature names, lowercase)
    public var key: KeyState
    public var keyName: String?
}

@MainActor @Observable
public final class AppModel {
    public let settings: Settings
    public let store: OfflineStore
    public let jobs: SharedJobStore
    public let library: LibraryModel
    /// The photos album (CONTRACT-SYNC.md): `PhotosSync.preview(_:)` in previews.
    public let photosSync: PhotosSync
    /// "save to a folder" (macOS; the Mac's counterpart of the photos album, Folder/FolderSync.swift):
    /// unavailable on iOS and in previews, which get `FolderSync.preview(_:)`.
    public let folderSync: FolderSync
    /// "keep offline" (CONTRACT-OFFLINE.md decision 9): the background downloads and their states.
    public let offlineDownloads: OfflineDownloads
    public internal(set) var capabilities: Capabilities
    public internal(set) var isCheckingServer: Bool = false
    /// Every run of the app (CONTRACT-PARALLEL.md): the jobs, which one is focused, the tray's order, the lines.
    public let queue: JobQueue
    /// What the focus screens read: the focused job's pipeline, or an idle one when nothing is focused. A run started
    /// on it by hand becomes the focused job at once.
    public var pipeline: Pipeline { queue.focused?.pipeline ?? queue.idlePipeline }
    public var selectedTab: AppTab = .save

    /// A stored media a run link asks the home screen to open (CONTRACT-SHARE-QUICK.md R3): set by
    /// `openRunLink` when the run it names has settled and its original is in the store; the home screen
    /// opens that media's detail and sets this back to nil.
    public var requestedMediaID: String?

    /// `cobalt-apple://jobs` (the Hark summary for a batch, APP-API-CONTRACT 17.8) asks the save tab to show the tray
    /// (iPhone: the pill's cards; the Mac's tray is already on screen). The view that shows it sets this back to false.
    public var requestedJobs = false

    /// Live Activities (iOS only; nil on the Mac, in previews and in tests unless one is injected).
    @ObservationIgnored var liveManager: LiveActivityManager?

    /// Crash reports and logs to the owner's server; nil in previews and tests.
    @ObservationIgnored public internal(set) var telemetry: TelemetryService?

    /// Keeps a run going after the app leaves the screen (iOS 26 continued processing); nil on the
    /// Mac, in previews and in tests unless one is injected.
    @ObservationIgnored var continuedProcessing: ContinuedProcessing?
    @ObservationIgnored var lifecycleObservers: [any NSObjectProtocol] = []

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let makeClient: @MainActor (Settings) -> any CobaltClient

    init(
        context: PipelineContext, library: LibraryModel, photosSync: PhotosSync? = nil, folderSync: FolderSync? = nil,
        offlineDownloads: OfflineDownloads? = nil, ledger: JobLedger? = nil,
        makeClient: @escaping @MainActor (Settings) -> any CobaltClient
    ) {
        let sync = photosSync ?? PhotosSync.preview(.init(access: .notAsked, enabled: false))
        self.photosSync = sync
        let folder = folderSync ?? FolderSync.preview(.init(available: false, enabled: false))
        self.folderSync = folder
        // Previews and tests fetch in the foreground (no background session); the app passes its own engine.
        let offline = offlineDownloads ?? OfflineDownloads(
            store: context.store,
            queue: OfflineQueue(directory: context.store.root.deletingLastPathComponent().appendingPathComponent("Sync", isDirectory: true)),
            transport: nil, clock: context.clock, client: { context.client }, isPreview: context.isPreview)
        offline.markNotNew = { [sync, folder] keys in
            sync.markNotNew(keys)
            await folder.markNotNew(keys)
        }
        offline.landed = { [sync] in await sync.refresh() }
        self.offlineDownloads = offline
        context.photosSync = sync
        self.ctx = context
        self.settings = context.settings
        self.store = context.store
        self.jobs = context.jobs
        self.library = library
        self.capabilities = context.capabilities
        // Jobs that have no server session yet (CONTRACT-PARALLEL.md 3.5); previews and tests keep theirs beside the store.
        self.queue = JobQueue(
            context: context,
            ledger: ledger ?? JobLedger(
                fileURL: context.store.root.deletingLastPathComponent().appendingPathComponent("job-ledger.json"),
                now: { [clock = context.clock] in clock.now() }))
        self.makeClient = makeClient
        context.keyRejected = { [weak self] in self?.markKeyInvalid() }
        context.capabilitiesChanged = { [weak self] caps in self?.apply(caps) }
        // a gallery saved, or something made from one: the library re-reads the post (its items, its tabs)
        context.galleryChanged = { [weak self] in
            guard let self, self.capabilities.library, self.capabilities.gallery else { return }
            Task { await self.library.refresh() }
        }
        context.libraryDropped = { [weak self] ids in self?.library.drop(files: Set(ids)) }
    }

    /// The real app: app-group stores, the keychain, the configured server.
    public static func live() -> AppModel {
        Telemetry.start(process: .app)
        let settings = Settings.shared()
        let keychain = settings.keychain
        let factory: @MainActor (Settings) -> any CobaltClient = { settings in
            let server = settings.serverURL
            return HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        }
        let store = OfflineStore.shared()
        Telemetry.log(.info, .store, "store opened", data: [
            "media": .int(store.media.count), "videos": .int(store.videos.count), "root": .string(AppGroup.location.kind.rawValue),
        ])
        let ctx = PipelineContext(
            client: factory(settings), capabilities: .unknown, settings: settings, store: store,
            jobs: .shared(), tools: SystemMediaTools(), clock: SystemClock(), photos: SystemPhotosSaver(),
            clipboard: SystemClipboard(), intake: SystemFileIntake(), isPreview: false)
        ctx.recordsJobs = true
        ctx.notifier = SystemNotifier()          // asked on the first run, not here (HIG: ask in context)
        ctx.background.activity = SystemAppActivity()
        ctx.background.grace = SystemBackgroundGrace()
        Task { await store.enforceLimit() }      // the owner may have lowered the limit while the app was closed
        // The photos album and the background download of originals (CONTRACT-SYNC.md): the app only.
        let ledger = PhotosLedger.shared()
        ctx.photosLedger = ledger
        let sync = PhotosSync(
            settings: settings, store: store, ledger: ledger, library: SystemPhotoLibrary(),
            isForeground: { [unowned ctx] in ctx.background.activity.isActive })
        let fetcher = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: URLSessionBackgroundTransport(), pending: .shared(),
            store: store, clock: ctx.clock)
        ctx.originals = fetcher
        // The Mac's folder: created after the photos sync so it chains onto the store's `onAdd` (macOS only;
        // on iOS it is unavailable and never runs).
        let folder = FolderSync(settings: settings, store: store, ledger: FolderLedger.shared())
        #if os(macOS)
        folder.observeActivation()
        #endif
        let offline = OfflineDownloads(
            store: store, queue: OfflineQueue(directory: AppGroup.directory("Sync")), transport: URLSessionOfflineTransport(),
            clock: ctx.clock, client: { [unowned ctx] in ctx.client })
        let model = AppModel(
            context: ctx, library: LibraryModel(context: ctx), photosSync: sync, folderSync: folder,
            offlineDownloads: offline, ledger: JobLedger.shared(), makeClient: factory)
        model.telemetry = TelemetryService.live(settings: settings, capabilities: { [unowned model] in model.capabilities })
        fetcher.isActive = { [unowned ctx] in ctx.background.activity.isActive }
        fetcher.serverHoldsRequests = { [unowned model] in model.capabilities.sourceWait }
        // a gallery found by the foreground (a build with no app group) is followed as a job, not downloaded as one file
        fetcher.adoptGallery = { [unowned model] id, link in model.queue.adoptSharedGallery(session: id, link: link) }
        #if os(iOS) && canImport(ActivityKit)
        // First thing at launch, before any run: the push-to-start token observer (CONTRACT-LIVE.md 2.5).
        let manager = LiveActivityManager(context: ctx, adapter: ActivityKitAdapter(), environment: LiveEnvironment.current)
        ctx.live = manager
        model.liveManager = manager
        manager.start()
        #endif
        #if os(iOS)
        // The owner leaves mid-run: the system keeps the app working on it (`BGContinuedProcessingTask`),
        // and the server speaks for it through the notify bridge if that task is refused or expires.
        let continued = ContinuedProcessing(context: ctx, scheduler: SystemContinuedScheduler(), home: { [unowned model] in model.pipeline })
        continued.register()
        ctx.continued = continued
        model.continuedProcessing = continued
        model.lifecycleObservers = continued.observeLifecycle()
        #endif
        return model
    }

    /// Every screen previews against this: the boards' data and timings, nothing on the network.
    public static func preview(_ scenario: PreviewScenario = .happy) -> AppModel {
        makePreview(scenario, timeScale: 1, clock: SystemClock())
    }

    static func makePreview(_ scenario: PreviewScenario, timeScale: Double, clock: any PipelineClock) -> AppModel {
        let ctx = PipelineContext.preview(scenario, timeScale: timeScale, clock: clock)
        let client = ctx.client
        let model = AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)),
            folderSync: FolderSync.preview(.init(available: FolderSync.platformHasFolder, enabled: true, saved: 12, waiting: 0, existing: 0)),
            makeClient: { _ in client })
        if scenario == .offline { model.seedOfflinePreviewStates() }
        return model
    }

    public var serverSummary: ServerSummary {
        var features: [String] = []
        if capabilities.studio { features.append("studio") }
        if capabilities.library { features.append("library") }
        return ServerSummary(
            host: settings.serverURL.host(percentEncoded: false) ?? settings.serverURL.absoluteString,
            kind: capabilities.kind, version: capabilities.cobaltVersion, features: features,
            key: capabilities.key, keyName: capabilities.keyName)
    }

    // MARK: - Server

    /// Launch, foreground, server or key change.
    public func refreshServer() async {
        isCheckingServer = true
        defer { isCheckingServer = false }
        let previous = capabilities
        var fresh = await ctx.client.capabilities()
        // Offline: keep what we knew about this server (the circles must not vanish on a bad train).
        if fresh.kind == .unreachable, [.fork, .legacyFork, .plainCobalt].contains(previous.kind) { fresh = previous }
        apply(fresh)
        Telemetry.log(.info, .net, "server checked", data: ["kind": .string(fresh.kind.rawValue), "telemetry": .bool(fresh.telemetry), "key": .string(fresh.key.rawValue)])
        telemetry?.uploadSoon()
    }

    func apply(_ caps: Capabilities) {
        capabilities = caps
        ctx.capabilities = caps
        if selectedTab == .library, !caps.library, caps.kind != .unreachable { selectedTab = .save }
        liveManager?.capabilitiesChanged()
    }

    func markKeyInvalid() {
        var caps = capabilities
        caps.key = .invalid
        caps.keyName = nil
        apply(caps)
    }

    public func setServer(pasted text: String) async throws(ServerInputError) {
        try settings.setServer(pasted: text)
        serverChanged()
        await refreshServer()
    }

    public func setAPIKey(pasted text: String) async throws(KeyInputError) {
        try settings.setAPIKey(pasted: text)
        await refreshServer()
    }

    /// New server: a new client, nothing known, nothing cached.
    func serverChanged() {
        queue.serverChanged()                    // first: every job's Live Activity ends against the server it belonged to
        ctx.background.cancelAll()               // detached runs belonged to the old server too
        ctx.client = makeClient(settings)
        apply(.unknown)
        library.reset()
    }

    // MARK: - Links, handoffs

    /// `cobalt-apple://job/<uuid>`, `cobalt-apple://library` ("your webp is ready") and
    /// `cobalt-apple://open`.
    public func open(_ url: URL) {
        guard url.scheme?.lowercased() == "cobalt-apple" else { return }
        selectedTab = .save
        if url.host(percentEncoded: false)?.lowercased() == "library" {
            if capabilities.library || capabilities.kind == .unreachable { selectedTab = .library }
            return
        }
        if url.host(percentEncoded: false)?.lowercased() == "jobs" {
            requestedJobs = true                        // the Hark summary (APP-API-CONTRACT 17.8): show the tray
            return
        }
        guard url.host(percentEncoded: false)?.lowercased() == "job",
              let id = UUID(uuidString: url.lastPathComponent),
              !ctx.background.owns(job: id),            // a detached or queued run of this process is still carrying it
              let job = jobs.all().first(where: { $0.id == id })
        else { return }
        // Mid-run (saving, reading, rendering, a picker, a trim in progress) the home pipeline is
        // busy: taking the job would cancel what the owner is waiting on. It stays in the store
        // (and a stale notification for a job this run already follows has nothing to add);
        // `pickUpSharedJobs` takes it once the pipeline is quiet. A result on screen is replaced
        // here, because opening the job link is the owner asking for exactly that; so is a clip
        // sitting at the ready card when the job is a "trim in cobalt" one (that clip stays in the
        // library and the orbit).
        guard isPipelineFree || (job.wantsTrim && pipelineIsReady) else {
            // busy home: with a tray on screen the run joins it instead of being ignored (CONTRACT-PARALLEL.md 3.3);
            // without one it stays in the store until the home screen is quiet
            if queue.trayIsShown { queue.add([.shared(job)], via: .share) }
            return
        }
        take(job)
    }

    /// The home pipeline follows `job`; its notifications have nothing left to say.
    private func take(_ job: SharedJob) {
        pipeline.resume(job)
        if !ctx.isPreview { Notifications.clear(jobID: job.id) }
    }

    /// On scenePhase `.active`: take over whatever the share extension left.
    public func pickUpSharedJobs() async {
        defer { liveManager?.foreground() }       // start token, push-started activities, orphans (after a handoff took its run)
        await store.reload()
        store.startWatching()                      // the visible folder, while cobalt is in front (no-op without one)
        Telemetry.log(.info, .store, "store reloaded", data: ["media": .int(store.media.count), "videos": .int(store.videos.count)])
        queue.appForegrounded()                    // the line's one summary opt-in is taken back: the owner is looking
        takePendingJobs()
        await queue.restoreLedger()                // links the server never answered for, from last time (once per launch)
        await queue.adoptRecentShares()            // share-sheet saves still running or queued on the server
        if capabilities.titles { await ctx.titles.flush(client: ctx.client) }      // titles that failed to send (decision 4)
        // Then what the share sheet handed to the background download, then the photos album
        // (CONTRACT-SYNC.md): in this order, so a clip that just landed goes into Photos at once.
        await ctx.originals?.reconcile()
        // "keep offline" downloads: what arrived is landed, what waits is restarted, what the system lost is started
        // again (after the store's reload, which just re-read the visible folder).
        await offlineDownloads.reconcile()
        await photosSync.refresh()
        await photosSync.reconcile()
    }

    private func takePendingJobs() {
        // A handoff found on foregrounding never pushes aside a finished result or an image the
        // owner is looking at, nor a run in flight: only an idle or failed home screen takes it
        // (opening its notification, `open(_:)`, is the explicit way to replace a result).
        // The one exception is an explicit "trim in cobalt" handoff, which may replace a clip that is
        // only sitting at the ready card (never a busy state).
        if let job = jobs.nextHandoff(now: ctx.clock.now()), canTakeHandoff(job) {
            selectedTab = .save
            take(job)
            return
        }
        // The app itself was closed (or killed) mid-save or mid-render: the server carried on, so follow every one of
        // them again, newest first. The newest takes the focus when the screen is quiet (today's pickup); the rest go
        // alongside. Jobs this process already runs are left alone.
        let window = SharedJobStore.inFlightWindow + (capabilities.line ? capabilities.limits.lineWait : 0)
        let owned = ctx.background.jobIDs
        let now = ctx.clock.now()
        let inFlight = jobs.all()
            .filter { job in
                guard job.origin == .app, !job.pickedUp, !owned.contains(job.id), now.timeIntervalSince(job.updatedAt) < window
                else { return false }
                switch job.stage {
                case .saving, .rendering: return true
                default: return false
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !inFlight.isEmpty else { return }
        let before = queue.focusedID
        if queue.trayIsShown {
            for job in inFlight { queue.add([.shared(job)], via: .relaunch) }
        } else if isPipelineFree, case .idle = pipeline.state, let newest = inFlight.first {
            queue.add([.shared(newest)], via: .relaunch)       // no tray yet: today's pickup, one run into the focus
        }
        if queue.focusedID != before { selectedTab = .save }
    }

    /// Nothing on the home screen worth keeping: idle, or a failure (which says nothing the new job
    /// would not).
    private func canTakeHandoff(_ job: SharedJob) -> Bool {
        switch pipeline.state {
        case .idle, .failed: return true
        case .ready: return job.wantsTrim
        default: return false
        }
    }

    private var pipelineIsReady: Bool {
        if case .ready = pipeline.state { return true } else { return false }
    }

    private var isPipelineFree: Bool {
        switch pipeline.state {
        case .idle, .done, .failed, .savedLocally, .image: return true
        default: return false
        }
    }

    // MARK: - Background downloads (CONTRACT-SYNC.md decision 6)

    /// The background URLSessions this app and its share extension use: `com.capybaraharmony.cobalt.bg.app`
    /// and `com.capybaraharmony.cobalt.bg.share.<job uuid>`.
    nonisolated public static func ownsBackgroundSession(_ identifier: String) -> Bool {
        identifier.hasPrefix(BackgroundSessionID.prefix)
    }

    /// The system woke the app for a finished download of one of those sessions
    /// (`.backgroundTask(.urlSession(matching:))`): the files move into the store, then the photos sync runs.
    public func handleBackgroundDownloads(identifier: String) async {
        if identifier == OfflineDownloads.sessionIdentifier {
            await offlineDownloads.handleWake(identifier: identifier)          // "keep offline" (`…bg.offline`)
        } else {
            await ctx.originals?.handleWake(identifier: identifier)            // share-sheet originals (`…bg.app`, `…bg.share.*`)
        }
        await photosSync.refresh()
        await photosSync.reconcile()
    }

    public func trimNewWebp(from post: LibraryPost) async {
        selectedTab = .save
        pipeline.resumeFromLibrary(post)
    }
}
