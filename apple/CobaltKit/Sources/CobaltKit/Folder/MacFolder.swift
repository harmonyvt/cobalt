import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The Mac's folder, as the screens see it (CONTRACT-OFFLINE.md 13.1, 13.5, 13.6, 13.10): the Finder folder that holds the
/// kept files (`~/Movies/cobalt`, or the folder the owner chose) is the store's visible root, so this is not a copier any
/// more. It reports the root's state, chooses another folder (moving the kept files when the owner says so), and shows
/// files in Finder. `FolderSync` is gone: nothing copies, and what it wrote is adopted by tag (`FolderAdoption`).
///
/// Created with `AppModel`; `MacFolder.preview(_:)` is the disk-free twin for previews. Unavailable (`available == false`)
/// where the store's root is not the Mac folder (iPhone, iPad).
@MainActor @Observable
public final class MacFolder {
    /// `noTrash`: the last delete was refused because the folder's disk has no Trash, so the file stayed.
    public enum Problem: Sendable, Equatable { case unreachable, notAllowed, wrongFolder, diskFull, noTrash }

    public struct Moving: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
    }

    public struct Status: Sendable, Equatable {
        public var available: Bool
        /// the display path (`~/Movies/cobalt`)
        public var path: String
        public var isDefault: Bool
        public var problem: Problem?
        /// what FolderSync wrote is being adopted
        public var adopting: Bool
        /// a move to another folder is under way
        public var moving: Moving?

        public init(
            available: Bool = true, path: String = "~/Movies/cobalt", isDefault: Bool = true, problem: Problem? = nil,
            adopting: Bool = false, moving: Moving? = nil
        ) {
            self.available = available
            self.path = path
            self.isDefault = isDefault
            self.problem = problem
            self.adopting = adopting
            self.moving = moving
        }
    }

    public enum ChooseOutcome: Sendable, Equatable {
        /// the folder is set
        case chosen
        /// kept files are in the current folder and it is reachable: ask "move the N offline files to <path>?", then
        /// `answerMove(_:)`. Nothing has changed yet.
        case askMove(count: Int)
        /// the same folder as before
        case unchanged
        /// a folder in iCloud Drive: refused (evicted placeholders and attribute sync would break identity)
        case refusedICloud
        /// a folder that holds cobalt's own store (or is inside it): refused, or the scan would take the hidden copies for the
        /// folder's files
        case refusedStore
        /// the folder could not be opened or remembered
        case failed
    }

    // MARK: State

    /// A folder picked but not switched to yet (the move question is open).
    private struct Prepared {
        var path: String
        var bookmark: Data?
        var isDefault: Bool
        var identity: FolderIdentity
    }

    @ObservationIgnored private let store: OfflineStore?
    @ObservationIgnored private let ledger: FolderLedger?
    @ObservationIgnored private let provider: MacRootProvider?
    @ObservationIgnored private var pending: Prepared?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    private var movingProgress: Moving?
    var previewStatus: Status?

    public var status: Status {
        if let previewStatus { return previewStatus }
        guard let store, store.rootMode == .macFolder, let root = store.visibleRoot else { return Status(available: false) }
        let problem: Problem?
        switch store.rootState {
        case .ready: problem = store.rootDiskFull ? .diskFull : (store.trashRefused ? .noTrash : nil)
        case .unreachable: problem = .unreachable
        case .notAllowed: problem = .notAllowed
        case .wrongFolder: problem = .wrongFolder
        }
        let defaultFolder = provider?.defaultFolder ?? FolderDestination.defaultURL
        return Status(
            available: true, path: Self.display(root.path),
            isDefault: FolderDestination.canonical(root) == FolderDestination.canonical(defaultFolder), problem: problem,
            adopting: store.isAdopting, moving: movingProgress)
    }

    public var isAvailable: Bool { status.available }

    init(store: OfflineStore, ledger: FolderLedger, provider: MacRootProvider? = nil) {
        self.store = store
        self.ledger = ledger
        self.provider = provider ?? store.rootProvider
    }

    private init(preview: Status) {
        self.store = nil
        self.ledger = nil
        self.provider = nil
        self.previewStatus = preview
    }

    /// The Mac has a Finder folder; the iPhone and iPad do not.
    nonisolated public static var platformHasFolder: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// `~` for the real home folder.
    nonisolated static func display(_ path: String) -> String {
        let home = FolderDestination.realHome().path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        if let sandbox = AppGroup.sandboxRoot?.path, path.hasPrefix(sandbox + "/") { return "~" + path.dropFirst(sandbox.count) }
        return path
    }

    // MARK: - Choosing another folder (13.5)

    /// One folder holds the other, or is the other (symlinks resolved): a root that contains cobalt's hidden store makes the scan
    /// read the store's own files as the folder's (wave M review S4), and one inside it is the store's.
    nonisolated static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let x = FolderDestination.canonical(a) + "/", y = FolderDestination.canonical(b) + "/"
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// The owner picked a folder. Prepares it (bookmark, identity, the iCloud refusal) without switching. When kept files
    /// are in the current folder and it is reachable the answer is `.askMove(count:)`; nothing changes until `answerMove`.
    /// Otherwise the folder is switched to at once.
    public func chooseFolder(_ url: URL) async -> ChooseOutcome {
        if previewStatus != nil {
            previewStatus?.path = Self.display(url.path)
            previewStatus?.isDefault = false
            return .askMove(count: 24)
        }
        guard let store, let ledger, store.rootMode == .macFolder else { return .failed }
        let defaultFolder = provider?.defaultFolder ?? FolderDestination.defaultURL
        let current = store.visibleRoot
        let stores = [store.root, store.syncDirectory].compactMap { $0 }
        enum Prep: Sendable { case unchanged, iCloud, store, failed, ready(path: String, bookmark: Data?, isDefault: Bool, volume: String?, fileID: Int64?) }
        let prep: Prep = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if FolderDestination.isInICloudDrive(url) { return .iCloud }                 // a path check first: nothing is read there
            if stores.contains(where: { Self.overlaps(url, $0) }) { return .store }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .failed }
            let canonical = FolderDestination.canonical(url)
            if let current, canonical == FolderDestination.canonical(current) { return .unchanged }
            guard FileManager.default.isWritableFile(atPath: url.path) else { return .failed }
            if canonical == FolderDestination.canonical(defaultFolder) {
                return .ready(path: defaultFolder.path, bookmark: nil, isDefault: true, volume: nil, fileID: nil)
            }
            guard let bookmark = try? FolderDestination.makeBookmark(for: url) else { return .failed }
            let identity = FolderDestination.identity(of: url)
            return .ready(path: url.standardizedFileURL.path, bookmark: bookmark, isDefault: false, volume: identity.volume, fileID: identity.fileID)
        }.value
        switch prep {
        case .unchanged: return .unchanged
        case .iCloud: return .refusedICloud
        case .store: return .refusedStore
        case .failed: return .failed
        case .ready(let path, let bookmark, let isDefault, let volume, let fileID):
            return await begin(Prepared(path: path, bookmark: bookmark, isDefault: isDefault, identity: FolderIdentity(volume: volume, fileID: fileID)), ledger: ledger, store: store)
        }
    }

    /// Back to `~/Movies/cobalt` ("use ~/Movies/cobalt"): the same flow toward the default folder.
    public func resetToDefault() async -> ChooseOutcome {
        if previewStatus != nil {
            previewStatus?.path = "~/Movies/cobalt"
            previewStatus?.isDefault = true
            return .askMove(count: 24)
        }
        guard let store, let ledger, store.rootMode == .macFolder else { return .failed }
        let defaultFolder = provider?.defaultFolder ?? FolderDestination.defaultURL
        if let current = store.visibleRoot, FolderDestination.canonical(current) == FolderDestination.canonical(defaultFolder) { return .unchanged }
        do { try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true) } catch { return .failed }
        return await begin(Prepared(path: defaultFolder.path, bookmark: nil, isDefault: true, identity: FolderIdentity()), ledger: ledger, store: store)
    }

    private func begin(_ prepared: Prepared, ledger: FolderLedger, store: OfflineStore) async -> ChooseOutcome {
        let count = store.visibleKeptCount
        if count > 0, store.rootState == .ready {
            pending = prepared
            return .askMove(count: count)
        }
        _ = await apply(prepared, move: false)
        return .chosen
    }

    /// The owner's answer to "move the N offline files to <path>?": `true` moves them, `false` leaves them where they are
    /// (they stop being offline here; nothing is downloaded again), `nil` cancels (no change). Returns how many moved and
    /// how many stayed in the old folder.
    @discardableResult
    public func answerMove(_ move: Bool?) async -> (moved: Int, stayed: Int) {
        if previewStatus != nil { return (move == true ? 24 : 0, 0) }
        guard let prepared = pending else { return (0, 0) }
        pending = nil
        guard let move else { return (0, 0) }
        return await apply(prepared, move: move)
    }

    private func apply(_ prepared: Prepared, move: Bool) async -> (moved: Int, stayed: Int) {
        guard let store, let ledger else { return (0, 0) }
        // The folder being left, read before the new one is named: from then on anything that resolves the root (a landing's
        // promotion, the watcher) would swap it to the new folder (review S3).
        let leaving = store.rootBox.current
        let provider = provider ?? MacRootProvider(ledger: ledger)
        movingProgress = move ? Moving(done: 0, total: store.visibleKeptCount) : nil
        // The ledger names the new folder first, inside the store's gate and before the first file moves: a crash mid-move then
        // reopens on the new folder, where what moved is found by its tag, and what did not stays in the old one, the owner's,
        // still tagged; and nothing can read the new folder before the files have left the old one.
        let result = await store.switchRoot(move: move, from: leaving, progress: { @Sendable [weak self] done, total in
            Task { @MainActor in self?.movingProgress = Moving(done: done, total: total) }
        }, resolve: { @Sendable in
            ledger.choose(
                path: prepared.path, bookmark: prepared.bookmark, isDefault: prepared.isDefault,
                volume: prepared.identity.volume, fileID: prepared.identity.fileID)
            return provider.resolve()
        })
        movingProgress = nil
        await store.reload()                                  // adopts the new folder's section, scans it, moves in what waited
        return (result.moved, result.stayed)
    }

    // MARK: - Finder

    /// "show in finder": these videos' files selected in Finder (a gallery's folder for its items); the folder itself when none
    /// of them is there, or none is given. Nothing while the folder is not connected.
    public func reveal(_ videos: [StoredVideo] = []) async {
        #if os(macOS)
        guard previewStatus == nil, let store, let root = store.visibleRoot, store.rootState == .ready else { return }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let targets: [URL] = await Task.detached(priority: .userInitiated) {
            var seen: Set<String> = []
            var out: [URL] = []
            for video in videos {
                guard let file = video.fileURL, video.place == .offline, FileManager.default.fileExists(atPath: file.path) else { continue }
                var target = file
                let relative = file.resolvingSymlinksInPath().path.dropFirst(prefix.count)
                if relative.contains("/") { target = file.deletingLastPathComponent() }      // a gallery's item: its folder
                if seen.insert(target.path).inserted { out.append(target) }
            }
            return out
        }.value
        if targets.isEmpty {
            NSWorkspace.shared.open(root)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
        #endif
    }

    /// The folder a kept file is in, for the detail line: `~/Movies/cobalt/instagram · DeKlsGCGZmx`.
    public func displayFolder(of video: StoredVideo) -> String? {
        if previewStatus != nil { return previewStatus?.path }
        guard video.place == .offline, let file = video.fileURL else { return nil }
        return Self.display(file.deletingLastPathComponent().path)
    }

    // MARK: - Activation

    #if os(macOS)
    /// Looks at the root again when the app comes to the front. A root that was not usable is the case this is for (a disk
    /// that came back, a folder the owner re-made): the store's `reload()` then resolves it, adopts, scans and moves in what
    /// waited. Every other foreground is `AppModel.pickUpSharedJobs`' (scene phase). The notification closure is called by
    /// the system on a thread of its choosing: `@Sendable`, and it hops to the main actor explicitly.
    public func observeActivation() {
        guard activationObserver == nil, let store else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { @Sendable [weak store] _ in
            Task { @MainActor [weak store] in
                guard let store else { return }
                let before = store.rootState
                let after = await store.resolveRoot()
                if before != .ready || after != .ready || store.rootDiskFull { await store.reload() }
            }
        }
    }
    #endif

    // MARK: - Previews

    /// No disk: for `#Preview`s and `AppModel.preview`. The owner's actions move this fixed status around.
    public static func preview(_ status: Status) -> MacFolder { MacFolder(preview: status) }

    /// Replaces a preview instance's status. No effect on the real one.
    public func setPreviewStatus(_ status: Status) {
        guard previewStatus != nil else { return }
        previewStatus = status
    }
}
