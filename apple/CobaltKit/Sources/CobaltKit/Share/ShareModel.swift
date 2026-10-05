import Foundation
import Observation
import UniformTypeIdentifiers

#if os(iOS)
/// The share sheet's model: one pipeline plus what closing the sheet means. The whole declaration
/// is iOS only (the extension has no macOS twin); the logic lives in `ShareCore`, which compiles
/// everywhere so it can be tested on the Mac.
@MainActor @Observable
public final class ShareModel {
    public enum CloseResult: Sendable { case dismissed, continuesInBackground }

    public let pipeline: Pipeline
    /// Duration > `maxClipSeconds` once known.
    public var isLong: Bool { core.isLong }
    /// What the server can do, as last read (updates once the pipeline has asked the server).
    public var capabilities: Capabilities { core.capabilities }
    /// "make webp" belongs on the sheet only when the server has a studio (not plain cobalt).
    public var webpAvailable: Bool { core.webpAvailable }
    /// A webp is being made: swiping the sheet away would lose track of it, so the controller makes
    /// the sheet modal while this is true and routes an attempt to dismiss it to `close()`.
    public var isRendering: Bool { core.isRendering }
    /// A save or a render is on the server for this sheet and can finish without it: closing now
    /// (or `continueInBackground()`) lets it. The controller makes the sheet modal while this is
    /// true so the attempt to swipe it away goes through `close()`.
    public var canContinueInBackground: Bool { core.canContinueInBackground }

    /// Where the automatic "continue in background" is (CONTRACT-SYNC.md decisions 1 to 5).
    public var autoContinue: AutoContinue { core.autoContinue }

    @ObservationIgnored let core: ShareCore

    init(context: PipelineContext, pipeline: Pipeline, notifier: any NotificationPosting = SystemNotifier()) {
        self.pipeline = pipeline
        self.core = ShareCore(context: context, pipeline: pipeline, notifier: notifier)
    }

    /// The stay button: stops the countdown for good (the sheet stays open).
    public func stay() { core.stay() }

    /// Every other control on the sheet calls this first: touching the sheet stops the countdown.
    public func noteInteraction() { core.noteInteraction() }

    /// For `#Preview`s: shows `state` and stops the real countdown (nothing will fire).
    public func previewAutoContinue(_ state: AutoContinue) { core.previewAutoContinue(state) }

    /// Mid-render: leaves a `SharedJob(.rendering)` for the app and a notification, then lets the
    /// sheet go. Anything else just stops.
    public func close() async -> CloseResult {
        switch await core.close() {
        case .dismissed: return .dismissed
        case .continuesInBackground: return .continuesInBackground
        }
    }

    /// "continue in background": a save or render in flight is left to the server, which tells the
    /// owner when it is done (the notify bridge; a local "still making it" notification when the
    /// server has none), and the sheet goes. A sheet with nothing to continue just stops.
    public func continueInBackground() async -> CloseResult {
        switch await core.continueInBackground() {
        case .dismissed: return .dismissed
        case .continuesInBackground: return .continuesInBackground
        }
    }

    /// "trim in cobalt": a `wantsTrim` job, then open the app (or ask with a notification).
    public func handOffToApp() async {
        await core.handOffToApp()
    }

    // MARK: - Wiring (additive to the pinned API; approved after wave 0, CONTRACT 4.7)

    /// Called by `ShareViewController`: reads what the host app shared, builds the pipeline on the
    /// real stores and starts it. `openApp` tries to open `cobalt-apple://job/<uuid>` and says whether
    /// it worked; `complete` finishes the extension request (called when `close()` /
    /// `handOffToApp()` return).
    public static func live(
        inputItems: [NSExtensionItem],
        openApp: @escaping @MainActor (URL) async -> Bool,
        complete: @escaping @MainActor () -> Void
    ) async -> ShareModel {
        let settings = Settings.shared()
        let keychain = settings.keychain
        let store = OfflineStore.shared()
        let server = settings.serverURL
        let ctx = PipelineContext(
            client: HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) }),
            capabilities: .unknown, settings: settings, store: store, jobs: .shared(), tools: SystemMediaTools(),
            clock: SystemClock(), photos: SystemPhotosSaver(), clipboard: SystemClipboard(),
            intake: SystemFileIntake(), isPreview: false)
        ctx.background.allowsDetach = false      // the sheet hands off through `ShareCore`, never `detach()`
        ctx.frameEdge = 160                      // ~120 MB in an extension: small frames
        let model = ShareModel(context: ctx, pipeline: Pipeline(context: ctx))
        // The original follows the sheet out through a background URLSession of its own (only one
        // process may use a background session at a time), recorded in the app group.
        ctx.photosLedger = .shared()
        ctx.originals = OriginalFetcher(
            identifier: BackgroundSessionID.share(job: model.core.jobID), transport: URLSessionBackgroundTransport(),
            pending: .shared(), store: store, clock: ctx.clock)
        model.core.openApp = openApp
        model.core.complete = complete
        switch await ShareInbox.load(inputItems, store: store) {
        case .link(let url): model.pipeline.start(link: url)
        case .file(let url): model.pipeline.start(file: url)
        case .none: model.pipeline.start(pastedText: nil)
        }
        return model
    }

    /// For `ShareRootView` previews: an idle pipeline over `PreviewClient`. Start it with
    /// `pipeline.start(link:)` / `start(file:)` like the controller does.
    public static func preview(_ scenario: PreviewScenario = .happy) -> ShareModel {
        let ctx = PipelineContext.preview(scenario, timeScale: 1, clock: SystemClock())
        return ShareModel(context: ctx, pipeline: Pipeline(context: ctx), notifier: SilentNotifier())
    }
}

