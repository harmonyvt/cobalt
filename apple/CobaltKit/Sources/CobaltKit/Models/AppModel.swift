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
    public internal(set) var capabilities: Capabilities
    public internal(set) var isCheckingServer: Bool = false
    public internal(set) var pipeline: Pipeline           // the home pipeline
    public var selectedTab: AppTab = .save

    /// Live Activities (iOS only; nil on the Mac, in previews and in tests unless one is injected).
    @ObservationIgnored var liveManager: LiveActivityManager?

    /// Keeps a run going after the app leaves the screen (iOS 26 continued processing); nil on the
    /// Mac, in previews and in tests unless one is injected.
    @ObservationIgnored var continuedProcessing: ContinuedProcessing?
    @ObservationIgnored var lifecycleObservers: [any NSObjectProtocol] = []

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let makeClient: @MainActor (Settings) -> any CobaltClient

    init(
        context: PipelineContext, library: LibraryModel, photosSync: PhotosSync? = nil,
        makeClient: @escaping @MainActor (Settings) -> any CobaltClient
    ) {
        let sync = photosSync ?? PhotosSync.preview(.init(access: .notAsked, enabled: false))
        self.photosSync = sync
        context.photosSync = sync
        self.ctx = context
        self.settings = context.settings
        self.store = context.store
        self.jobs = context.jobs
        self.library = library
        self.capabilities = context.capabilities
        self.pipeline = Pipeline(context: context)
        self.makeClient = makeClient
        context.keyRejected = { [weak self] in self?.markKeyInvalid() }
        context.capabilitiesChanged = { [weak self] caps in self?.apply(caps) }
    }

    /// The real app: app-group stores, the keychain, the configured server.
    public static func live() -> AppModel {
        let settings = Settings.shared()
        let keychain = settings.keychain
        let factory: @MainActor (Settings) -> any CobaltClient = { settings in
            let server = settings.serverURL
            return HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        }
        let store = OfflineStore.shared()
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
        let sync = PhotosSync(settings: settings, store: store, ledger: ledger, library: SystemPhotoLibrary())
        let fetcher = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: URLSessionBackgroundTransport(), pending: .shared(),
            store: store, clock: ctx.clock)
        ctx.originals = fetcher
        let model = AppModel(context: ctx, library: LibraryModel(context: ctx), photosSync: sync, makeClient: factory)
        fetcher.isActive = { [unowned ctx] in ctx.background.activity.isActive }
        fetcher.serverHoldsRequests = { [unowned model] in model.capabilities.sourceWait }
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
        return AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)),
            makeClient: { _ in client })
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
        pipeline.reset()                         // first: its Live Activity ends against the server it belonged to
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
        guard url.host(percentEncoded: false)?.lowercased() == "job",
              let id = UUID(uuidString: url.lastPathComponent),
              !ctx.background.owns(job: id),            // a detached run of this process is still carrying it
              let job = jobs.all().first(where: { $0.id == id })
        else { return }
        // Mid-run (saving, reading, rendering, a picker, a trim in progress) the home pipeline is
        // busy: taking the job would cancel what the owner is waiting on. It stays in the store
        // (and a stale notification for a job this run already follows has nothing to add);
        // `pickUpSharedJobs` takes it once the pipeline is quiet. A result on screen is replaced
        // here, because opening the job link is the owner asking for exactly that; so is a clip
        // sitting at the ready card when the job is a "trim in cobalt" one (that clip stays in the
        // library and the orbit).
        guard isPipelineFree || (job.wantsTrim && pipelineIsReady) else { return }
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
        takePendingJobs()
        // Then what the share sheet handed to the background download, then the photos album
        // (CONTRACT-SYNC.md): in this order, so a clip that just landed goes into Photos at once.
        await ctx.originals?.reconcile()
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
        guard isPipelineFree else { return }
        // The app itself was closed (or killed) mid-save or mid-render: the server carried on, so
        // follow it again. Only from a quiet home screen, never over something the owner is doing.
        if case .idle = pipeline.state,
           let job = jobs.nextInFlightAppJob(now: ctx.clock.now(), excluding: ctx.background.jobIDs) {
            selectedTab = .save
            take(job)
        }
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
        await ctx.originals?.handleWake(identifier: identifier)
        await photosSync.refresh()
        await photosSync.reconcile()
    }

    public func trimNewWebp(from post: LibraryPost) async {
        selectedTab = .save
        pipeline.resumeFromLibrary(post)
    }
}
