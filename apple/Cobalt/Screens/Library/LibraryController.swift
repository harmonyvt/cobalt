import CobaltKit
import SwiftUI
#if os(iOS)
import GameController
#endif

/// What a tap opened on the phone: the media as it was then (the detail keeps itself current) and the tab
/// to start on.
struct OpenedMedia: Identifiable, Hashable {
    let item: MediaItem
    let initial: Rendition.ID?

    var id: String { "\(item.id)|\(initial ?? "")" }
    static func == (a: OpenedMedia, b: OpenedMedia) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// "open in library" asked for this post to be shown (the token makes the same post a new request).
struct LibraryReveal: Equatable {
    let id: String
    let token = UUID()
}

/// Where a share of ticked posts stands once the copying pass is over and some posts did not come ("3 of 4 ready · 1
/// failed"). The share sheet waits for the owner's choice: share what is ready, or try the failed ones again.
struct SharePrepSummary: Equatable {
    var ready: Int
    var total: Int
    var failed: Int

    var text: String { Copy.Save.sharePrepSummary(ready: ready, of: total, failed: failed) }
}

extension LibraryRow {
    /// Whether select mode can tick it. Galleries are not shared, so they cannot be ticked, except in the hidden album
    /// (a hidden post is a post whatever it holds, and the album offers `unhide` and `status…`, never a share).
    var shareable: Bool { kind != .gallery || item.post?.hidden == true }
}

/// One row of the card shown while ticked posts are being copied for the share sheet.
struct SharePrepRow: Identifiable, Equatable {
    enum State: Equatable {
        /// Already a file on this device: nothing to download.
        case onDevice
        case waiting, downloading, ready, skipped

        var done: Bool { self == .onDevice || self == .ready || self == .skipped }
    }

    /// What the shared file is. Galleries are never shared, so never a row here.
    enum Kind: Equatable {
        case video, photo, webp
    }

    let id: String
    var title: String
    /// For the card's thumbnail.
    var item: MediaItem
    var kind: Kind
    /// The video's length, when the file is a video.
    var length: Double?
    var state: State
    /// Why this post could not be copied (an `error.*` code), set together with `state == .skipped`: a download that failed,
    /// or a post with no file to fetch. Nil for every row that is or is going to be ready.
    var failure: String?
    /// The bytes of the download in flight, when it reports them.
    var progress: TransferProgress?

    init(_ row: LibraryRow, state: State) {
        id = row.id
        title = row.title
        item = row.item
        self.state = state
        if row.item.face.isWebp {
            kind = .webp
        } else if row.originalIsImage || row.kind == .photo {
            kind = .photo
        } else {
            kind = .video
        }
        length = kind == .video && row.length > 0 ? row.length : nil
    }
}

/// The library screen's state and what its menus do: what is opened (in the screen pane everywhere: beside the tab, or the
/// sheet on a one-screen layout), what is lit, select mode for the posts on screen, the rename and delete in progress, and each
/// action of the context menu. One per screen; the views read the parts they draw, so a lit tile never re-evaluates
/// the table.
@MainActor @Observable
final class LibraryController {
    let model: AppModel

    // MARK: the stuck zoom back (owner, 2026-11-14)

    /// Bumped to rebuild the phone's navigation stack from scratch.
    private(set) var stackID = 0
    #if os(iOS)
    /// A plain view inside the library's own content: in a window whenever the grid really is on screen.
    @ObservationIgnored weak var anchor: UIView?
    #endif
    @ObservationIgnored private var stackCheck: Task<Void, Never>?

    /// iOS 26's zoom back from a playing video, after an edge swipe, can finish with the library's view left out of the
    /// navigation controller: SwiftUI reports the pop done (the grid "appears", `opened` is nil) while the screen keeps
    /// the transition's last picture and the detail's bar, and no tap reaches the grid (8.13 tap probe: taps land on an
    /// empty `UIViewControllerWrapperView`). A moment after the grid should be back, if its anchor has no window while
    /// the library tab is showing, the stack is rebuilt.
    func checkStackSoon() {
        #if os(iOS)
        // the second net: a tap on an empty wrapper. Set here, by the controller the screen really keeps (the screen's
        // init makes throwaway ones)
        TouchProbe.emptyWrapperTapped = { [weak self] in self?.emptyWrapperTapped() }
        stackCheck?.cancel()
        stackCheck = Task { [weak self] in
            // twice, at 0.9 s and 2.5 s: a long frame during the zoom back (8.15 saw 970 ms) can push the first look to
            // before the transition has really ended
            for wait in [900, 1600] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled, let self else { return }
                guard self.model.selectedTab == .library, let anchor = self.anchor else { return }
                if !Self.gridReachable(anchor) {
                    self.unstick("check")
                    return
                }
            }
        }
        #endif
    }