/// Previews never post: no notification center, and nothing to open.
private struct SilentNotifier: NotificationPosting {
    func post(_ kind: Notifications.Kind, jobID: UUID) async {}
}
#endif

// MARK: - The logic behind it

/// What closing the sheet and "trim in cobalt" do. Not iOS specific, so the Mac test run covers it.
@MainActor @Observable
final class ShareCore {
    enum Outcome: Sendable, Equatable { case dismissed, continuesInBackground }

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let pipeline: Pipeline
    @ObservationIgnored let notifier: any NotificationPosting
    @ObservationIgnored let jobID = UUID()
    /// Keeps this run's Live Activity current through the server (CONTRACT-LIVE.md 2.5).
    @ObservationIgnored let relay: ShareLiveRelay
    @ObservationIgnored var openApp: (@MainActor (URL) async -> Bool)?
    @ObservationIgnored var complete: (@MainActor () -> Void)?

    /// What the server can do, as last read: the sheet hides "make webp" when it has no studio.
    /// Starts as the context's (unknown until the pipeline has asked, or the preview scenario's).
    private(set) var capabilities: Capabilities

    /// The countdown (CONTRACT-SYNC.md decisions 1 to 5); see `ShareCore+AutoContinue.swift`.
    var autoContinue: AutoContinue
    @ObservationIgnored var countdownTask: Task<Void, Never>?
    @ObservationIgnored var assistiveRunning: Bool
    @ObservationIgnored var closed = false

    init(
        context: PipelineContext, pipeline: Pipeline, notifier: any NotificationPosting,
        liveEnvironment: LiveEnvironment? = LiveEnvironment.current,
        assistiveRunning: Bool = AssistiveTech.isRunning
    ) {
        self.ctx = context
        self.pipeline = pipeline
        self.notifier = notifier
        self.capabilities = context.capabilities
        self.assistiveRunning = assistiveRunning
        self.autoContinue = context.settings.autoContinue ? .armed : .off
        self.relay = ShareLiveRelay(context: context, pipeline: pipeline, environment: liveEnvironment)
        if context.notifier == nil { context.notifier = notifier }
        // The sheet's run id is the job id, so the activity, the `SharedJob` and the server agree (2.1).
        pipeline.nextLiveRunID = jobID
        context.live = relay
        let previous = context.capabilitiesChanged
        context.capabilitiesChanged = { [weak self] caps in
            self?.capabilities = caps
            self?.relay.kick()
            self?.evaluateAutoContinue()
            previous?(caps)
        }
        observeAutoContinue()
    }

    /// webp, studio and hosting exist on this server (a fork, old or new); plain cobalt only saves.
    var webpAvailable: Bool { capabilities.studio }

    /// Closing now has something to save (`close()` leaves a job and a notification).
    var isRendering: Bool {
        if case .rendering = pipeline.state { return true }
        return false
    }

    var isLong: Bool {
        guard let d = pipeline.media?.duration else { return false }
        return d > pipeline.maxClipSeconds
    }

    /// A save or a render is on the server for this sheet, and the server finishes it unpolled.
    /// (A render whose POST has not answered yet has no job to hand over: a moment later it does.)
    var canContinueInBackground: Bool {
        guard pipeline.sessionID != nil, capabilities.studio else { return false }
        switch pipeline.state {
        case .rendering: return pipeline.renderJobID != nil
        case .fetching, .saving: return true
        default: return false
        }
    }

    /// Closing the sheet. A render in flight always carries on (a `SharedJob(.rendering)` for the
    /// app, and the owner told: by the server when it has the notify bridge, else by a local
    /// notification); so does a save when the server can tell the owner. Anything else just stops.
    func close() async -> Outcome {
        if canContinueInBackground, isRendering || capabilities.notifyBridge {
            return await continueInBackground()
        }
        return await dismiss()
    }

