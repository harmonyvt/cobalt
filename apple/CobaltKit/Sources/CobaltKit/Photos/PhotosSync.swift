import Foundation
import Observation

/// Where the run's original is in the owner's Photos, as the "save to photos" button shows it
/// (CONTRACT-SYNC.md decision 12).
public enum PhotosPlacement: Sendable, Equatable { case none, inAlbum, inLibrary }

/// The photos album (CONTRACT-SYNC.md decisions 7 to 11). The app only: the share extension never
/// syncs. Created with `AppModel`; `PhotosSync.preview(_:)` is the PhotoKit-free twin for previews.
///
/// The offline store is the source: every eligible original (and webp, when asked) that has a file
/// on this phone is added to Photos once, and into the album named `cobalt` when the access allows
/// it. What was added is recorded in the `PhotosLedger`, which is keyed so that neither eviction nor
/// a deletion in Photos ever brings an item back.
@MainActor @Observable
public final class PhotosSync {
    public enum Access: Sendable, Equatable { case unavailable, notAsked, album, libraryLimited, libraryAddOnly, denied }
    public enum Problem: Sendable, Equatable { case outOfSpace, libraryUnavailable }
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
    }
    public struct Status: Sendable, Equatable {
        public var access: Access
        public var enabled: Bool               // Settings.photosAlbumSync
        public var paused: Bool                // enabled, keepVideosOnDevice off
        public var added: Int
        public var waiting: Int
        public var gaveUp: Int
        public var progress: Progress?         // non-nil while adding
        public var problem: Problem?

        public init(
            access: Access, enabled: Bool, paused: Bool = false, added: Int = 0, waiting: Int = 0,
            gaveUp: Int = 0, progress: Progress? = nil, problem: Problem? = nil
        ) {
            self.access = access
            self.enabled = enabled
            self.paused = paused
            self.added = added
            self.waiting = waiting
            self.gaveUp = gaveUp
            self.progress = progress
            self.problem = problem
        }
    }
    public enum EnableOutcome: Sendable, Equatable { case on(existing: Int), refused }

    /// The title of the album (CONTRACT-SYNC.md decision 7).
    static let albumTitle = "cobalt"

    // MARK: State

    struct Base: Equatable {
        var access: Access = .notAsked
        var added = 0
        var waiting = 0
        var gaveUp = 0
        var progress: Progress?
        var problem: Problem?
    }

    struct Engine {
        let settings: Settings
        let store: OfflineStore
        let ledger: PhotosLedger
        let library: any PhotoLibrary
        let clock: any PipelineClock
        let available: Bool
        /// Whether the system can show its permission prompt right now (the app is in front). A
        /// background wake never asks: the prompt would not appear, and the answer would be "not asked".
        let isForeground: @MainActor () -> Bool
    }

    var base = Base()
    /// Bumped whenever the ledger changed under a button: `placement` reads it.
    var revision = 0
    /// Preview instances answer from a fixed status and never touch PhotoKit.
    var previewStatus: Status?

    @ObservationIgnored let engine: Engine?
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    /// Keys `enable()` marked "already there": the backfill answer un-marks them.
    @ObservationIgnored private var pendingBackfill: [String] = []
    @ObservationIgnored private var existsCache: [String: (exists: Bool, at: Date)] = [:]
    /// The permission prompt was shown (or tried) in this process: never twice, whatever the answer.
    @ObservationIgnored private var askedThisLaunch = false

    public var status: Status {
        if let previewStatus { return previewStatus }
        guard let engine else { return Status(access: .unavailable, enabled: false) }
        let enabled = engine.settings.photosAlbumSync
        return Status(
            access: base.access, enabled: enabled, paused: enabled && !engine.settings.keepVideosOnDevice,
            added: base.added, waiting: enabled ? base.waiting : 0, gaveUp: base.gaveUp,
            progress: base.progress, problem: base.problem)
    }

    public var isAvailable: Bool { status.access != .unavailable }

    /// A real sync (PhotoKit behind it), not a preview.
    var hasEngine: Bool { engine != nil }

    init(
        settings: Settings, store: OfflineStore, ledger: PhotosLedger, library: any PhotoLibrary,
        clock: any PipelineClock = SystemClock(), available: Bool = PhotosSync.platformHasPhotos,
        isForeground: @escaping @MainActor () -> Bool = { true }
    ) {
        self.engine = Engine(
            settings: settings, store: store, ledger: ledger, library: library, clock: clock, available: available,
            isForeground: isForeground)
        base.access = available ? Self.access(of: library) : .unavailable
        // The app only: every add to the store (a finished download, a refill) runs the sync.
        store.onAdd = { [weak self] _, _ in
            Task { @MainActor [weak self] in await self?.reconcile() }
        }
        recount()
    }

    private init(preview: Status) {
        self.engine = nil
        self.previewStatus = preview
    }

    /// iPhone and iPad (decision 13): on the Mac the section is hidden and nothing syncs.
    nonisolated static var platformHasPhotos: Bool {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }

    // MARK: - Access

    /// The access matrix (decision 7).
    static func access(of library: any PhotoLibrary) -> Access {
        let rw = library.readWriteStatus()
        switch rw {
        case .authorized: return .album
        case .limited: return .libraryLimited
        case .notDetermined, .denied:
            switch library.status() {
            case .authorized: return .libraryAddOnly
            case .denied: return .denied
            case .notDetermined: return rw == .denied ? .denied : .notAsked
            }
        }
    }

    private var canWork: Bool {
        switch base.access {
        case .album, .libraryLimited, .libraryAddOnly: return true
        default: return false
        }
    }

    /// Read access (can check that an asset still exists).
    private var canRead: Bool { base.access == .album || base.access == .libraryLimited }

    // MARK: - Owner's actions

    /// Asks for read-write access and turns the setting on unless the owner refused everything.
    public func enable() async -> EnableOutcome {
        if previewStatus != nil {
            previewStatus?.enabled = true
            if previewStatus?.access == .denied || previewStatus?.access == .notAsked { previewStatus?.access = .album }
            return .on(existing: 3)
        }
        guard let engine, engine.available else { return .refused }
        if engine.library.readWriteStatus() == .notDetermined { _ = await engine.library.requestReadWrite() }
        base.access = Self.access(of: engine.library)
        guard canWork else { revision += 1; return .refused }
        engine.settings.photosAlbumSync = true
        // What is already in cobalt waits for the owner's answer: marked "already there" now (no
        // suspension between turning the setting on and this), un-marked by `includeExisting(true)`.
        let existing = eligibleVideos().filter { engine.ledger.entry(PhotosKey.of($0)) == nil }
        pendingBackfill = existing.map { PhotosKey.of($0) }
        engine.ledger.skipPreexisting(pendingBackfill, now: engine.clock.now())
        recount()
        revision += 1
        if existing.isEmpty { Task { await reconcile() } }
        return .on(existing: existing.count)
    }

    /// The backfill answer after `enable()` returned `.on(existing: n)`.
    public func includeExisting(_ include: Bool) async {
        if previewStatus != nil {
            if include { previewStatus?.waiting += 3 }
            return
        }
        guard let engine else { return }
        let keys = pendingBackfill
        pendingBackfill = []
        if include { engine.ledger.unskipPreexisting(keys) }
        recount()
        revision += 1
        await reconcile()
    }

    public func disable() {
        if previewStatus != nil {
            previewStatus?.enabled = false
            previewStatus?.paused = false
            previewStatus?.progress = nil
            return
        }
        engine?.settings.photosAlbumSync = false      // the pass in flight stops before its next item
        base.progress = nil
        base.problem = nil
        revision += 1
    }

    /// Turning it on marks webps already kept as skipped (no prompt); it applies from now on.
    public func setIncludeWebps(_ on: Bool) {
        guard let engine else { return }
        if on {
            let existing = engine.store.videos.filter { $0.kind == .webp && fileIsHere($0) }
            engine.ledger.skipPreexisting(existing.map { PhotosKey.of($0) }, now: engine.clock.now())
        }
        engine.settings.photosSyncWebps = on
        recount()
        revision += 1
    }

    /// Re-reads access and the ledger: foreground, and back from Settings.
    public func refresh() async {
        guard let engine else { return }
        base.access = engine.available ? Self.access(of: engine.library) : .unavailable
        recount()
        revision += 1
    }

    // MARK: - The pass

    /// Adds what is eligible and not yet in Photos. One pass at a time: a call during a pass asks for
    /// another when it ends.
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

    private enum Outcome { case added, skipped, stop(Problem?), accessChanged }

    private func pass() async {
        guard let engine else { return }
        base.access = engine.available ? Self.access(of: engine.library) : .unavailable
        base.problem = nil
        defer { base.progress = nil; recount(); revision += 1 }
        guard engine.settings.photosAlbumSync, engine.settings.keepVideosOnDevice else { return }
        // The album is on by default: the first time something is about to be saved, ask for access
        // (the permission copy says why), here and not at launch.
        if base.access == .notAsked, !pendingVideos().isEmpty { await askForAccessOnce(reason: "first save") }
        guard canWork else { return }

        if base.access == .album { await repairAlbum() }

        let todo = pendingVideos()
        guard !todo.isEmpty else { return }
        base.progress = Progress(done: 0, total: todo.count)
        for video in todo {
            // "disable stops new adds", and so does turning keep off: the album is filled from what is kept
            guard engine.settings.photosAlbumSync, engine.settings.keepVideosOnDevice else { break }
            let outcome = await add(video)
            base.progress?.done += 1
            switch outcome {
            case .added:
                base.added += 1
                base.waiting = max(0, base.waiting - 1)
                revision += 1
            case .skipped:
                break
            case .stop(let problem):
                base.problem = problem
                return
            case .accessChanged:
                base.access = Self.access(of: engine.library)
                return
            }
        }
    }

    /// The new asset: claimed, added (into the album when the access allows it), then marked done.
    private func add(_ video: StoredVideo) async -> Outcome {
        guard let engine else { return .skipped }
        let key = PhotosKey.of(video)
        let ledger = engine.ledger
        switch ledger.claim(key, now: engine.clock.now()) {
        case .alreadyDone, .skipped, .inFlight:
            return .skipped
        case .claimed:
            break
        case .doubt(let old):
            // A claim from before a crash: with read access the asset says whether it landed; add-only
            // cannot tell, and never twice beats maybe-missing.
            if canRead, let asset = old.asset, !engine.library.existingAssets(among: [asset]).contains(asset) {
                ledger.release(key)
                guard case .claimed = ledger.claim(key, now: engine.clock.now()) else { return .skipped }
            } else if canRead, old.asset == nil {
                ledger.release(key)
                guard case .claimed = ledger.claim(key, now: engine.clock.now()) else { return .skipped }
            } else {
                ledger.finish(key, asset: old.asset, inAlbum: .no, now: engine.clock.now())
                return .skipped
            }
        }
        guard let file = video.fileURL, FileManager.default.fileExists(atPath: file.path) else {
            ledger.release(key)
            return .skipped
        }
        var albumID: String?
        if base.access == .album { albumID = try? await ensureAlbum() }
        do {
            let asset = try await engine.library.addAsset(
                fileURL: file, isImage: Self.isStill(video), albumID: albumID,
                placeholder: { id in ledger.recordAsset(key, id) })
            Telemetry.log(.info, .photos, "album add", data: ["album": .bool(albumID != nil), "kind": .string(video.kind.rawValue), "bytes": .bytes(video.bytes)])
            ledger.finish(key, asset: asset, inAlbum: albumID == nil ? .no : .yes, now: engine.clock.now())
            return .added
        } catch {
            return classify(error, key: key)
        }
    }

    private func classify(_ error: any Error, key: String) -> Outcome {
        guard let engine else { return .skipped }
        let now = engine.clock.now()
        if let e = error as? PhotosError {
            switch e {
            case .denied:
                engine.ledger.release(key)
                return .accessChanged
            case .unreadable:
                engine.ledger.release(key)
                return .skipped
            case .failed: break
            }
        }
        let ns = error as NSError
        let code = photosErrorCode(error) ?? ns.code
        Telemetry.log(.warn, .photos, "album add failed", data: ["code": .int(code), "domain": .string(ns.domain)])
        if code == 3305 || (ns.domain == NSPOSIXErrorDomain && code == 28) {          // not enough space
            engine.ledger.release(key)
            return .stop(.outOfSpace)
        }
        if [3114, 3142, 3143].contains(code) {                                         // library unavailable
            engine.ledger.release(key)
            return .stop(.libraryUnavailable)
        }
        if ns.domain == "PHPhotosErrorDomain", code == 3311 || code == 3310 {          // access denied / restricted
            engine.ledger.release(key)
            return .accessChanged
        }
        engine.ledger.fail(key, code: code, now: now)
        return .skipped
    }

    /// The permission prompt, once per launch, only while the app is in front and the system has not
    /// been asked yet. Whatever the owner answers is then the access mode (decision 7): full access
    /// fills the album, limited or add-only fills the library, a refusal leaves settings saying so.
    private func askForAccessOnce(reason: String) async {
        guard let engine, engine.available, !askedThisLaunch, engine.isForeground(),
              engine.library.readWriteStatus() == .notDetermined else { return }
        askedThisLaunch = true
        Telemetry.log(.info, .photos, "photos access asked", data: ["reason": .string(reason)])
        _ = await engine.library.requestReadWrite()
        base.access = Self.access(of: engine.library)
        Telemetry.log(.info, .photos, "photos access answered", data: ["access": .string(String(describing: base.access))])
        revision += 1
    }

    // MARK: - An asset that is already in Photos

    /// The upload of a video the owner picked from their photo library: the asset is already in Photos,
    /// so it must not be added again. It is recorded in the ledger under the original's key
    /// (`s:<session>`) as this asset, and, with the album on and full access, put into the cobalt
    /// album (the existing asset, no copy). With the album off, or without full access, it is only
    /// recorded: nothing adds the video a second time, and a later upgrade to full access moves it into
    /// the album like any library-only item. Call it before the original is stored, so the store's
    /// `onAdd` pass already finds the entry.
    public func adoptExistingAsset(localIdentifier: String, forSession sessionID: String) async {
        await adoptExistingAsset(localIdentifier: localIdentifier, key: PhotosKey.original(session: sessionID))
    }

    /// `adoptExistingAsset(localIdentifier:forSession:)` for a video that is already stored.
    public func adoptExistingAsset(localIdentifier: String, for video: StoredVideo) async {
        await adoptExistingAsset(localIdentifier: localIdentifier, key: PhotosKey.of(video))
    }

    func adoptExistingAsset(localIdentifier: String, key: String) async {
        guard let engine, previewStatus == nil, !localIdentifier.isEmpty else { return }
        let ledger = engine.ledger
        let now = engine.clock.now()
        switch ledger.claim(key, now: now) {
        case .claimed:
            break
        case .doubt:
            ledger.release(key)
            guard case .claimed = ledger.claim(key, now: now) else { return }
        case .alreadyDone, .skipped, .inFlight:
            Telemetry.log(.info, .photos, "photos asset adopt skipped", data: ["reason": "already known"])
            return
        }
        var albumID: String?
        if engine.settings.photosAlbumSync, engine.settings.keepVideosOnDevice {
            if base.access == .notAsked || base.access == .denied {
                base.access = engine.available ? Self.access(of: engine.library) : .unavailable
            }
            if base.access == .notAsked { await askForAccessOnce(reason: "picked video") }
            if base.access == .album { albumID = try? await ensureAlbum() }
        }
        var inAlbum = PhotosEntry.InAlbum.no
        if let albumID {
            do {
                try await engine.library.addToAlbum(assetIDs: [localIdentifier], albumID: albumID)
                inAlbum = .yes
            } catch {
                Telemetry.log(.warn, .photos, "photos asset adopt album add failed", data: Telemetry.errorData(error))
            }
        }
        ledger.finish(key, asset: localIdentifier, inAlbum: inAlbum, now: engine.clock.now())
        Telemetry.log(.info, .photos, "photos asset adopted", data: ["album": .bool(inAlbum == .yes), "access": .string(String(describing: base.access))])
        recount()
        revision += 1
    }

    // MARK: - Album

    private static let albumGate = AsyncGate()

    /// The album's identifier: the ledger's, else a user album titled `cobalt`, else a new one. Created
    /// at most once, whoever asks first.
    private func ensureAlbum() async throws -> String {
        guard let engine else { throw PhotosError.denied }
        await Self.albumGate.acquire()
        defer { Self.albumGate.release() }
        let known = engine.ledger.album
        if let found = engine.library.findAlbum(id: known?.id, title: Self.albumTitle) {
            if found.id != known?.id { engine.ledger.setAlbum(PhotosAlbumRecord(id: found.id, title: found.title)) }
            return found.id
        }
        // the remembered album is gone and nothing carries its name: one new one
        let created = try await engine.library.createAlbum(title: Self.albumTitle)
        engine.ledger.setAlbum(PhotosAlbumRecord(id: created.id, title: created.title))
        return created.id
    }

    /// After an upgrade to full access: library-only items go into the album, when they still exist.
    /// Items the owner took out of the album stay out (their entry says `yes`).
    private func repairAlbum() async {
        guard let engine else { return }
        let snapshot = engine.ledger.snapshot()
        let candidates = snapshot.items.filter { _, e in
            e.state == .done && e.origin == .sync && e.inAlbum == .no && e.asset != nil
        }
        guard !candidates.isEmpty else { return }
        let ids = candidates.compactMap { $0.value.asset }
        let alive = engine.library.existingAssets(among: ids)
        let gone = candidates.filter { !alive.contains($0.value.asset ?? "") }.map(\.key)
        let moving = candidates.filter { alive.contains($0.value.asset ?? "") }
        engine.ledger.setInAlbum(gone, .gone)
        guard !moving.isEmpty, let albumID = try? await ensureAlbum() else { return }
        do {
            try await engine.library.addToAlbum(assetIDs: moving.compactMap { $0.value.asset }, albumID: albumID)
            engine.ledger.setInAlbum(moving.map(\.key), .yes)
        } catch {
            // next pass
        }
    }

    // MARK: - The owner's own save

    /// "save to photos" pressed: an explicit request, recorded as a new asset so the sync never adds
    /// that item again. In the app, with the album on, it goes into the album.
    func manualSave(fileURL: URL, isImage: Bool, key: String?, saver: any PhotosSaver) async throws {
        guard let engine else {
            try await saver.save(fileURL: fileURL, isImage: isImage)
            return
        }
        let access = engine.available ? Self.access(of: engine.library) : .unavailable
        base.access = access
        if engine.settings.photosAlbumSync, access == .album, let albumID = try? await ensureAlbum() {
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else { throw PhotosError.unreadable }
            do {
                let asset = try await engine.library.addAsset(
                    fileURL: fileURL, isImage: isImage, albumID: albumID, placeholder: { _ in })
                if let key { engine.ledger.recordManual(key, asset: asset, inAlbum: .yes, now: engine.clock.now()) }
                revision += 1
                return
            } catch let e as PhotosError {
                throw e
            } catch {
                Telemetry.log(.error, .photos, "manual album save failed", data: Telemetry.errorData(error))
                throw PhotosError.failed(code: photosErrorCode(error) ?? (error as NSError).code)
            }
        }
        let asset = try await saver.save(fileURL: fileURL, isImage: isImage)
        if let key { engine.ledger.recordManual(key, asset: asset, inAlbum: .no, now: engine.clock.now()) }
        revision += 1
    }

    // MARK: - Where an item is

    /// Where this stored original is in Photos right now.
    public func placement(of video: StoredVideo) -> PhotosPlacement {
        placement(key: PhotosKey.of(video))
    }

    func placement(key: String) -> PhotosPlacement {
        _ = revision                                              // a button redraws when the ledger moves
        guard let engine, previewStatus == nil, let entry = engine.ledger.entry(key), entry.state == .done else { return .none }
        if entry.inAlbum == .gone { return .none }
        // With read access: an asset the owner deleted is not "in your photos" any more.
        if canRead, let asset = entry.asset, !assetExists(asset) { return .none }
        return entry.inAlbum == .yes ? .inAlbum : .inLibrary
    }

    private func assetExists(_ id: String) -> Bool {
        guard let engine else { return false }
        let now = engine.clock.now()
        if let hit = existsCache[id], now.timeIntervalSince(hit.at) < 3 { return hit.exists }
        let exists = engine.library.existingAssets(among: [id]).contains(id)
        existsCache[id] = (exists, now)
        return exists
    }

    // MARK: - What is eligible

    /// Everything cobalt keeps, webps when asked (decision 8, amended 2026-10-05: uploads count too, a
    /// video the owner picked from Photos is adopted in the ledger first, so it is never added twice).
    /// The file must be on this phone: an evicted one has nothing to add until a refill brings it back.
    static func isEligible(_ video: StoredVideo, includeWebps: Bool) -> Bool {
        if video.kind == .webp, !includeWebps { return false }
        guard let file = video.fileURL else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// PhotoKit stores a webp, and a still original, as a picture; everything else as a video.
    static func isStill(_ video: StoredVideo) -> Bool {
        video.kind == .webp || (video.fileURL.map { OfflineStore.looksLikeImage($0.lastPathComponent) } ?? false)
    }

    private func fileIsHere(_ video: StoredVideo) -> Bool {
        guard let file = video.fileURL else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func eligibleVideos() -> [StoredVideo] {
        guard let engine else { return [] }
        let webps = engine.settings.photosSyncWebps
        return engine.store.videos.filter { Self.isEligible($0, includeWebps: webps) }
    }

    /// Eligible and not settled yet, oldest first.
    private func pendingVideos() -> [StoredVideo] {
        guard let engine else { return [] }
        let items = engine.ledger.snapshot().items
        var seen: Set<String> = []
        return eligibleVideos()
            .filter { v in
                let key = PhotosKey.of(v)
                guard seen.insert(key).inserted else { return false }
                guard let e = items[key] else { return true }
                return e.state == .claimed || e.state == .failed
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func recount() {
        guard let engine else { return }
        let items = engine.ledger.snapshot().items
        var added = 0, gaveUp = 0
        for e in items.values where e.origin == .sync {
            if e.state == .done { added += 1 }
            if e.state == .skipped && e.skip == .gaveUp { gaveUp += 1 }
        }
        var waiting = 0
        var seen: Set<String> = []
        for v in eligibleVideos() {
            let key = PhotosKey.of(v)
            guard seen.insert(key).inserted else { continue }
            guard let e = items[key] else { waiting += 1; continue }
            if e.state == .claimed || e.state == .failed { waiting += 1 }
        }
        base.added = added
        base.waiting = waiting
        base.gaveUp = gaveUp
    }

    // MARK: - Previews

    /// No PhotoKit: for `#Preview`s and `AppModel.preview`. `enable()`, `disable()` and the backfill
    /// answer move this fixed status around so a preview is interactive.
    public static func preview(_ status: Status) -> PhotosSync {
        PhotosSync(preview: status)
    }

    /// Replaces a preview instance's status (a preview that wants every state from one model).
    /// No effect on the real one.
    public func setPreviewStatus(_ status: Status) {
        guard previewStatus != nil else { return }
        previewStatus = status
    }
}

/// An async mutual exclusion: the album is looked up and created by one caller at a time.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if locked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                locked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