    #if os(iOS)
    /// Whether a tap in the middle of the grid would reach it. 8.15 showed the stuck state with the anchor still in a
    /// window (so `window == nil` alone missed it): taps went to an empty `UIViewControllerWrapperView` instead. So: the
    /// anchor must sit inside a view controller's wrapper, and a hit test at its centre must land inside that same
    /// view controller's view.
    static func gridReachable(_ anchor: UIView) -> Bool {
        guard let window = anchor.window else { return false }
        // a sheet or alert over the library takes the centre's taps on purpose: never rebuild under one
        if window.rootViewController?.presentedViewController != nil { return true }
        var root: UIView? = anchor
        while let view = root, let parent = view.superview, !Self.isWrapper(parent) { root = parent }
        guard let root, root.superview.map(Self.isWrapper) == true else { return false }
        let centre = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: window)
        guard let hit = window.hitTest(centre, with: nil) else { return false }
        return hit.isDescendant(of: root)
    }

    private static func isWrapper(_ view: UIView) -> Bool {
        String(describing: type(of: view)) == "UIViewControllerWrapperView"
    }

    /// A tap landed on an empty view controller wrapper (`TouchProbe`): on the library, with no detail open, that is
    /// the stuck zoom back. One dead tap, then the grid is back.
    func emptyWrapperTapped() {
        guard model.selectedTab == .library else { return }
        if let anchor, Self.gridReachable(anchor) { return }
        unstick("tap")
    }

    private func unstick(_ how: String) {
        Breadcrumbs.add("library.unstuck", ["how": .string(how)])
        stackID += 1
    }
    #endif

    /// The post the pane shows: set by a tap or a click, mirrored from the pane (`LibraryPaneBridge` opens `.post(selection)`
    /// when it is set and clears it when the pane shows something else or is hidden), and what the mosaic lights (beside
    /// the tab only: the sheet covers it).
    var selection: String?
    /// `selection` was set by the screen itself (a search's best match), not by the owner: the pane opens it only when
    /// nothing is in the way (`Pane.openIfIdle`).
    @ObservationIgnored var selectionIsAutomatic = false
    /// The `showingHidden` this controller last acted on (nil before the screen first showed it): what `albumSeen`
    /// compares with, so a view built again does not start the album over.
    @ObservationIgnored var albumShown: Bool?
    /// The post "open in library" lit, for 1.6 s.
    var lit: String?
    var reveal: LibraryReveal?
    /// Select mode (the `select` pill): taps tick posts instead of opening them.
    var selecting = false
    /// Ticked posts (`LibraryRow.id`). Kept across a re-enter; `endSelecting` clears it.
    private(set) var picked: Set<String> = []
    /// The same posts in the order they were ticked: the pill's row of thumbnails and the link's order.
    private(set) var pickOrder: [String] = []
    /// Where a shift-click range starts: the post last ticked by a plain click or a ⌘-click (Finder's anchor).
    @ObservationIgnored private var pickAnchor: String?
    /// The posts on screen in their order (the screen keeps it current): what a shift-click range runs through.
    /// Observed on purpose: the select actions page (`PaneSelectionPage`) draws from it, and must follow the screen's rows.
    var shownRows: [LibraryRow] = []
    /// The share chips: every post, not shared, shared, or one collection's.
    var shareFilter: LibraryShareFilter = .all
    /// The post a hold is showing full size (media only), while the finger stays down.
    var peek: LibraryRow?
    /// A hold just showed a peek: the tap the same touch ends with must not tick or untick.
    @ObservationIgnored var peekSwallowsTap = false
    /// A share of the ticked posts is copying files. A second tap while this is set does nothing.
    var preparingShare = false
    /// Files ready for the system share sheet; the library screen presents them and the sheet clears this when it ends.
    /// Here, not on the screen, so the select actions (in the pill or in the pane's page) can ask for it and then leave
    /// select mode, which takes that page away.
    var filesToShare: [URL] = []
    /// A share link is being made (`make share link`). A second tap while this is set does nothing.
    var makingShareLink = false
    /// Bumped when a share link was made and copied: the success haptic.
    var shareLinksMade = 0
    /// The select panel's `public` / `private` choice for the next gallery link (APP-API-CONTRACT 36.6); nil follows
    /// settings › sharing (`new_links`).
    var shareLinkPrivate: Bool?
    /// Bumped when a copy, a save, a visibility switch or a delete lands (success haptic), half lands (warning) or
    /// fails (error).
    var doneTick = 0
    var warnTick = 0
    var failTick = 0
    /// What the share card lists while `preparingShare` is set. Cleared when the copy finishes.
    var sharePrep: [SharePrepRow] = []
    /// The card's `cancel`: the copy stops before the next post and no sheet opens.
    var shareCancelled = false
    /// Set while the pass is over and some posts failed: the card says so and waits for `shareReadyOnes()` or `retryFailedShares()`
    /// (or `cancel`), so the share sheet never opens on a quiet partial result.
    var sharePrepSummary: SharePrepSummary?
    @ObservationIgnored private var shareDecision: ShareDecision?
    private enum ShareDecision { case shareReady, retry }
    /// Bumped by a refresh: a tile whose picture failed tries again.
    var reload = 0
    var renaming: MediaItem?
    var deleting: MediaItem?
    /// The media whose video the owner is turning private (the confirm: its link stops working for everyone).
    var makingPrivate: MediaItem?
    /// The gallery the owner chose `make from this post…` for: the combine sheet is open on it (`LibraryCombineSheet`).
    var combining: MediaItem?
    /// The picture the owner chose `crop a copy…` for: the crop sheet is open on it (`LibraryImageCropHook.swift`).
    var croppingPicture: LibraryImageCropTarget?
    /// The post the owner chose `make an emote…` for: the emote editor is open on it (`EmoteEditor/EmoteEditorEntry.swift`).
    var makingEmote: EmoteEditorTarget?
    /// The sky map (`SkyMap/LibrarySkyMapHook.swift`) is open.
    var showingSkyMap = false
    /// The posts `add to link` is picking a link for (`LibraryAddToLinkHook.swift`): the link picker is up.
    var addingToLink: LibraryLinkPicks?
    /// An append to a link is on its way: a second one waits.
    var appendingToLink = false

    // The hidden album (APP-API-CONTRACT 37.7; `LibraryController+Hidden.swift`). All in memory: nothing here is stored.
    /// The owner passed the lock for this visit to the album. Dropped by `relockHidden()`.
    var hiddenUnlocked = false
    /// The system sheet (Face ID, Touch ID, passcode) is up.
    var unlocking = false
    /// The last try failed (not cancelled): the locked card says so.
    var lockFailed = false
    /// What the system will ask, for the locked card's button.
    var lockMethod: Copy.HiddenAlbum.LockMethod = .passcode
    /// The album was opened and its first page has not come back yet: a spinner, not `nothing hidden`.
    var albumPending = false
    /// A `status…` choice waiting on its confirm (hide, make public).
    var asking: StatusAsk?
    /// A `status…` change is on its way (the pill's buttons wait).
    var changingStatus = false
    /// Bumped whenever the lock is dropped: a sheet that answers after that is ignored.
    @ObservationIgnored var lockEpoch = 0
    /// The system sheet was already asked for in this lock, so a return from the sheet does not ask again.
    @ObservationIgnored var lockPrompted = false

    /// True while the window has no room for the pane beside the tab (one narrow screen: the pane is a sheet over the
    /// grid, which keeps the select pill and the overlay peek); false where the pane sits beside it. Set from the pane's
    /// placement. Observed: the tiles' hold (preview and release opens the pane) follows it.
    var compact = true

    /// A hold on a tile is hold-to-preview, release-opens-the-pane, and the tile has no context menu (the iPhone and a
    /// narrow iPad window, where the pane is a sheet over the grid). The Mac and the wide placements keep the context menu
    /// and the plain peek.
    var holdOpens: Bool {
        #if os(iOS)
        compact
        #else
        false
        #endif
    }
    /// The shell's status line (`ShellActions.showStatus`), set by the screen.
    @ObservationIgnored var showStatus: @MainActor (String) -> Void = { _ in }

    init(model: AppModel) {
        self.model = model
    }

    var library: LibraryModel { model.library }

    // MARK: opening

    /// A tap: the post opens in the pane.
    func open(_ row: LibraryRow) {
        open(row.item, initial: row.item.face.id)
    }

    /// Opens `item` in the pane (the bridge does it: beside the tab, or as the sheet on one narrow screen).
    func open(_ item: MediaItem, initial: Rendition.ID?) {
        selectionIsAutomatic = false
        // the same post again (the pane was closed since): the library's watcher sees a change from nil
        selection = item.post?.id ?? item.id
    }

    /// The screen opens a post by itself (a search's best match): the pane takes it only when nothing is in the way, and
    /// never over a running stream or a post the owner opened.
    func openAutomatically(_ item: MediaItem) {
        let id = item.post?.id ?? item.id
        // the same post is already selected: nothing would read the flag
        guard selection != id else { return }
        selectionIsAutomatic = true
        selection = id
    }

    /// The media the pane shows: the loaded post whatever the filter says (else the post a search returned).
    /// A hidden post resolves only in the open (unlocked) album; everywhere else it is nil (APP-API-CONTRACT 37.7).
    var selectedItem: MediaItem? {
        guard let id = selection else { return nil }
        guard let post = (albumOpen ? library.hiddenPost(id: id) : nil) ?? library.post(id: id) else { return nil }
        return model.mediaItem(for: post)
    }

    func light(_ id: String) {
        lit = id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lit == id { lit = nil }
        }
    }

    // MARK: select mode

    /// Starts select mode. Does not clear `picked`: ending is what empties it, so a fresh enter starts empty
    /// and a second call while already selecting keeps the ticks.
    func beginSelecting() {
        selecting = true
    }

    func endSelecting() {
        selecting = false
        pickAnchor = nil
        setPicks([])
        peek = nil
    }

    private func setPicks(_ ids: [String]) {
        pickOrder = ids
        picked = Set(ids)
    }

    /// Ticks or unticks one post. A gallery cannot be ticked: galleries are not shared.
    func togglePick(_ row: LibraryRow) {
        guard row.shareable else { return }
        pickAnchor = row.id
        if picked.contains(row.id) { unpick(row.id) } else { setPicks(pickOrder + [row.id]) }
    }

    /// What a click on a post does, by the keys held (Finder's rules): shift ticks the run from the last tick to
    /// here, ⌘ ticks or unticks this one; either starts select mode. Plain: tick while selecting, else open.
    enum Click {
        case plain, toggle, range

        /// The keys held right now: `NSEvent` on the Mac, the hardware keyboard (`GCKeyboard`) on the iPad.
        @MainActor static func current(_ controller: LibraryController) -> Click {
            #if os(macOS)
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) { return .range }
            if flags.contains(.command) { return .toggle }
            #else
            guard let keys = GCKeyboard.coalesced?.keyboardInput else { return .plain }
            func held(_ a: GCKeyCode, _ b: GCKeyCode) -> Bool {
                keys.button(forKeyCode: a)?.isPressed == true || keys.button(forKeyCode: b)?.isPressed == true
            }
            if held(.leftShift, .rightShift) { return .range }
            if held(.leftGUI, .rightGUI) { return .toggle }
            #endif
            return .plain
        }
    }

    /// A click or tap on a tile or a row: ticks (starting select mode for shift and ⌘) or opens.
    func click(_ row: LibraryRow, _ click: Click) {
        switch click {
        case .plain:
            if selecting { togglePick(row) } else { open(row) }
        case .toggle, .range:
            // a gallery cannot be ticked: a modified click opens it, as a plain one would, unless selecting
            guard row.shareable else {
                if !selecting { open(row) }
                return
            }
            selecting = true
            if click == .range { pickRange(to: row) } else { togglePick(row) }
        }
    }

    /// Ticks every post on screen from the anchor (else the last tick on screen) through `row`, keeping the ticks
    /// already there. With neither on screen it ticks `row` alone, which becomes the anchor.
    private func pickRange(to row: LibraryRow) {
        let ids = shownRows.map(\.id)
        let from = pickAnchor.flatMap { ids.contains($0) ? $0 : nil } ?? pickOrder.last(where: ids.contains)
        guard let from, let start = ids.firstIndex(of: from), let end = ids.firstIndex(of: row.id) else {
            if !picked.contains(row.id) { togglePick(row) } else { pickAnchor = row.id }
            return
        }
        let run = start <= end ? shownRows[start...end] : shownRows[end...start]
        // in click order: from the anchor towards the post clicked
        let ordered = start <= end ? Array(run) : Array(run.reversed())
        let added = ordered.filter { $0.shareable && !picked.contains($0.id) }.map(\.id)
        if pickAnchor == nil { pickAnchor = from }
        setPicks(pickOrder + added)
    }

    /// Unticks one post (the pill's thumbnail).
    func unpick(_ id: String) {
        setPicks(pickOrder.filter { $0 != id })
    }

    /// Ticks every post on screen that can be shared (the kind chip, the search and the show filter decide which), or
    /// clears them all when every one is already ticked.
    func toggleAll(_ rows: [LibraryRow]) {
        let ids = rows.filter(\.shareable).map(\.id)
        if Set(ids).isSubset(of: picked) {
            let gone = Set(ids)
            setPicks(pickOrder.filter { !gone.contains($0) })
        } else {
            setPicks(pickOrder + ids.filter { !picked.contains($0) })
        }
    }

    /// Select mode with exactly these posts ticked: a kind chip's `select all` / `share all`.
    func pickOnly(_ rows: [LibraryRow]) {
        selecting = true
        setPicks(rows.filter(\.shareable).map(\.id))
    }

    /// The ticked posts that are on screen, in the order they were ticked (the pill's thumbnails).
    func pickedRows(_ rows: [LibraryRow]) -> [LibraryRow] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return pickOrder.compactMap { byID[$0] }.filter(\.shareable)
    }

    /// A hold on a tile or a thumbnail: shows (`row`) or hides (nil) the media-only peek.
    func setPeek(_ row: LibraryRow?) {
        if row != nil { peekSwallowsTap = true }
        peek = row
        if row == nil {
            // the touch that ends the hold may or may not also end as a tap: forget the swallow shortly after
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if peek == nil { peekSwallowsTap = false }
            }
        }
    }

    /// The tap that ends a hold: true once, then taps count again.
    func takeSwallowedTap() -> Bool {
        guard peekSwallowsTap else { return false }
        peekSwallowsTap = false
        return true
    }

    /// Local files for the ticked posts, in `rows` order. One file per picked row: that row's face only
    /// (never a gallery, not `post.link`, never `publicURL`). One download at a time.
    /// The URL `localCopy` returns is kept — deleting it can destroy the only copy.
    ///
    /// A post that cannot be copied is never dropped quietly (apple 02-PHASE2 2.2.4): its row says why (`failure`), and when
    /// the pass ends with some failed the card says "3 of 4 ready · 1 failed" and waits: `shareReadyOnes()` shares what came,
    /// `retryFailedShares()` tries the failed ones again, `cancel` shares nothing. Empty means nothing is shared
    /// (`Copy.actionFailed` is already shown, or the owner cancelled). `[]` while a share is already being prepared: the
    /// caller does nothing.
    func sharePicked(_ rows: [LibraryRow]) async -> [URL] {
        guard !preparingShare else { return [] }
        preparingShare = true
        let chosen = picked
        let rows = rows.filter(\.shareable)
        shareCancelled = false
        shareDecision = nil
        sharePrepSummary = nil
        let order = rows.filter { chosen.contains($0.id) }
        sharePrep = order.map { SharePrepRow($0, state: Self.shareState(of: $0.item.face)) }
        defer {
            preparingShare = false
            model.offlineDownloads.dismissFailedTransfers()
            sharePrep = []
            sharePrepSummary = nil
            shareDecision = nil
        }
        var copied: [String: URL] = [:]
        var pass = order
        while true {
            for row in pass {
                // `cancel` on the card: nothing is shared (what already downloaded stays as the cache's)
                if shareCancelled { return [] }
                if let url = await copyForShare(row) { copied[row.id] = url }
            }
            if shareCancelled { return [] }
            let ready = order.compactMap { copied[$0.id] }
            let failed = sharePrep.filter { $0.failure != nil }
            if failed.isEmpty {
                if ready.isEmpty { showStatus(Copy.actionFailed); failTick += 1 }
                return ready
            }
            // some did not come: say so, and let the owner choose before the sheet opens
            sharePrepSummary = SharePrepSummary(ready: ready.count, total: order.count, failed: failed.count)
            warnTick += 1
            let decision = await awaitShareDecision()
            sharePrepSummary = nil
            shareDecision = nil
            guard let decision, !shareCancelled else { return [] }
            switch decision {
            case .shareReady:
                return ready
            case .retry:
                let again = Set(failed.map(\.id))
                for id in again { resetShareRow(id) }
                pass = order.filter { again.contains($0.id) }
            }
        }
    }

    /// `share the ones that are ready` on the summary: the sheet opens on what came.
    func shareReadyOnes() { if sharePrepSummary != nil { shareDecision = .shareReady } }
    /// `retry` on the summary: the failed posts are copied again, then the summary says how it went.
    func retryFailedShares() { if sharePrepSummary != nil { shareDecision = .retry } }

    private func awaitShareDecision() async -> ShareDecision? {
        while shareDecision == nil, !shareCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
        return shareDecision
    }

    /// One post's file for the share sheet: the one on this device, else a download. Nil when it could not come, with the
    /// row saying why.
    private func copyForShare(_ row: LibraryRow) async -> URL? {
        let face = row.item.face
        if let url = face.local?.fileURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            setShareState(row.id, .onDevice)
            return url
        }
        setShareState(row.id, .downloading)
        guard let file = face.file else {
            failShareRow(row.id, code: "error.app.no_file")
            return nil
        }
        do {
            // the copy is a row of the downloads engine while it runs (`activity` lists it), landing nowhere: the share sheet takes the file
            let library = model.library
            let copied = try await model.offlineDownloads.transfer(
                key: OfflineDownloads.shareKey(row.id), name: row.title, expectedBytes: file.bytes
            ) { progress in try await library.localCopy(file, progress: progress) }
            guard copied.isFileURL else {
                failShareRow(row.id, code: "error.app.no_file")
                return nil
            }
            setShareState(row.id, .ready)
            return copied
        } catch {
            let code = Self.shareFailureCode(error)
            Telemetry.log(.warn, .store, "share copy failed", data: Telemetry.errorData(error).merging(["copy": .string(code)]) { a, _ in a })
            failShareRow(row.id, code: code)
            return nil
        }
    }

    private static func shareFailureCode(_ error: Error) -> String {
        if let failure = error as? PipelineFailure { return failure.code }
        if error is CancellationError { return "error.app.cancelled" }
        return Pipeline.localCopyCode(error)
    }

    /// `share` of the select actions: copies each ticked face on screen, hands the files to the share sheet and leaves
    /// select mode (as saving a gallery's photos does). A second call while that runs does nothing.
    func shareAndEnd(_ rows: [LibraryRow]) async {
        let urls = await sharePicked(rows)
        guard !urls.isEmpty else { return }
        filesToShare = urls
        withAnimation(Motion.rows) { endSelecting() }
    }

    /// `make link` / `collection` of the select actions: makes the link, copies it, files it when `target` says so, and
    /// leaves select mode once it was made.
    func makeLinkAndEnd(_ rows: [LibraryRow], into target: CollectionTarget? = nil) async {
        let made = if let target { await makeShareLink(rows, into: target) } else { await makeShareLink(rows) }
        if made { withAnimation(Motion.rows) { endSelecting() } }
    }

    // MARK: gallery share link (APP-API-CONTRACT 24)

    /// The picked posts that are on screen (`rows` order) with the library file that stands for each: the public one,
    /// or for a private link any file the post has (APP-API-CONTRACT 36.3); nil when there is none. What the select
    /// bar's verdict and the button both read, so they cannot disagree.
    func shareLinkPicks(_ rows: [LibraryRow]) -> [(row: LibraryRow, fileID: String?)] {
        let isPrivate = makesPrivateLink
        return pickedRows(rows).map { ($0, isPrivate ? ShareSetRule.privateFileID(for: $0.item) : ShareSetRule.fileID(for: $0.item)) }
    }

    /// The next gallery link is private: the panel's choice, else what new links start as. Only while the server has
    /// private links. A private link may hold files that are not public (APP-API-CONTRACT 36.3).
    var makesPrivateLink: Bool {
        model.capabilities.privateLinks && (shareLinkPrivate ?? (model.shareSets.newLinks == .private))
    }

    func shareLinkVerdict(_ rows: [LibraryRow]) -> ShareSetVerdict {
        ShareSetRule.verdict(
            publicFlags: shareLinkPicks(rows).map { $0.fileID != nil }, max: model.capabilities.limits.shareSetMax)
    }

    /// Makes one link for the picked posts and copies it. True when it was made (the caller leaves select mode).
    /// A second call while one runs does nothing. `.notPublic` says so; any other failure is the generic one.
    func makeShareLink(_ rows: [LibraryRow]) async -> Bool {
        await makeLink(rows, filing: nil)
    }

    /// The pill's `collection`: makes one link for the picks, copies it, and files it in the collection (an existing
    /// one by id, or a new one by name). True when the link was made, even if filing it failed (that is said).
    func makeShareLink(_ rows: [LibraryRow], into target: CollectionTarget) async -> Bool {
        await makeLink(rows, filing: target)
    }

    enum CollectionTarget: Equatable {
        case existing(id: String, name: String)
        case new(name: String)
    }

    private func makeLink(_ rows: [LibraryRow], filing target: CollectionTarget?) async -> Bool {
        guard !makingShareLink, shareLinkVerdict(rows) == .ready else { return false }
        let ids = shareLinkPicks(rows).compactMap(\.fileID)
        let isPrivate = makesPrivateLink
        makingShareLink = true
        defer { makingShareLink = false }
        do {
            // with private links the choice is always sent, so the link is what the panel showed
            let set = try await model.shareSets.create(
                items: ids, title: nil, private: model.capabilities.privateLinks ? isPrivate : nil)
            Pasteboard.copy(set.url.absoluteString)
            if let target {
                do {
                    let name: String
                    switch target {
                    case .existing(let id, let n):
                        _ = try await model.shareSets.addLink(set.id, to: id)
                        name = n
                    case .new(let n):
                        name = try await model.shareSets.createCollection(name: n, setIDs: [set.id]).name
                    }
                    showStatus(Copy.Library2.filedIn(name))
                } catch {
                    // the link exists and is copied; only the filing failed
                    showStatus(Copy.Collections.message(for: error))
                    warnTick += 1
                    return true
                }
            } else {
                showStatus(set.isPrivate ? Copy.PrivateLinks.copiedPrivate : Copy.Media.copied)
            }
            shareLinksMade += 1
            return true
        } catch let ShareSetError.notPublic(refused) {
            showStatus(isPrivate ? Copy.PrivateLinks.notOnServer(max(1, refused.count)) : Copy.Links.makeThesePublic)
            warnTick += 1
        } catch {
            showStatus(Copy.actionFailed)
            failTick += 1
        }
        return false
    }

    private func setShareState(_ id: String, _ state: SharePrepRow.State) {
        guard let index = sharePrep.firstIndex(where: { $0.id == id }) else { return }
        sharePrep[index].state = state
        sharePrep[index].progress = nil
    }

    /// The row did not come: it stays `.skipped` (the card's red mark) and keeps the code, which the card's line and the
    /// summary read.
    private func failShareRow(_ id: String, code: String) {
        guard let index = sharePrep.firstIndex(where: { $0.id == id }) else { return }
        sharePrep[index].state = .skipped
        sharePrep[index].failure = code
        sharePrep[index].progress = nil
    }

    /// A retry: the row waits again, with nothing left of its failure.
    private func resetShareRow(_ id: String) {
        guard let index = sharePrep.firstIndex(where: { $0.id == id }) else { return }
        sharePrep[index].state = .waiting
        sharePrep[index].failure = nil
        sharePrep[index].progress = nil
    }

    private static func shareState(of face: Rendition) -> SharePrepRow.State {
        if let url = face.local?.fileURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return .onDevice
        }
        return .waiting
    }

    // MARK: the menu's questions

    /// The newest webp's live link: its private link (APP-API-CONTRACT 36.6), else its public one.
    func webpLink(_ item: MediaItem) -> URL? {
        item.webps.last(where: { $0.privateURL != nil || $0.publicURL != nil }).flatMap { $0.privateURL ?? $0.publicURL }
    }

    /// The video's live link: its private link, else the hosted video's.
    func videoLink(_ item: MediaItem) -> URL? { item.video?.privateURL ?? item.video?.hosted?.url ?? item.video?.publicURL }

    /// What the face can be shared as (`share`: the file, its share link, its direct link); nil when none.
    func shareTargets(_ item: MediaItem) -> ShareTargets? {
        let face = item.face
        let targets = model.capabilities.shareTargets(for: face, file: face.isOnDevice || face.file != nil)
        return targets.forms.isEmpty ? nil : targets
    }

    /// `share` → `file`: the face's file, fetched onto this device first when it is not here, in the system sheet.
    /// A second call while one is fetching does nothing.
    func shareFile(_ item: MediaItem) async {
        guard !preparingShare else { return }
        let face = item.face
        if face.isOnDevice, let url = face.local?.fileURL {
            filesToShare = [url]
            return
        }
        guard let file = face.file else {
            showStatus(Copy.actionFailed)
            return
        }
        preparingShare = true
        defer { preparingShare = false }
        guard let copied = try? await model.library.localCopy(file), copied.isFileURL else {
            showStatus(Copy.actionFailed)
            failTick += 1
            return
        }
        filesToShare = [copied]
    }

    /// `save to photos` of one file: a video, a webp, or a single photo. A gallery has `save all to photos` instead.
    func canSave(_ item: MediaItem) -> Bool { item.kind != .gallery && RenditionPhotos.canSave(item.face) }

    /// A photo or a gallery: what the media holds is its items, not a video.
    func holdsItems(_ item: MediaItem) -> Bool { item.video == nil && !item.items.isEmpty }

    /// `copy photo link`: a single photo's live link (its private link, else its public one).
    func photoLink(_ item: MediaItem) -> URL? { item.kind == .photo ? (item.face.privateURL ?? item.face.publicURL) : nil }

    /// `copy all links` is offered for a gallery with at least one public link (items, then what was made).
    func canCopyAllLinks(_ item: MediaItem) -> Bool {
        item.kind == .gallery && !model.copyAllLinks(item).isEmpty
    }

    /// `save all to photos` (owner-asked only; the Mac has no Photos sync, its folder is in Finder): a gallery's items.
    func canSaveAll(_ item: MediaItem) -> Bool {
        #if os(iOS)
        item.kind == .gallery && item.items.contains { RenditionPhotos.canSave($0) }
        #else
        false
        #endif
    }

    /// `make from this post…`: a gallery of 2+ items on a server that makes things.
    func canMakeFromPost(_ item: MediaItem) -> Bool {
        item.kind == .gallery && item.itemCount >= 2 && model.capabilities.gallery && model.capabilities.galleryMake
            && !model.isHiddenPost(item)       // nothing is made from a hidden post: it could end up public
    }

    /// "make public" / "make private…": the server takes the switch for this media's video (the same switch the
    /// detail has; a webp's is on its tab there). A photo or gallery has the post's switch (`AppModel.setPublic`).
    func canSwitchVisibility(_ item: MediaItem) -> Bool {
        guard model.capabilities.visibility else { return false }
        if let video = item.video { return video.canToggleVisibility }
        return holdsItems(item) && item.items.contains { $0.canToggleVisibility }
    }

    /// `delete everything` is offered when the media has something on the server and a way to delete it
    /// (the keyed post route, or a webp the older route can take); plain cobalt has neither.
    func canDelete(_ item: MediaItem) -> Bool {
        guard item.hasServerCopy else { return false }
        return usesPostRoute(item) || item.webps.contains { $0.deletableName != nil }
    }

    func usesPostRoute(_ item: MediaItem) -> Bool { model.capabilities.deletePost && item.post != nil }

    func isBusy(_ item: MediaItem) -> Bool { model.isBusy(item) }

    /// The confirm's message (CONTRACT-MEDIA 1.12): what exists, for everyone, or on an older server only the webps.
    func deleteMessage(_ item: MediaItem) -> String {
        if usesPostRoute(item), holdsItems(item) {
            return Copy.Library2.deleteGalleryMessage(items: item.itemCount, made: item.made.count)
        }
        if usesPostRoute(item) {
            let video = item.video
            let hosted = video?.hosted != nil || video?.publicURL != nil
            return Copy.Media.deleteEverythingMessage(video: video != nil, hosted: hosted, webps: item.webpCount)
        }
        return Copy.Media.deleteEverythingFallbackMessage(webps: item.webps.filter { $0.deletableName != nil }.count)
    }

    /// The rename alert's extra line: a fork without `features.titles` keeps the name on this device only.
    func renameIsLocalOnly(_ item: MediaItem) -> Bool {
        model.capabilities.library && !model.capabilities.titles && item.post != nil
    }

    // MARK: actions

    /// Copies a public file's link: its share page by default, or the file itself with `.direct`.
    func copy(_ url: URL, form: LinkForm = .share) {
        Pasteboard.copy(model.capabilities.link(for: url, form).absoluteString)
        showStatus(Copy.Media.copied)
        doneTick += 1
    }

    /// The video's link on or off, said in the shell's status line. Off asks first (`makingPrivate`); the library's
    /// file flips at once and goes back when the server says no (`AppModel.setVisibility`).
    func setVisibility(_ item: MediaItem, public makePublic: Bool) {
        let video = item.video
        guard video != nil || holdsItems(item) else { return }
        Task {
            if makePublic { showStatus(Copy.Library2.makingPublic) }
            do {
                var cacheCleared: Bool?
                if let video {
                    cacheCleared = try await model.setVisibility(video, public: makePublic).cacheCleared
                } else {
                    cacheCleared = try await model.setPublic(makePublic, for: item).cacheCleared
                }
                doneTick += 1
                if makePublic {
                    showStatus(Copy.Library2.nowPublic)
                } else {
                    showStatus(cacheCleared == false ? "\(Copy.Library2.nowPrivate) \(Copy.Media.cacheNote)" : Copy.Library2.nowPrivate)
                }
            } catch {
                showStatus(makePublic ? Copy.Media.makeLinkFailed : Copy.Media.turnOffFailed)
                failTick += 1
            }
        }
    }

    func save(_ item: MediaItem) {
        Task {
            do {
                let face = item.face
                #if os(iOS)
                if face.isItem || face.isMade {
                    try await model.saveToPhotos([face], of: item)      // records the gallery file's ledger key
                } else {
                    try await RenditionPhotos.save(face, model: model)
                }
                #else
                try await RenditionPhotos.save(face, model: model)
                #endif
                #if os(iOS)
                showStatus(Copy.savedPhotos)
                #endif
                doneTick += 1
            } catch {
                showStatus(Self.words(error))
                failTick += 1
            }
        }
    }

    /// `save all to photos`: every item of the gallery, only because the owner asked (iPhone and iPad).
    func saveAll(_ item: MediaItem) {
        #if os(iOS)
        Task {
            do {
                try await model.saveToPhotos(item.items.filter { RenditionPhotos.canSave($0) }, of: item)
                showStatus(Copy.savedPhotos)
                doneTick += 1
            } catch {
                showStatus(Self.words(error))
                failTick += 1
            }
        }
        #endif
    }

    /// `copy all links`: the public links of the items and of what was made, one a line.
    func copyAllLinks(_ item: MediaItem, form: LinkForm = .share) {
        let text = model.copyAllLinks(item, direct: form == .direct)
        guard !text.isEmpty else {
            showStatus(Copy.Library2.noPublicLinks)
            warnTick += 1
            return
        }
        Pasteboard.copy(text)
        showStatus(Copy.Library2.copiedLinks(text.split(separator: "\n").count))
        doneTick += 1
    }

    /// `make from this post…`: the combine sheet on this gallery.
    func makeFromPost(_ item: MediaItem) {
        guard !model.isHiddenPost(item) else { return }
        combining = item
    }

    /// `delete everything` after the confirm, with the outcomes of the detail's (CONTRACT-MEDIA 1.12).
    func deleteEverything(_ item: MediaItem) {
        Task {
            if model.isBusy(item) {
                showStatus(Copy.Media.deleteBusy)
                warnTick += 1
                return
            }
            showStatus(Copy.Media.deleting)
            do {
                switch try await model.deleteEverything(item) {
                case .done:
                    showStatus(Copy.Media.deleted)
                    doneTick += 1
                    if let id = item.post?.id, selection == id { selection = nil }
                case .partial(let remaining):
                    showStatus(Copy.Media.deletePartial(remaining: remaining))
                    warnTick += 1
                case .leftOnServer:
                    showStatus(Copy.Media.stillOnServer)
                    warnTick += 1
                }
            } catch {
                showStatus((error as? PipelineFailure) == .serverBusy ? Copy.Media.deleteBusy : Copy.Media.deleteFailed)
                failTick += 1
            }
        }
    }

    /// The select panel's trash, after its sheet: each pick's plan, one post at a time. A post with work in flight is
    /// skipped and counted as not deleted; select mode ends when everything went.
    func deletePicks(_ plans: [DeletePick]) {
        guard !plans.isEmpty else { return }
        Task {
            showStatus(Copy.Media.deleting)
            var failed = 0
            var partial = 0
            for plan in plans {
                if model.isBusy(plan.item) { failed += 1; continue }
                do {
                    switch try await model.delete(plan) {
                    case .done:
                        if plan.plan == .everything, let id = plan.item.post?.id {
                            picked.remove(id)
                            if selection == id { selection = nil }
                        }
                    case .partial, .leftOnServer:
                        partial += 1
                    }
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                showStatus(Copy.DeletePicks.someFailed(failed))
                failTick += 1
            } else if partial > 0 {
                showStatus(Copy.Media.stillOnServer)
                warnTick += 1
            } else {
                showStatus(Copy.DeletePicks.deleted(plans.count))
                doneTick += 1
                withAnimation(Motion.rows) { endSelecting() }
            }
        }
    }

    /// A button's failure in plain words.
    static func words(_ error: Error) -> String {
        if let failure = error as? PipelineFailure { return Copy.failure(failure) }
        return Copy.actionFailed
    }

    // MARK: loading

    /// The next page near the end of the list (the whole-library modes already load everything).
    func loadMoreIfNeeded() {
        guard !library.needsWholeLibrary else { return }
        loadMoreAgain()
    }

    /// The footer's `try again`, and the next page near the end: the album's pages while it is open.
    func loadMoreAgain() {
        if library.showingHidden {
            Task { await library.loadMoreHidden() }
        } else {
            Task { await library.loadMore() }
        }
    }

    func refresh() async {
        if library.showingHidden {
            if library.needsWholeLibrary { await library.loadAll() } else { await library.loadHidden() }
            reload += 1
            return
        }
        await library.refresh()
        if library.needsWholeLibrary { await library.loadAll() }
        reload += 1
    }

    /// Pull to refresh: the spinner lets go at once and the page loads in place. Holding the gesture open for the
    /// network left the page hanging ~90 pt low under a blank band after a fling to the top (the owner's flicker).
    func pullToRefresh() {
        Task { await refresh() }
    }
}