    /// "continue in background" (and what closing does mid-work): the work stays with the server,
    /// the sheet goes. Without the work to continue it is a plain dismissal.
    ///
    /// The order is the extension's lifetime: the `SharedJob` first (it is a local write), then the
    /// opt-in (a network call, raced against a timeout: the process is torn down once the sheet is
    /// completed), then the sheet completes.
    func continueInBackground() async -> Outcome {
        guard canContinueInBackground, let sid = pipeline.sessionID else { return await dismiss() }
        defer { complete?() }
        noteClosing()
        let rendering = isRendering
        let stage: SharedJob.Stage
        if rendering, let renderJob = pipeline.renderJobID { stage = .rendering(job: renderJob) } else { stage = .saving }
        ctx.jobs.upsert(makeJob(stage: stage, wantsTrim: false))
        relay.detach()                              // the server keeps the island current through the work
        let optIn = NotifyOptIn(on: rendering ? [.rendered, .failed] : [.saved, .failed], label: pipeline.notifyLabel)
        handOffOriginal()                           // before the cancel: a keep download running here dies with it
        pipeline.cancel()
        let told = await ctx.registerNotify(session: sid, optIn, source: .shareSheet)
        pipeline.removeTemporaryFiles()
        if !told {
            // no bridge on this server (or it did not answer): all that is left is this process's
            // own word, which says "still going", not "done"
            await notifier.requestAuthorization()   // the sheet closes with work left: the moment this notification matters
            await notifier.post(rendering ? .stillMaking : .stillSaving, jobID: jobID)
        }
        return .continuesInBackground
    }

    private func dismiss() async -> Outcome {
        defer { complete?() }
        noteClosing()
        handOffOriginal()                           // closing at "ready" must not throw the keep download away
        pipeline.cancel()
        pipeline.removeTemporaryFiles()
        await relay.finish()                        // nothing carries on: the island goes
        return .dismissed
    }

    /// "trim in cobalt": a `wantsTrim` job, then open the app (the system may refuse: then a
    /// notification asks). Either way the app takes the handoff on its next foreground.
    func handOffToApp() async {
        defer { complete?() }
        noteClosing()
        guard pipeline.sessionID != nil else { return }
        ctx.jobs.upsert(makeJob(stage: .ready, wantsTrim: true))
        relay.detach()                              // the app takes the run over
        pipeline.cancel()
        let url = URL(string: Notifications.url(forJob: jobID))!
        let opened = await openApp?(url) ?? false
        if !opened {
            // the notification is the only way back to the clip: make sure it can be shown (asked once,
            // in context; a no-op once answered)
            await notifier.requestAuthorization()
            await notifier.post(.trimInCobalt, jobID: jobID)
        }
    }

    func makeJob(stage: SharedJob.Stage, wantsTrim: Bool) -> SharedJob {
        var link: URL?
        if case .link(let info) = pipeline.input { link = info.url }
        return SharedJob(
            id: jobID, origin: .shareExtension, link: link, sessionID: pipeline.sessionID,
            media: pipeline.media, trim: pipeline.trim, stage: stage, wantsTrim: wantsTrim,
            pickedUp: false, updatedAt: ctx.clock.now())
    }
}

// MARK: - Intake

/// What the extension was handed, in the order of preference: a movie, a web URL, text with a link.
enum ShareInput: Sendable, Equatable {
    case link(URL)
    case file(URL)       // already copied into the store's inbox
    case none
}

@MainActor
enum ShareInbox {
    static func load(_ items: [NSExtensionItem], store: OfflineStore) async -> ShareInput {
        let providers = items.flatMap { $0.attachments ?? [] }
        let movie = UTType.movie.identifier
        let url = UTType.url.identifier
        let text = UTType.plainText.identifier

        for provider in providers where provider.hasItemConformingToTypeIdentifier(movie) {
            let dir = store.inboxURL(for: "shared").deletingLastPathComponent()
            if let copied = await copyMovie(provider, into: dir) { return .file(copied) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(url) {
            if let link = await loadURL(provider), LinkInfo(link) != nil { return .link(link) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(text) {
            if let string = await loadString(provider), let link = LinkInfo.firstLink(in: string) { return .link(link) }
        }
        // Some apps put the link only in the item's own text fields.
        for item in items {
            for string in [item.attributedContentText?.string, item.attributedTitle?.string] {
                if let string, let link = LinkInfo.firstLink(in: string) { return .link(link) }
            }
        }
        return .none
    }

    /// Copies with `FileManager` inside the handler (the system deletes its temp file right after);
    /// never through `Data`, the extension has ~120 MB.
    private static func copyMovie(_ provider: NSItemProvider, into dir: URL) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { source, _ in
                guard let source else { continuation.resume(returning: nil); return }
                let destination = dir.appendingPathComponent(fileName(for: source, suggested: suggested))
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The system names its temp copy after the type ("QuickTime movie.mov"); the name the other
    /// app gave the file (`IMG_0412`) is what the library should show, with the copy's extension.
    nonisolated static func fileName(for copy: URL, suggested: String?) -> String {
        let ext = copy.pathExtension
        guard let suggested, !suggested.isEmpty else { return copy.lastPathComponent }
        let stem = (suggested as NSString).pathExtension.isEmpty ? suggested : (suggested as NSString).deletingPathExtension
        guard let base = SafeFileName.clean(stem) else { return copy.lastPathComponent }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: String.self) { string, _ in continuation.resume(returning: string) }
        }
    }
}
