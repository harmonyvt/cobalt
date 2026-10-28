import Foundation
import Observation
import UserNotifications

/// The tabs, in the order they show. `queue` is everything cobalt is doing (apple/CONTRACT.md section 12).
/// `links` lists the gallery share links (APP-API-CONTRACT 24) and shows only with `features.share_sets`; `chat` holds the
/// threads with Claude about the library (APP-API-CONTRACT 27) and shows only with `features.chat`; `stage` is the "studio"
/// tab, the stream canvas and the viewer store (APP-API-CONTRACT 30), after chat, and shows only with `features.stage`.
public enum AppTab: String, Sendable, CaseIterable {
    case save, library, links, chat, stage, queue, settings

    /// Whether this server lets the tab show: the library needs `features.library`, links need `features.share_sets`,
    /// chat needs `features.chat`, the studio needs `features.stage`.
    public func isAvailable(with caps: Capabilities) -> Bool {
        switch self {
        case .library: return caps.library
        case .links: return caps.shareSets
        case .chat: return caps.chat
        case .stage: return caps.stage
        case .save, .queue, .settings: return true
        }
    }
}

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
    /// Gallery share links (APP-API-CONTRACT 24; `PreviewShare.swift`): `.renditions` data on a server with
    /// `features.share_sets` and no links yet. `.happy` and `.renditions` have the same server with three sample links.
    case shareLinksEmpty
    /// Like `.shareLinksEmpty`, but `GET /share/sets` always fails (`503`), so the links tab shows its failed state.
    /// Making a link works.
    case shareLinksFail
    /// Chat (APP-API-CONTRACT 27; `PreviewChat.swift`): `.happy` and `.renditions` have `features.chat` with three sample
    /// threads. `.chatEmpty`: no threads yet. `.chatFail`: `GET /chat/threads` always fails (`503`), so the tab shows its
    /// failed state. `.chatReplyFails`: the sample threads, but every reply ends in `error.chat.model` after a few words.
    case chatEmpty, chatFail, chatReplyFails
    /// The sample threads plus a fifth, "tidy up the timer clips", whose last reply waits on a confirm card (33.5): "delete 3"
    /// deletes and the reply goes on, "cancel" keeps them.
    case chatConfirm
    /// The library's sky map (APP-API-CONTRACT 21, `PreviewSkyMap.swift`): a server with `features.search` whose
    /// `GET /library/map` hands over about 150 mock posts in eight clusters (cats, minecraft, anime, cooking, coffee, the
    /// harbour, guitar, skate). `.happy` and `.renditions` serve the same map but do not advertise `features.search`.
    case skyMap
    /// Stage, the studio tab (APP-API-CONTRACT 30; `PreviewStage.swift`): `.happy` and `.renditions` have `features.stage`
    /// and `stage_twitch` with a connected, on-air stage (a spotlight, four rewards, a few redemptions). `.stageNotConnected`:
    /// off air, Twitch not connected yet (connecting works). `.stageFail`: `GET /stage` always fails (`503`), so the tab shows
    /// its failed state.
    case stageNotConnected, stageFail
    /// The video editor (APP-API-CONTRACT 31; `Editor/PreviewEditor.swift`): `.happy` and `.renditions` have `features.editor` with
    /// two projects ("beach day edit", "cat compilation"). `.editorEmpty`: no projects. `.editorRendering`: "beach day edit" is
    /// rendering, queued to done in about 20 s. `.editorRenderFails`: a render ends `error.edit.render_failed` at 60 %.
    /// `.editorConflict`: the first save answers `409`. `.editorFail`: `GET /edits` always fails (`503`).
    case editorEmpty, editorRendering, editorRenderFails, editorConflict, editorFail
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
    /// The gallery share links (the links tab; the library's select bar makes them). Idle until `refresh()`.
    public let shareSets: ShareSetStore
    /// The chat threads (the chat tab; APP-API-CONTRACT 27). Idle until `refresh()`.
    public let chat: ChatStore
    /// Stage, the studio tab (APP-API-CONTRACT 30). Idle until `load()`.
    public let stage: StageStore
    /// The video editor (APP-API-CONTRACT 31): the projects, this key's renders and the open project. Idle until `refresh()`.
    public let editor: EditorStore
    /// The library as a sky map (APP-API-CONTRACT 21, `GET /library/map`). Idle until `load()`.
    public let skyMap: SkyMapModel
    /// The photos album (CONTRACT-SYNC.md): `PhotosSync.preview(_:)` in previews.
    public let photosSync: PhotosSync
    /// The Mac's Finder folder, the store's visible root (CONTRACT-OFFLINE.md section 13, Folder/MacFolder.swift):
    /// unavailable on iOS and in previews, which get `MacFolder.preview(_:)`.
    public let macFolder: MacFolder
    /// The Mac's pull of saves made anywhere (13.8): unavailable on iOS and in previews.
    public let savePull: SavePull
    /// "keep offline" (CONTRACT-OFFLINE.md decision 9): the background downloads and their states.
    public let offlineDownloads: OfflineDownloads
    public internal(set) var capabilities: Capabilities
    public internal(set) var isCheckingServer: Bool = false
    /// Every run of the app (CONTRACT-PARALLEL.md): the jobs, which one is focused, the tray's order, the lines.
    public let queue: JobQueue
    /// The queue tab (apple/CONTRACT.md section 12): the jobs, the server's line, downloads, the photos album and the
    /// search index in one list. Polls `GET /queue` only while the tab is on screen.
    public let unifiedQueue: UnifiedQueue
    /// What the focus screens read: the focused job's pipeline, or an idle one when nothing is focused. A run started
    /// on it by hand becomes the focused job at once.
    public var pipeline: Pipeline { queue.focused?.pipeline ?? queue.idlePipeline }
    public var selectedTab: AppTab = .save
    /// iPhone and iPad: the queue is a sheet over the shell (opened from a toolbar button), not a tab. Use `showQueue()`
    /// to open it from anywhere; the shell presents the sheet while this is true. The Mac keeps the queue as a tab and
    /// never sets this.
    public var queueShown = false

    /// A stored media a run link asks the home screen to open (CONTRACT-SHARE-QUICK.md R3): set by
    /// `openRunLink` when the run it names has settled and its original is in the store; the home screen
    /// opens that media's detail and sets this back to nil.
    public var requestedMediaID: String?

    /// Asks the save tab to open the tray fully; the view that shows it sets this back to false. `cobalt-apple://jobs`
    /// (the Hark summary, APP-API-CONTRACT 17.8) used to set it; it now opens the queue tab (apple/CONTRACT.md 12).
    public var requestedJobs = false

    /// Live Activities (iOS only; nil on the Mac, in previews and in tests unless one is injected).
    @ObservationIgnored var liveManager: LiveActivityManager?
    /// The editor's render activities (iOS only; nil on the Mac, in previews and in tests unless one is injected).
    @ObservationIgnored var editLive: EditLiveManager? {
        didSet {
            let feed: @MainActor ([EditRender]) -> Void = { [weak self] renders in
                guard let live = self?.editLive else { return }
                Task { @MainActor in await live.observe(renders) }
            }
            editor.onRenders = editLive == nil ? nil : feed
            unifiedQueue.onEdits = editLive == nil ? nil : feed
        }
    }

    /// Crash reports and logs to the owner's server; nil in previews and tests.
    @ObservationIgnored public internal(set) var telemetry: TelemetryService?

    /// Keeps a run going after the app leaves the screen (iOS 26 continued processing); nil on the
    /// Mac, in previews and in tests unless one is injected.
    @ObservationIgnored var continuedProcessing: ContinuedProcessing?
    @ObservationIgnored var lifecycleObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var foregrounding: Task<Void, Never>?

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let makeClient: @MainActor (Settings) -> any CobaltClient

    init(
        context: PipelineContext, library: LibraryModel, photosSync: PhotosSync? = nil, macFolder: MacFolder? = nil,
        savePull: SavePull? = nil, offlineDownloads: OfflineDownloads? = nil, ledger: JobLedger? = nil,
        makeClient: @escaping @MainActor (Settings) -> any CobaltClient
    ) {
        let sync = photosSync ?? PhotosSync.preview(.init(access: .notAsked, enabled: false))
        self.photosSync = sync
        self.macFolder = macFolder ?? MacFolder.preview(.init(available: false))
        self.savePull = savePull ?? SavePull.preview(.init(available: false))
        // Previews and tests fetch in the foreground (no background session); the app passes its own engine.
        let offline = offlineDownloads ?? OfflineDownloads(
            store: context.store,
            queue: OfflineQueue(directory: context.store.root.deletingLastPathComponent().appendingPathComponent("Sync", isDirectory: true)),
            transport: nil, clock: context.clock, client: { context.client }, isPreview: context.isPreview)
        offline.markNotNew = { [sync] keys in
            sync.markNotNew(keys)
        }
        offline.landed = { [sync] in await sync.refresh() }
        self.offlineDownloads = offline
        context.photosSync = sync
        self.ctx = context
        self.settings = context.settings
        self.store = context.store
        self.jobs = context.jobs
        self.library = library
        self.shareSets = ShareSetStore(context: context)
        self.chat = ChatStore(context: context)
        self.stage = StageStore(context: context)
        self.editor = EditorStore(context: context)
        self.skyMap = SkyMapModel(context: context)
        self.capabilities = context.capabilities
        // Jobs that have no server session yet (CONTRACT-PARALLEL.md 3.5); previews and tests keep theirs beside the store.
        let jobQueue = JobQueue(
            context: context,
            ledger: ledger ?? JobLedger(
                fileURL: context.store.root.deletingLastPathComponent().appendingPathComponent("job-ledger.json"),
                now: { [clock = context.clock] in clock.now() }))
        self.queue = jobQueue
        self.unifiedQueue = UnifiedQueue(context: context, jobs: jobQueue, offline: offline, photos: sync)
        self.makeClient = makeClient
        unifiedQueue.editRenders = { [weak self] in self?.editor.renders ?? [] }
        context.keyRejected = { [weak self] in self?.markKeyInvalid() }
        context.capabilitiesChanged = { [weak self] caps in self?.apply(caps) }
        // a gallery saved, or something made from one: the library re-reads the post (its items, its tabs)
        context.galleryChanged = { [weak self] in
            guard let self, self.capabilities.library, self.capabilities.gallery else { return }
            Task { await self.library.refresh() }
        }
        context.libraryDropped = { [weak self] ids in self?.library.drop(files: Set(ids)) }
        // The Mac's pull reads this model (settings, capabilities, the library, the runs); previews have none to wire.
        self.savePull.wire(pullEnvironment())
    }

    /// The real app: app-group stores, the keychain, the configured server.
    public static func live() -> AppModel {
        Telemetry.start(process: .app)
        let settings = Settings.shared()
        let keychain = settings.keychain
        let factory: @MainActor (Settings) -> any CobaltClient = { settings in
            let server = settings.serverURL
            #if os(iOS)
            // studio uploads keep going with the app suspended or ended (BackgroundUploads)
            return HTTPCobaltClient(
                baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) }, backgroundUploads: .shared)
            #else
            return HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) })
            #endif
        }
        let store = OfflineStore.shared()
        Telemetry.log(.info, .store, "store opened", data: [
            "media": .int(store.media.count), "videos": .int(store.videos.count), "root": .string(AppGroup.location.kind.rawValue),
        ])
        let ctx = PipelineContext(
            client: factory(settings), capabilities: settings.knownCapabilities ?? .unknown, settings: settings, store: store,
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
        // The Mac's folder is the store's visible root; this object reports it and chooses another (unavailable on iOS).
        let folder = MacFolder(store: store, ledger: FolderLedger.shared())
        #if os(macOS)
        folder.observeActivation()
        #endif
        let offline = OfflineDownloads(
            store: store, queue: OfflineQueue(directory: AppGroup.directory("Sync")), transport: URLSessionOfflineTransport(),
            clock: ctx.clock, client: { [unowned ctx] in ctx.client })
        // The pull of saves made anywhere (13.8): the Mac only (`isAvailable`); its baseline lives in `Sync/pull.json`.
        let pull = SavePull(
            store: store, ledger: PullLedger(directory: AppGroup.directory("Sync")), downloads: offline, clock: ctx.clock,
            scheduler: TimerScheduler())
        let model = AppModel(
            context: ctx, library: LibraryModel(context: ctx), photosSync: sync, macFolder: folder,
            savePull: pull, offlineDownloads: offline, ledger: JobLedger.shared(), makeClient: factory)
        model.telemetry = TelemetryService.live(settings: settings, capabilities: { [unowned model] in model.capabilities })
        pull.start()                             // the 5 minute tick (a no-op without the Mac folder)
        model.watchOwnUploads()
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
        model.editLive = EditLiveManager(
            adapter: ActivityKitEditAdapter(), environment: LiveEnvironment.current,
            capabilities: { [unowned model] in model.capabilities },
            client: { [unowned ctx] in ctx.client as? any EditorClient },
            now: { [unowned ctx] in ctx.clock.now() })
        let chatLive = ChatLiveManager(
            adapter: ActivityKitChatAdapter(), now: { [unowned ctx] in ctx.clock.now() },
            isAppActive: { [unowned ctx] in ctx.background.activity.isActive },
            environment: LiveEnvironment.current,
            capabilities: { [unowned model] in model.capabilities },
            client: { [unowned ctx] in ctx.client as? any ChatLiveClient })
        model.chat.live = chatLive
        chatLive.start()             // a chat sent from the Mac push-starts its activity here (APP-API-CONTRACT 27.9)
        #endif
        #if os(iOS)
        // The owner leaves mid-run: the system keeps the app working on it (`BGContinuedProcessingTask`),
        // and the server speaks for it through the notify bridge if that task is refused or expires.
        let continued = ContinuedProcessing(context: ctx, scheduler: SystemContinuedScheduler(), home: { [unowned model] in model.pipeline })
        continued.liveActivityCovers = { ActivityKitAdapter.activitiesAllowed }
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
            macFolder: MacFolder.preview(.init(available: MacFolder.platformHasFolder)),
            savePull: SavePull.preview(.init(available: MacFolder.platformHasFolder)),
            makeClient: { _ in client })
        if scenario == .offline { model.seedOfflinePreviewStates() }
        return model
    }

    /// True for `AppModel.preview(...)`: system prompts and sheets that ask for permissions stay away.
    public var isPreview: Bool { ctx.isPreview }

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
        if !ctx.isPreview { settings.remember(caps) }
        if selectedTab == .library, !caps.library, caps.kind != .unreachable { selectedTab = .save }
        if selectedTab == .links, !caps.shareSets, caps.kind != .unreachable { selectedTab = .save }
        if selectedTab == .chat, !caps.chat, caps.kind != .unreachable { selectedTab = .save }
        if selectedTab == .stage, !caps.stage, caps.kind != .unreachable { selectedTab = .save }
        liveManager?.capabilitiesChanged()
        unifiedQueue.capabilitiesChanged()            // `features.queue` came or went: poll, or stop
        savePull.capabilitiesChanged()                // a check that waited for the server runs now
        editor.capabilitiesChanged()                  // `features.editor` went: close the editor
        if let editLive { Task { await editLive.capabilitiesChanged() } }
        if let chatLive = chat.live { Task { await chatLive.capabilitiesChanged() } }
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
        savePull.serverChanged()                 // another library: a new baseline for the pull
        unifiedQueue.serverChanged()             // nothing from the old server's queue is kept
        ctx.background.cancelAll()               // detached runs belonged to the old server too
        ctx.client = makeClient(settings)
        apply(.unknown)
        library.reset()
        shareSets.reset()
        chat.reset()
        stage.reset()
        editor.reset()
        skyMap.reset()
    }

    // MARK: - Links, handoffs

    /// Shows the queue: the Mac selects its tab, iPhone and iPad present the queue sheet (apple/CONTRACT.md section 12).
    public func showQueue() {
        #if os(macOS)
        selectedTab = .queue
        #else
        queueShown = true
        #endif
    }

    /// `cobalt-apple://job/<uuid>`, `cobalt-apple://library` ("your webp is ready"), `cobalt-apple://stage` (the Twitch
    /// sign-in's return), `cobalt-apple://chat/<thread>` (a chat reply's Live Activity) and `cobalt-apple://open`.
    public func open(_ url: URL) {
        guard url.scheme?.lowercased() == "cobalt-apple" else { return }
        queueShown = false                              // a link to somewhere else leaves the queue sheet behind
        selectedTab = .save
        if url.host(percentEncoded: false)?.lowercased() == "library" {
            if capabilities.library || capabilities.kind == .unreachable { selectedTab = .library }
            return
        }
        if url.host(percentEncoded: false)?.lowercased() == "stage" {
            // the Twitch sign-in's return (APP-API-CONTRACT 30.4): `cobalt-apple://stage?twitch=connected|failed`. The studio tab
            // reads the stage again either way, so the card shows what Twitch did.
            if capabilities.stage || capabilities.kind == .unreachable { selectedTab = .stage }
            if capabilities.stage { Task { await self.stage.load() } }
            return
        }
        if url.host(percentEncoded: false)?.lowercased() == "chat" {
            // a chat reply's Live Activity: `cobalt-apple://chat/<thread>` opens that thread in the chat tab
            if capabilities.chat || capabilities.kind == .unreachable { selectedTab = .chat }
            let thread = url.lastPathComponent
            if !thread.isEmpty, thread != "/" {
                chat.openThreadID = thread
                Task { await self.chat.load(thread) }
            }
            return
        }
        if url.host(percentEncoded: false)?.lowercased() == "jobs" {
            showQueue()                                 // the Hark summary (APP-API-CONTRACT 17.8): the queue (a tab on the Mac, a sheet elsewhere)
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

    /// Launch and every activation: the server check, then whatever the share extension left. Calls that overlap
    /// (the launch task and the first `.active`) share one run instead of checking and reloading twice at once.
    public func foreground() async {
        if let running = foregrounding { return await running.value }
        let run = Task { @MainActor in
            await refreshServer()
            await pickUpSharedJobs()
        }
        foregrounding = run
        await run.value
        foregrounding = nil
    }

    /// On scenePhase `.active`: take over whatever the share extension left.
    public func pickUpSharedJobs() async {
        defer { liveManager?.foreground() }       // start token, push-started activities, orphans (after a handoff took its run)
        if let editLive { Task { await editLive.foreground() } }   // render activities whose end no push brought
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
        // The Mac's pull of saves made anywhere (13.8): at launch and on every activation, once the engine has landed what
        // arrived. Not awaited: a slow library never holds the foregrounding.
        Task { @MainActor [savePull] in await savePull.check() }
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
        if identifier == BackgroundUploads.identifier {
            await BackgroundUploads.shared.handleWake()                       // a studio upload ended (`…bg.upload`)
            return
        }
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
