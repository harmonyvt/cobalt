import CoreGraphics
import Foundation

/// Everything a pipeline (and the library model) reaches out to, in one place so live, preview and
/// test wiring differ only here. Not public: UI sees `AppModel`, `Pipeline` and `LibraryModel`.
@MainActor
final class PipelineContext {
    var client: any CobaltClient
    var capabilities: Capabilities
    let settings: Settings
    let store: OfflineStore
    let jobs: SharedJobStore
    /// Titles whose send failed, retried on foreground, on `library.refresh()` and with the next run.
    /// Lives next to the store's index (the app group's, shared with the extension).
    let titles: TitleQueue
    let tools: any MediaTools
    let clock: any PipelineClock
    let photos: any PhotosSaver
    let clipboard: any Clipboard
    let intake: any FileIntake
    /// Previews skip side effects a real run has (keeping the original on the device).
    let isPreview: Bool
    /// The app (not the extension, not previews) keeps a `SharedJob` per run with server work in
    /// flight, so a relaunch can pick it up (`AppModel.pickUpSharedJobs`).
    var recordsJobs = false

    /// Runs the owner closed with `Pipeline.detach()` while work was in flight: they finish here,
    /// not in any view.
    let background = BackgroundRuns()

    /// Mirrors the pipeline's run into a Live Activity (the app) or a relay (the share sheet);
    /// nil in previews and tests unless a fake is injected (CONTRACT-LIVE.md 2.5).
    var live: (any LiveSink)?

    /// The background download of originals (CONTRACT-SYNC.md decision 6): the app's, or the sheet's
    /// own. Nil in previews and tests unless one is injected.
    var originals: OriginalFetcher?
    /// The photos ledger (shared by the app and the extension) and, in the app only, the sync.
    var photosLedger: PhotosLedger?
    var photosSync: PhotosSync?

    /// "save to photos": the file goes to Photos (into the album when the app's sync has it on) and
    /// the item's key is recorded so the sync never adds it again.
    func savePhoto(fileURL: URL, isImage: Bool, key: String?) async throws {
        if let sync = photosSync, sync.hasEngine {
            try await sync.manualSave(fileURL: fileURL, isImage: isImage, key: key, saver: photos)
            return
        }
        let asset = try await photos.save(fileURL: fileURL, isImage: isImage)
        if let key, let ledger = photosLedger { ledger.recordManual(key, asset: asset, inAlbum: .no, now: clock.now()) }
    }

    func photosPlacement(forKey key: String) -> PhotosPlacement {
        if let sync = photosSync, sync.hasEngine { return sync.placement(key: key) }
        guard let entry = photosLedger?.entry(key), entry.state == .done, entry.inAlbum != .gone else { return .none }
        return entry.inAlbum == .yes ? .inAlbum : .inLibrary
    }

    /// The notify opt-ins this process holds (APP-API-CONTRACT 9).
    let notify = NotifyBridge()

    /// Hears when a run's work starts, moves or ends, so a continued-processing task can keep it alive
    /// while the app is off screen (the app on iOS; nil in the extension, on the Mac, in previews).
    var continued: (any ContinuedWorkSink)?

    /// The long edge, in pixels, of the filmstrip's frames. The share extension has ~120 MB, so it
    /// asks for small ones.
    var frameEdge: CGFloat = 360

    /// Who may be asked for notification permission, once, at the first moment a notification has a
    /// reason to exist: the owner closes a run that still has work in flight (`Pipeline.detach()`), or
    /// the share sheet closes mid-render. Never on a plain run. Nil in previews and tests that do not
    /// care. The app sets it live; `ShareCore` sets it for the extension.
    var notifier: (any NotificationPosting)?
    private var askedForNotifications = false

    /// Work is about to carry on without the screen (a detached run): "your webp is ready" now has a
    /// reason to exist, and the app is active, so the system permission prompt belongs here. Not at
    /// launch and not when a run merely starts (it would cover the focus card).
    func notificationsNowUseful() {
        guard !askedForNotifications, let notifier else { return }
        askedForNotifications = true
        Task { await notifier.requestAuthorization() }
    }

    /// Set by `AppModel`: a server error said the key is revoked.
    var keyRejected: (@MainActor () -> Void)?
    /// Set by `AppModel`: capabilities were re-read by the pipeline.
    var capabilitiesChanged: (@MainActor (Capabilities) -> Void)?

    init(
        client: any CobaltClient, capabilities: Capabilities, settings: Settings, store: OfflineStore,
        jobs: SharedJobStore, tools: any MediaTools, clock: any PipelineClock, photos: any PhotosSaver,
        clipboard: any Clipboard, intake: any FileIntake, isPreview: Bool
    ) {
        self.client = client
        self.capabilities = capabilities
        self.settings = settings
        self.store = store
        self.jobs = jobs
        self.titles = TitleQueue(fileURL: store.root.appendingPathComponent("titles.json"))
        self.tools = tools
        self.clock = clock
        self.photos = photos
        self.clipboard = clipboard
        self.intake = intake
        self.isPreview = isPreview
    }

    func refreshCapabilities() async -> Capabilities {
        let fresh = await client.capabilities()
        capabilities = fresh
        capabilitiesChanged?(fresh)
        return fresh
    }
}
