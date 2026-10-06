import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The Mac's "save to a folder": the counterpart of the iPhone's photos album. Every video and webp that
/// lands in the offline store is copied (the store keeps its own copy) into a folder in Finder, once,
/// with a name a person can read (`FolderNaming`). ON by default, into `~/Movies/cobalt`, which is created.
///
/// The rules, all decided here and in `FolderLedger`:
/// - **Once per item, durable.** `FolderLedger` records every copy under the same keys as the photos
///   ledger (`PhotosKey`). Done is forever: a file the owner deleted, renamed or moved out of the folder is
///   never put back, and neither eviction nor a refill nor removing a whole record brings an item back.
/// - **Survives a kill.** A copy is a hidden `.part` file renamed into place; a claim left by a dead
///   launch is settled by the next pass (see `FolderLedger`).
/// - **Renames do not follow.** The name is decided when the file is copied; renaming the media in cobalt
///   later leaves the file as it is.
/// - **Existing items are offered, not copied.** The first time the feature runs, when it is turned back
///   on, and when the folder changes, what cobalt already holds (and the folder has no entry for) is
///   marked "already there"; the owner is offered "also save the N already in cobalt?" (`includeExisting`),
///   and the settings row keeps offering it until they answer or the items are gone.
/// - **A chosen folder is a security-scoped bookmark**, so it keeps working once the app is sandboxed; a
///   chosen folder that is gone is never re-created (the status says so), the default one is.
/// - **iOS:** nothing. `isAvailable` is false and no pass ever runs.
///
/// Created with `AppModel`; `FolderSync.preview(_:)` is the disk-free twin for previews.
@MainActor @Observable
public final class FolderSync {
    public enum Problem: Sendable, Equatable { case folderMissing, notAllowed, diskFull }
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
    }
    public struct Status: Sendable, Equatable {
        public var available: Bool
        public var enabled: Bool               // Settings.folderSync
        public var path: String                // display path, `~` for the home folder
        public var isDefault: Bool
        public var saved: Int                  // copies in this folder
        public var waiting: Int                // kept on this Mac, not copied yet
        public var existing: Int               // already in cobalt when the folder was set up, not copied (offered)
        public var gaveUp: Int
        public var progress: Progress?         // non-nil while copying
        public var problem: Problem?

        public init(
            available: Bool = true, enabled: Bool, path: String = "~/Movies/cobalt", isDefault: Bool = true,
            saved: Int = 0, waiting: Int = 0, existing: Int = 0, gaveUp: Int = 0, progress: Progress? = nil,
            problem: Problem? = nil
        ) {
            self.available = available
            self.enabled = enabled
            self.path = path
            self.isDefault = isDefault
            self.saved = saved
            self.waiting = waiting
            self.existing = existing
            self.gaveUp = gaveUp
            self.progress = progress
            self.problem = problem
        }
    }
    public enum ChooseOutcome: Sendable, Equatable {
        /// The folder is set. `existing`: how many items already in cobalt the owner is offered.
        case chosen(existing: Int)
        /// Same folder as before.
        case unchanged
        /// The folder could not be opened or remembered.
        case failed
    }

    // MARK: State

    struct Base: Equatable {
        var path: String
        var isDefault = true
        var saved = 0
        var waiting = 0
        var existing = 0
        var gaveUp = 0
        var progress: Progress?
        var problem: Problem?
        /// key -> file name in the folder, for "show in Finder".
        var files: [String: String] = [:]
    }

    struct Engine {
        let settings: Settings
        let store: OfflineStore
        let ledger: FolderLedger
        let clock: any PipelineClock
        let available: Bool
        let defaultFolder: URL
        /// Records newer than this are "new" for the first-run offer; everything older is already there.
        let launchedAt: Date
    }

    var base: Base
    var previewStatus: Status?

    @ObservationIgnored let engine: Engine?
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    public var status: Status {
        if let previewStatus { return previewStatus }
        guard let engine else { return Status(available: false, enabled: false) }
        return Status(
            available: engine.available, enabled: engine.settings.folderSync, path: base.path, isDefault: base.isDefault,
            saved: base.saved, waiting: engine.settings.folderSync ? base.waiting : 0, existing: base.existing,
            gaveUp: base.gaveUp, progress: base.progress, problem: base.problem)
    }

    public var isAvailable: Bool { status.available }

    init(
        settings: Settings, store: OfflineStore, ledger: FolderLedger, clock: any PipelineClock = SystemClock(),
        available: Bool = FolderSync.platformHasFolder, defaultFolder: URL = FolderDestination.defaultURL
    ) {
        self.engine = Engine(
            settings: settings, store: store, ledger: ledger, clock: clock, available: available,
            defaultFolder: defaultFolder, launchedAt: clock.now())
        let record = ledger.destination
        self.base = Base(path: Self.display(record?.path ?? defaultFolder.path), isDefault: record == nil)
        guard available else { return }
        // The app only: every add to the store (a finished download, a refill) runs a pass. Whatever was
        // listening before (the photos album) keeps listening.
        let previous = store.onAdd
        store.onAdd = { [weak self] video, origin in
            previous?(video, origin)
            Task { @MainActor [weak self] in await self?.reconcile() }
        }
        Task { @MainActor [weak self] in
            await self?.refresh()
            await self?.reconcile()
        }
    }

    private init(preview: Status) {
        self.engine = nil
        self.previewStatus = preview
        self.base = Base(path: preview.path)
    }

    /// Mac only (the iPhone keeps the photos album).
    nonisolated static var platformHasFolder: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// `~/Movies/cobalt` for the real home, whatever the process's own home is.
    nonisolated static func display(_ path: String) -> String {
        let home = FolderDestination.realHome().path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Owner's actions

    /// Turns it on. Whatever cobalt holds that the folder has no entry for was saved while it was off (or
    /// before it ran): marked "already there", and the count is what the owner is offered.
    @discardableResult
    public func enable() async -> Int {
        if previewStatus != nil {
            previewStatus?.enabled = true
            return 3
        }
        guard let engine, engine.available else { return 0 }
        engine.settings.folderSync = true
        let existing = await markExisting(before: nil)
        await recount()
        await reconcile()
        return existing
    }

    public func disable() {
        if previewStatus != nil {
            previewStatus?.enabled = false
            previewStatus?.progress = nil
            return
        }
        engine?.settings.folderSync = false           // the pass in flight stops before its next item
        base.progress = nil
        base.problem = nil
    }

    /// "add N" (the offer after `enable` / `chooseFolder` / `resetToDefault`, and the settings row): the
    /// items that were already in cobalt are copied too. `include == false` is the other answer: nothing
    /// to do, they stay "already there" and the settings row keeps offering them.
    public func includeExisting(_ include: Bool) async {
        if previewStatus != nil {
            if include { previewStatus?.saved += previewStatus?.existing ?? 0; previewStatus?.existing = 0 }
            return
        }
        guard include, let engine else { return }
        let worker = currentWorker(engine)
        let videos = engine.store.videos
        await Task.detached(priority: .utility) { worker.includeExisting(videos) }.value
        await recount()
        await reconcile()
    }

    /// The owner picked a folder. The bookmark is made while the picker's scope is open. A folder the
    /// ledger already knows comes back with what was copied to it; otherwise what cobalt holds is
    /// "already there" and offered.
    public func chooseFolder(_ url: URL) async -> ChooseOutcome {
        if previewStatus != nil { previewStatus?.path = Self.display(url.path); previewStatus?.isDefault = false; return .chosen(existing: 3) }
        guard let engine, engine.available else { return .failed }
        let ledger = engine.ledger
        let defaultFolder = engine.defaultFolder
        let current = ledger.destination?.path ?? defaultFolder.path
        let prepared: (path: String, bookmark: Data?, isDefault: Bool, same: Bool)? = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let canonical = FolderDestination.canonical(url)
            let isDefault = canonical == FolderDestination.canonical(defaultFolder)
            let same = canonical == FolderDestination.canonical(URL(fileURLWithPath: current, isDirectory: true))
            if isDefault { return (defaultFolder.path, nil, true, same) }
            guard let bookmark = try? FolderDestination.makeBookmark(for: url) else { return nil }
            return (url.standardizedFileURL.path, bookmark, false, same)
        }.value
        guard let prepared else { return .failed }
        if prepared.same { return .unchanged }
        ledger.choose(path: prepared.path, bookmark: prepared.bookmark, isDefault: prepared.isDefault)
        return await destinationChanged()
    }

    /// Back to `~/Movies/cobalt`.
    public func resetToDefault() async -> ChooseOutcome {
        if previewStatus != nil { previewStatus?.path = "~/Movies/cobalt"; previewStatus?.isDefault = true; return .chosen(existing: 3) }
        guard let engine, engine.available else { return .failed }
        guard engine.ledger.destination != nil else { return .unchanged }
        engine.ledger.choose(path: engine.defaultFolder.path, bookmark: nil, isDefault: true)
        return await destinationChanged()
    }

    private func destinationChanged() async -> ChooseOutcome {
        guard let engine else { return .failed }
        let record = engine.ledger.destination
        base.path = Self.display(record?.path ?? engine.defaultFolder.path)
        base.isDefault = record == nil
        base.problem = nil
        let existing = await markExisting(before: nil)
        await recount()
        await reconcile()
        return .chosen(existing: existing)
    }

    /// Re-reads the ledger: foreground, and back to Settings.
    public func refresh() async {
        guard engine != nil, previewStatus == nil else { return }
        await recount()
    }

    // MARK: - The pass

    /// Copies what is eligible and not yet in the folder. One pass at a time: a call during a pass asks
    /// for another when it ends.
    public func reconcile() async {
        guard engine != nil, previewStatus == nil else { return }
        if let current = passTask {
            rerun = true
            await current.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.rerun = false
                await self.pass()
            } while self.rerun
            self.passTask = nil
        }
        passTask = task
        await task.value
    }

    private func pass() async {
        guard let engine, engine.available, engine.settings.folderSync else { return }
        let ledger = engine.ledger
        let defaultFolder = engine.defaultFolder
        let resolution = await Task.detached(priority: .utility) {
            FolderDestination.open(ledger: ledger, defaultFolder: defaultFolder)
        }.value
        let access: FolderAccess
        let id: String
        let path: String
        switch resolution {
        case .missing(let p):
            base.problem = .folderMissing
            base.path = Self.display(p)
            await recount()
            return
        case .notAllowed(let p):
            base.problem = .notAllowed
            base.path = Self.display(p)
            await recount()
            return
        case .ready(let a, let i, let p):
            access = a
            id = i
            path = p
        }
        defer { access.stop() }
        base.problem = nil
        base.path = Self.display(path)
        let worker = FolderWorker(ledger: ledger, destination: access.url, id: id, path: path, clock: engine.clock)

        // The first time this folder is seen: what is already in cobalt is offered, not copied.
        let videos = engine.store.videos
        let media = engine.store.media
        let launchedAt = engine.launchedAt
        let now = engine.clock.now()
        let todo = await Task.detached(priority: .utility) { () -> [FolderWorker.Candidate] in
            if !ledger.hasSection(id) { worker.markExisting(videos, before: launchedAt) }
            worker.cleanStrayParts(now: now)
            return worker.pending(videos, media: media)
        }.value
        guard !todo.isEmpty else { await recount(); return }

        base.progress = Progress(done: 0, total: todo.count)
        for candidate in todo {
            // "off" stops new copies before the next one
            guard engine.settings.folderSync else { break }
            let outcome = await Task.detached(priority: .utility) { worker.copy(candidate) }.value
            base.progress?.done += 1
            switch outcome {
            case .copied:
                base.saved += 1
                base.waiting = max(0, base.waiting - 1)
                base.files[candidate.key] = ""            // placeholder until the recount below names it
                Telemetry.log(.info, .sync, "folder copy", data: ["bytes": .bytes(candidate.bytes)])
            case .skipped:
                break
            case .stop(let problem):
                Telemetry.log(.warn, .sync, "folder copy stopped", data: ["problem": .string(String(describing: problem))])
                base.problem = problem
                base.progress = nil
                await recount()
                return
            }
        }
        base.progress = nil
        await recount()
    }

    // MARK: - Counting

    private func currentWorker(_ engine: Engine) -> FolderWorker {
        let record = engine.ledger.destination
        return FolderWorker(
            ledger: engine.ledger, destination: URL(fileURLWithPath: record?.path ?? engine.defaultFolder.path, isDirectory: true),
            id: record?.id ?? FolderLedger.defaultID, path: record?.path ?? engine.defaultFolder.path, clock: engine.clock)
    }

    /// Marks what the folder has no entry for as "already there"; returns how many that leaves offered.
    private func markExisting(before: Date?) async -> Int {
        guard let engine else { return 0 }
        let worker = currentWorker(engine)
        let videos = engine.store.videos
        return await Task.detached(priority: .utility) { worker.markExisting(videos, before: before) }.value
    }

    private func recount() async {
        guard let engine, engine.available else { return }
        let worker = currentWorker(engine)
        let videos = engine.store.videos
        let counts = await Task.detached(priority: .utility) { worker.counts(videos) }.value
        base.saved = counts.saved
        base.waiting = counts.waiting
        base.existing = counts.existing
        base.gaveUp = counts.gaveUp
        base.files = counts.files
        let record = engine.ledger.destination
        base.isDefault = record == nil
        if base.problem != .folderMissing, base.problem != .notAllowed { base.path = Self.display(record?.path ?? engine.defaultFolder.path) }
    }

    // MARK: - Finder

    /// This video has a copy in the folder (the ledger says so; whether Finder still has it is Finder's).
    public func hasCopy(_ video: StoredVideo) -> Bool {
        if previewStatus != nil { return true }
        return base.files[PhotosKey.of(video)] != nil
    }

    /// Any of these has a copy in the folder.
    public func hasCopy(any videos: [StoredVideo]) -> Bool { videos.contains(where: hasCopy) }

    #if os(macOS)
    /// "show in Finder" with videos: their copies, selected in the folder; the folder itself when none of
    /// them is there any more. With no videos: the folder.
    public func revealInFinder(_ videos: [StoredVideo] = []) async {
        guard let engine, previewStatus == nil else { return }
        let ledger = engine.ledger
        let defaultFolder = engine.defaultFolder
        let keys = videos.map { PhotosKey.of($0) }
        let found = await Task.detached(priority: .userInitiated) { () -> (folder: URL, files: [URL])? in
            guard case .ready(let access, let id, _) = FolderDestination.open(ledger: ledger, defaultFolder: defaultFolder) else { return nil }
            let items = ledger.items(id)
            let files = keys.compactMap { items[$0]?.file }
                .map { access.url.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            // the scope is left open on purpose: Finder is asked right after this, and `access` releases it
            return (access.url, files)
        }.value
        guard let found else {
            base.problem = .folderMissing
            return
        }
        if found.files.isEmpty {
            NSWorkspace.shared.open(found.folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(found.files)
        }
    }

    /// Passes again when the app comes to the front (a disk that came back, a folder the owner re-made).
    /// The notification closure is called by the system on a thread of its choosing: `@Sendable`, and it
    /// hops to the main actor explicitly.
    public func observeActivation() {
        guard activationObserver == nil, engine != nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
                await self?.reconcile()
            }
        }
    }
    #else
    /// No Finder here (the iPhone keeps the photos album).
    public func revealInFinder(_ videos: [StoredVideo] = []) async {}
    #endif

    // MARK: - Previews

    /// No disk: for `#Preview`s and `AppModel.preview`. The owner's actions move this fixed status around.
    public static func preview(_ status: Status) -> FolderSync { FolderSync(preview: status) }

    /// Replaces a preview instance's status. No effect on the real one.
    public func setPreviewStatus(_ status: Status) {
        guard previewStatus != nil else { return }
        previewStatus = status
    }
}
