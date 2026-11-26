import CobaltKit
import SwiftUI

/// The library tab (CONTRACT-LIBRARY2): the owner's media as a mosaic or a table, one remembered switcher.
///
/// The **mosaic** is a dense masonry of faces at their real aspect (`LibraryMosaic`); the **table** is a real
/// sortable `Table` on the iPad and Mac and a dense two-line list on the iPhone (`LibraryTable`). Search, sort and
/// show live in the toolbar; a search, a filter or a sort other than newest first loads the whole library first
/// (the server pages by date only). Tapping opens the same media as the orbit in the screen pane (`PanePostPage`): beside
/// the tab wherever the window has room, the sheet (the cover, spanned) on one narrow screen. The context menu, rename and
/// `delete everything` are the same in every view.
///
/// iOS: this screen always brings its own navigation stack. Mac: a narrow window gets one; otherwise the window's
/// toolbar is already there.
struct LibraryScreen: View {
    let model: AppModel
    let tier: Tier

    @State private var controller: LibraryController
    #if os(iOS)
    /// The library's own width: beside the pane it is one column, and the shell's tier for it did not always come back
    /// to the window's when the pane closed (a half-width bar, no "…", at full width).
    @State private var ownWidth: CGFloat = 0
    /// What the library's stack shows past the grid: the unified detail a tap pushes on the iPhone.
    @State private var path = NavigationPath()
    #endif

    init(model: AppModel, tier: Tier) {
        self.model = model
        self.tier = tier
        _controller = State(initialValue: LibraryController(model: model))
    }

    #if os(iOS)
    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var measuredTier: Tier? { ownWidth > 0 ? Tier(width: ownWidth) : nil }
    /// The tier the library lays out for. Beside the screen pane (a window with room for it) the library never drops to
    /// the one-screen phone layout: opening, closing or peeking the pane halves the library's width (the Duo spread is
    /// 951 pt, one screen ~475), and dropping to `.compact` there swapped the toolbar (paste and file into "…"), the table
    /// for the list and the tile size on every open, close and both ends of every hold (8.40 replays: "buttons disappear,
    /// flickering"). Read from the pane's host, which the pane does not change, so it is also right on the first frame.
    private var shownTier: Tier {
        let own = measuredTier ?? tier
        guard own == .compact, let pane, pane.placement != .compact, Tier(width: pane.hostSize.width) != .compact
        else { return own }
        return .regular
    }
    #endif

    #if os(iOS)
    /// A tap in compact width pushes the unified detail onto the library's stack (one detail, not the pane's sheet).
    /// Regular width (iPhone Duo inner, iPad, Mac) opens in the split pane.
    private var phonePush: (@MainActor (MediaDetailRoute) -> Void)? {
        guard sizeClass == .compact else { return nil }
        return { route in path.append(route) }
    }
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            // Always its own stack (the shell adds none), so the tier never changes this screen's identity.
            NavigationStack(path: $path) {
                LibraryContent(model: model, tier: shownTier, controller: controller, push: phonePush)
                    .mediaDetailDestination(model: model)
            }
                // rebuilt when the zoom back from a video leaves the grid out of the stack (LibraryController.checkStackSoon)
                .id(controller.stackID)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ownWidth = $0 }
                .onChange(of: shownTier) { old, new in
                    LayoutSwap.report(screen: "library", from: old, to: new, width: ownWidth, pane: pane)
                }
            #else
            if tier == .compact {
                NavigationStack { LibraryContent(model: model, tier: tier, controller: controller, push: nil) }
            } else {
                LibraryContent(model: model, tier: tier, controller: controller, push: nil)
            }
            #endif
        }
        .task {
            #if DEBUG
            if LibraryDebug.state != nil { return }
            #endif
            if model.library.posts.isEmpty { await model.library.refresh() }
        }
        // the links and collections the tiles badge and the shelves list (the links tab refreshes the same store)
        .task {
            if model.capabilities.shareSets { await model.shareSets.refresh() }
        }
    }
}

// MARK: - what the library shows

/// What the content area is: the rows, or the reason there are none.
enum LibraryPhase: Equatable {
    case rows, loading, failed, empty
    case noMatch(String)
    /// A kind chip with nothing behind it (`no galleries kept on this iphone yet.`), with a way back to everything.
    case emptyKind(LibraryKindFilter, kept: Bool)
    /// The hidden album, before the owner passes the lock: the locked card, no rows.
    case locked
    /// The hidden album with nothing in it.
    case emptyHidden
}

private struct LibraryContent: View {
    let model: AppModel
    let tier: Tier
    @Bindable var controller: LibraryController
    /// Pushes a post's detail onto the stack (the iPhone); nil where a post opens in the pane.
    let push: (@MainActor (MediaDetailRoute) -> Void)?

    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The window docks the screen pane beside the tab (macOS column): a hold's peek and auto-open search results
    /// open beside the grid. On iOS single-focus mode, hold-to-peek stays as `LibraryPeekOverlay` and taps open full-canvas.
    private var paneBeside: Bool { pane?.sitsBesideTab ?? false }
    @Environment(\.hapticsEnabled) private var haptics
    /// The app's phase (`AppLifecycle`), not this window's scenePhase: the album relocks when the app goes away.
    @Environment(\.lifecycle) private var lifecycle
    @Namespace private var zoomSpace
    /// The last rows a search showed, kept on screen (dimmed) while the next words are still being searched, so each
    /// keystroke does not flash the tiles away to grey and back.
    @State private var heldRows: [LibraryRow] = []
    /// Memoizes `ShareSetIndex` across body passes so scrolling/selecting never rebuilds the index dictionary.
    @State private var shareIndexCache = ShareSetIndexCache()
    #if DEBUG
    @Environment(\.libraryDebugRows) private var debugRows
    @Environment(\.hiddenPreviewUnlocked) private var previewUnlocked
    #endif

    private var library: LibraryModel { model.library }

    /// The posts on screen: the library's rows (kind, search, show and sort applied), then the share chips' filter.
    private var rows: [LibraryRow] { rows(from: unfilteredRows, index: shareIndex) }

    /// `rows` from rows and an index already in hand (the body builds both once per pass).
    private func rows(from unfiltered: [LibraryRow], index: ShareSetIndex) -> [LibraryRow] {
        let filter = shareFilter
        // the share chips are not in the album: nothing hidden is in a link
        guard filter != .all, !library.showingHidden else { return unfiltered }
        var setCollections: Set<String> = []
        if case .set(let id) = filter { setCollections = Set(model.shareSets.group(id)?.collectionIDs ?? []) }
        return unfiltered.filter { filter.admits($0, index: index, setCollections: setCollections) }
    }

    /// The share chips' filter, back to `all` when its collection is gone.
    private var shareFilter: LibraryShareFilter {
        guard model.capabilities.shareSets else { return .all }
        if case .collection(let id) = controller.shareFilter, model.shareSets.collection(id) == nil { return .all }
        if case .set(let id) = controller.shareFilter, model.shareSets.group(id) == nil { return .all }
        return controller.shareFilter
    }

    /// Before the share chips: what their counts are of.
    private var unfilteredRows: [LibraryRow] {
        #if DEBUG
        if LibraryDebug.state != nil { return [] }
        if !debugRows.isEmpty {
            return LibraryDebug.merged(model.libraryRows, with: debugRows, query: library.query, kind: library.kindFilter, sort: library.sort)
        }
        #endif
        // the album is open in the chip but not unlocked (or the server stopped offering it): no rows at all, whatever the
        // model holds
        if library.showingHidden, !controller.albumOpen { return [] }
        return model.libraryRows
    }

    /// The preview's synthetic rows (none in a release build), counted by the kind chips.
    private var debugExtra: [LibraryRow] {
        #if DEBUG
        return LibraryDebug.state == nil ? debugRows : []
        #else
        return []
        #endif
    }

    /// What the whole-library loader is waiting for (the `.task` below): see there.
    private var wholeLibraryStep: Int {
        let library = model.library
        guard library.needsWholeLibrary else { return 0 }
        if controller.hiddenLocked { return 2 }
        return library.wholeLibraryWaitsForSearch ? 3 : 1
    }

    private func phase(_ rows: [LibraryRow]) -> LibraryPhase {
        #if DEBUG
        if let forced = LibraryDebug.state {
            switch forced {
            case .failed: return .failed
            case .loading: return .loading
            case .empty: return .empty
            }
        }
        #endif
        if controller.hiddenLocked { return .locked }
        if library.showingHidden, model.capabilities.hidden { return albumPhase(rows) }
        if !rows.isEmpty { return .rows }
        if library.failure != nil, library.posts.isEmpty { return .failed }
        let query = library.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // the server searched the whole library and found nothing: say so, while the paging still looks for names
        if !query.isEmpty, case .results = library.searchState, library.activeSearchResults != nil { return .noMatch(query) }
        if library.isLoading || library.loadingAll != nil { return .loading }
        // the server is still looking (or waking up): not "nothing matches" yet
        if !query.isEmpty, library.searchState == .searching || library.searchState == .waking { return .loading }
        if !query.isEmpty { return .noMatch(query) }
        if model.capabilities.gallery, library.kindFilter != .all {
            return .emptyKind(library.kindFilter, kept: library.show == .offline)
        }
        return .empty
    }

    /// The open album's phase: its rows, its first page coming, why it failed, or nothing.
    private func albumPhase(_ rows: [LibraryRow]) -> LibraryPhase {
        if !rows.isEmpty { return .rows }
        if library.hiddenFailure != nil, library.hiddenPosts.isEmpty { return .failed }
        if controller.albumPending || library.hiddenLoading || library.loadingAll != nil { return .loading }
        let query = library.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return .noMatch(query) }
        if model.capabilities.gallery, library.kindFilter != .all {
            return .emptyKind(library.kindFilter, kept: library.show == .offline)
        }
        return .emptyHidden
    }

    private var footer: LibraryFooter {
        if library.showingHidden {
            if library.hiddenFailure != nil, !library.hiddenPosts.isEmpty { return .failed }
            return library.hiddenHasMore ? .loading : .none
        }
        if library.failure != nil, !library.posts.isEmpty { return .failed }
        return library.hasMore ? .loading : .none
    }

    private var searchPrompt: String {
        model.capabilities.search ? Copy.Search.prompt : Copy.Library2.searchPrompt
    }

    /// The iPhone's search is the system's drawer under the navigation bar (like the iPad's narrow window); the Mac and
    /// the wide iPad put it in the toolbar. The field never moves with the scroll (the old iPhone-only fold is gone).
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        tier == .compact ? .navigationBarDrawer(displayMode: .always) : .toolbar
        #else
        .toolbar
        #endif
    }

    // MARK: body

    var body: some View {
        @Bindable var library = model.library
        // `libraryRows` is the snapshot the rows engine built off the main thread: read once here, not once per reader
        let unfiltered = unfilteredRows
        let shareIndex = self.shareIndex
        let rows = self.rows(from: unfiltered, index: shareIndex)
        let phase = phase(rows)
        let holding = holdsRows(phase)
        // Ticks a search, a filter or a delete took off screen are neither counted nor shared.
        let pickedCount = controller.selecting ? controller.pickedRows(rows).count : 0
        let shownRows: [LibraryRow] = holding ? heldRows : rows
        let shownPhase: LibraryPhase = holding ? .rows : phase
        // split in two: one chain this long is past the type checker's time limit on the Mac
        let core = content(rows: shownRows, phase: shownPhase, shareIndex: shareIndex, held: holding)
            .modifier(LibraryHoldRows(rows: rows, showing: phase == .rows, album: library.showingHidden, held: $heldRows))
            .navigationTitle(Copy.library)
            #if os(iOS)
            // An inline title: the large title grew and shrank with the scroll (and with a pull to refresh) while the
            // search drawer and the glass bar re-sampled the tiles under them, which read as a flicker at the top.
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationSubtitle(
                controller.selecting
                    ? Copy.Library2.selected(pickedCount)
                    : library.showingHidden
                        ? (controller.hiddenLocked ? Copy.HiddenAlbum.chipName : Copy.HiddenAlbum.note(library.hiddenCount))
                        : Copy.libraryCounts(posts: library.postCount, files: library.fileCount))
            .searchable(text: $library.query, placement: searchPlacement, prompt: searchPrompt)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if controller.selecting {
                        LibrarySelectTopBar(
                            controller: controller,
                            rows: rows,
                            toggle: toggleSelecting
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        filterRow(
                            unfiltered: unfiltered,
                            shareIndex: shareIndex,
                            hasRows: !rows.isEmpty,
                            canSelect: rows.contains(where: \.shareable)
                        )
                    }
                    if controller.albumOpen {
                        HiddenAlbumNote(count: library.hiddenCount)
                    }
                    LibraryStatusLine(state: library.searchState)
                    if model.capabilities.transcripts {
                        // results said in their video: a tap opens the post playing from that moment (APP-API-CONTRACT 47.5)
                        LibrarySaidStrip(library: library) { post, said in
                            library.pendingMoment = PendingMoment(postKey: post.id, seconds: said.start)
                            let item = model.mediaItem(for: post)
                            controller.open(item, initial: item.face.id)
                        }
                    }
                }
                // one hairline along the bar's bottom edge says "working": the whole library paging in (with its
                // progress), or the server still searching. The status line above it keeps only the answer.
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CobaltColor.hairline).frame(height: 0.5).allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) { activityBar }
                .motion(Motion.rows, value: library.searchState)
                .motion(Motion.fade, value: library.loadingAll == nil)
            }
            // bottom Liquid Glass selection sheet: picked items + thumb-reachable action grid
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if controller.selecting {
                    LibraryPickedSheet(
                        model: model,
                        controller: controller,
                        rows: rows,
                        tier: tier,
                        makeLink: { Task { await controller.makeLinkAndEnd(controller.freshRows(from: rows)) } },
                        file: { target in Task { await controller.makeLinkAndEnd(controller.freshRows(from: rows), into: target) } },
                        share: { Task { await controller.shareAndEnd(rows) } }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .motion(Motion.rows, value: controller.selecting)
            // hold a tile or a pick to see its media; isolated so peeking never re-evaluates the masonry grid
            .overlay { LibraryPeekOverlay(controller: controller, paneBeside: paneBeside, haptics: haptics) }
            // a search with room for the pane opens its best match beside the results: the query and the top hit both in view
            .onChange(of: library.searchState) { _, state in
                guard paneBeside, !controller.selecting, case .results(let count, _) = state, count > 0,
                      let best = rows.first else { return }
                controller.openAutomatically(best.item)
            }
            .statusConfirm(controller: controller)
            .modifier(LibraryPaneBridge(controller: controller, pane: pane, push: push))
            // the freeze hunt (owner, 2026-11-14): the grid is back on screen after a detail
            .onAppear {
                Breadcrumbs.add("library.appear")
                controller.checkStackSoon()
            }
            #if os(iOS)
            .background(LibraryAnchor(controller: controller))
            #endif
            .onDisappear { Breadcrumbs.add("library.disappear") }
            .modifier(LibrarySkyMapPresenter(model: model, controller: controller))
            .modifier(NamesPresenter(model: model))
            // a collection chip on the shelves pushes the same screen the links tab does
            .navigationDestination(for: CollectionRoute.self) { route in
                CollectionScreen(model: model, collectionID: route.id)
            }
            .renameAlert(item: $controller.renaming, model: model)
            .modifier(LibraryCombineSheet(model: model, controller: controller))
            .modifier(LibraryAddToLinkPresenter(model: model, controller: controller))
            .modifier(LibraryImageCropPresenter(
                model: model, target: $controller.croppingPicture, done: { line in controller.showStatus(line) }))
            .modifier(EmoteEditorPresenter(model: model, target: $controller.makingEmote))
            .confirmationDialog(
                Copy.Media.deleteEverythingTitle, isPresented: deletingPresented, titleVisibility: .visible,
                presenting: controller.deleting
            ) { item in
                Button(Copy.Media.deleteEverything, role: .destructive) { controller.deleteEverything(item) }
                Button(Copy.Media.keep, role: .cancel) {}
            } message: { item in
                Text(controller.deleteMessage(item))
            }
            .confirmationDialog(
                Copy.Media.makePrivateTitle, isPresented: makingPrivatePresented, titleVisibility: .visible,
                presenting: controller.makingPrivate
            ) { item in
                Button(Copy.Media.makePrivate, role: .destructive) { controller.setVisibility(item, public: false) }
                Button(Copy.Media.keepPublic, role: .cancel) {}
            } message: { _ in
                Text(Copy.Media.makePrivateMessage)
            }
            #if os(macOS)
            .background { macShortcuts }
            #endif
            .modifier(LibraryClickRows(controller: controller, rows: rows))
            .background { GalleryFileShare(fileURLs: $controller.filesToShare) }
            // centred over a light scrim; isolated so share prep updates never re-evaluate the grid
            .overlay { LibrarySharePrepOverlay(controller: controller) }
        core
            // a tick, select mode on and off, and the share sheet ready: felt as well as seen (Settings › haptics)
            .haptic(.selection, trigger: controller.picked, enabled: haptics)
            .haptic(.impact(weight: .light), trigger: controller.selecting, enabled: haptics)
            .haptic(.success, trigger: controller.filesToShare.isEmpty, enabled: haptics) { !$0 }
            .haptic(.success, trigger: controller.shareLinksMade, enabled: haptics)
            .haptic(.success, trigger: controller.doneTick, enabled: haptics)
            .haptic(.warning, trigger: controller.warnTick, enabled: haptics)
            .haptic(.error, trigger: controller.failTick, enabled: haptics)
            .onAppear { controller.showStatus = { shell.showStatus($0) } }
            // 0 nothing to load, 1 the whole library (or album), 2 the same but the album is still locked: wait, 3 the same but
            // the server search is still out: wait for its answer first (it covers the whole library and comes sooner alone)
            .task(id: wholeLibraryStep) {
                if wholeLibraryStep == 1 { await library.loadAll() }
            }
            // the album: locked at every open, its first page once the owner is in. `initial` only reads: a rebuilt view
            // (the zoom-back fix's new stack, a fold, a rotation, a pane) sees the value the controller already acted on,
            // and `albumSeen` compares with that, so only a real open or close drops the selection and the sheets
            .onChange(of: library.showingHidden, initial: true) { _, open in
                if open, !model.capabilities.hidden { library.showingHidden = false; return }
                guard controller.albumSeen(open: open) else { return }
                #if DEBUG
                if open, previewUnlocked { controller.hiddenUnlocked = true }
                #endif
            }
            .task(id: controller.albumOpen) { await controller.loadAlbum() }
            .onChange(of: lifecycle.phase) { _, phase in
                if phase == .background { controller.relockHidden() } else if phase == .active { controller.promptIfNeeded() }
            }
            .onChange(of: model.selectedTab) { _, tab in
                if tab == .library { controller.promptIfNeeded() } else { controller.relockHidden() }
            }
            .onDisappear { if model.selectedTab != .library { controller.relockHidden() } }
            .onChange(of: library.expandedPostID, initial: true) { _, id in
                guard let id else { return }
                library.expandedPostID = nil
                Task { await reveal(id) }
            }
            // a post that became hidden leaves the detail and the sheets; the app switcher's cover goes outermost
            .modifier(LibraryHiddenWatchers(model: model, controller: controller))
    }

    private func content(rows: [LibraryRow], phase: LibraryPhase, shareIndex: ShareSetIndex, held: Bool) -> some View {
        phaseContent(rows: rows, phase: phase, shareIndex: shareIndex)
            // the last search's tiles while the next one is out: dimmed, and not tappable (they may not match any more)
            // (only the dim animates: the tiles themselves change in place as they always did)
            .animation(Motion.fade) { $0.opacity(held ? 0.4 : 1) }
            .allowsHitTesting(!held)
    }

    /// Whether the last search's rows stay on screen in place of the loading tiles: only while words are in the field and
    /// the server (or the whole-library paging) is still working on them, and only once there were rows to keep.
    private func holdsRows(_ phase: LibraryPhase) -> Bool {
        guard phase == .loading, !heldRows.isEmpty, !library.posts.isEmpty, !library.showingHidden else { return false }
        guard !library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return library.searchState == .searching || library.searchState == .waking || library.loadingAll != nil
    }

    @ViewBuilder
    private func phaseContent(rows: [LibraryRow], phase: LibraryPhase, shareIndex: ShareSetIndex) -> some View {
        switch phase {
        // The tiles and the grey loading tiles are one mosaic (one scroll view) on purpose: swapping scroll views under
        // the top bar while typing took the keyboard away from the search field at every "searching…".
        case .rows where library.viewMode == .mosaic, .loading where library.viewMode == .mosaic:
            let loading = phase == .loading
            LibraryMosaic(
                rows: loading ? [] : rows, controller: controller, tier: tier, footer: loading ? .none : footer,
                skeleton: loading, zoom: zoomSpace, shareIndex: shareIndex, shelves: shelves(loading: loading))
        case .rows:
            if tier == .compact {
                LibraryList(rows: rows, controller: controller, footer: footer, zoom: zoomSpace, shareIndex: shareIndex)
            } else {
                LibraryTable(rows: rows, controller: controller, footer: footer, shareIndex: shareIndex)
            }
        case .locked:
            HiddenLockedCard(controller: controller)
        default:
            LibraryPlaceholder(phase: phase, controller: controller)
        }
    }

    // MARK: the filter row

    /// One row of filters: the kind chips scroll, and the links menu chip + `select` button stay pinned at the
    /// trailing end behind a hairline, keeping the bottom of the masonry completely clear while browsing.
    @ViewBuilder
    private func filterRow(unfiltered: [LibraryRow], shareIndex: ShareSetIndex, hasRows: Bool, canSelect: Bool) -> some View {
        let kinds = model.capabilities.gallery || model.capabilities.hidden
        let links = model.capabilities.shareSets && !model.shareSets.sets.isEmpty && !library.showingHidden
        if kinds || links || hasRows {
            HStack(spacing: 0) {
                if kinds {
                    LibraryKindChips(
                        model: model, extra: debugExtra,
                        pickAll: { kind, share in pickKind(kind, thenShare: share) })
                    .equatable()
                } else {
                    Spacer(minLength: 0)
                }
                if links || hasRows {
                    if kinds {
                        Rectangle()
                            .fill(CobaltColor.caption.opacity(0.3))
                            .frame(width: 1, height: 18)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 6) {
                        if links {
                            LibraryShareMenu(model: model, rows: unfiltered, index: shareIndex, filter: $controller.shareFilter)
                        }
                        if hasRows {
                            LibrarySelectButton(disabled: !canSelect, action: toggleSelecting)
                        }
                    }
                    .padding(.leading, kinds ? 8 : 12)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
                }
            }
            .background(.bar)
        }
    }

    // MARK: what is already shared

    /// The links and collections the tiles badge (empty while the server makes no share links).
    private var shareIndex: ShareSetIndex {
        guard model.capabilities.shareSets else { return .empty }
        return shareIndexCache.index(sets: model.shareSets.sets, collections: model.shareSets.collections)
    }

    /// The shelf over the mosaic: while not selecting or searching (iPhone, iPad and Mac alike). While the library or the
    /// links are still loading, a device that has shown the shelf before gets its grey cards in the same place, so the
    /// tiles do not jump down when the links arrive.
    private func shelves(loading: Bool) -> LibraryShelves? {
        guard !controller.selecting, !library.showingHidden,
              library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if LibraryShelves.hasContent(model) { return LibraryShelves(model: model, controller: controller) }
        let waiting = loading || model.shareSets.state == .loading || model.shareSets.state == .idle
        if waiting, LibraryShelves.wasSeen { return LibraryShelves(model: model, controller: controller, placeholder: true) }
        return nil
    }

    // MARK: toolbar

    private var sortMenu: some View {
        LibrarySortMenu(library: library, offersOffline: model.store.canKeep, offersKinds: model.capabilities.gallery)
            .accessibilityIdentifier("library.sort")
    }

    /// Regular width below `wide` (portrait or beside the pane) puts the sort menu with the view buttons so the
    /// trailing bar doesn't crowd into overflow; compact, wide regular and Mac keep it trailing.
    private var sortLeads: Bool {
        #if os(iOS)
        sizeClass == .regular && tier != .wide
        #else
        false
        #endif
    }

    #if os(iOS)
    /// Compact width (iPhone, Duo Outer, narrow Split View): the bar folds secondary actions into one "…" menu.
    private var isCompactWidth: Bool { sizeClass == .compact }
    #endif

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        if isCompactWidth {
            // Compact width: one "…" menu with every secondary action, then the activity pill and the settings gear (the
            // shell's header, `PhoneRootToolbar`), three trailing items at most, in select mode too. Nothing leading.
            PhoneRootToolbar(model: model) {
                LibraryPhoneMenu(model: model, controller: controller, toggleSelecting: toggleSelecting)
            }
        } else {
            padToolbar
        }
        #else
        ToolbarItem(placement: .navigation) { LibraryViewSwitcher(library: library) }
        if model.capabilities.search, !controller.selecting {
            ToolbarItem(placement: .navigation) { LibrarySkyMapButton(controller: controller) }
        }
        trailingToolbar
        #endif
    }

    #if os(iOS)
    /// Regular-width bar (Duo inner display, iPad): view switcher, sort, paste & file, inspector toggle.
    @ToolbarContentBuilder
    private var padToolbar: some ToolbarContent {
        // Two plain buttons in one group, drawn as one glass capsule like the trailing group. A segmented `Picker` in a
        // toolbar item got a second glass capsule behind it on iOS 26 (the bar's and the control's own).
        ToolbarItemGroup(placement: .topBarLeading) {
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                LibraryViewButton(library: library, mode: mode)
            }
            if sortLeads { sortMenu }
            // the sky map is a third way to look at the library (only where the search has embedded the posts)
            if model.capabilities.search, !controller.selecting { LibrarySkyMapButton(controller: controller) }
        }
        .duoVisibilityPriority(.automatic)
        // the queue is a sheet on iPhone and iPad (not a tab); select mode keeps its controls and drops this button
        if !controller.selecting { QueueToolbarItem(model: model) }
        trailingToolbar
    }
    #endif

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // select lives in the pill at the bottom (`LibrarySelectPill`), not here
            if !sortLeads { sortMenu }
            #if os(macOS)
            Button(Copy.Library2.refresh, systemImage: Symbol.Library.refresh) { Task { await controller.refresh() } }
                .labelStyle(.iconOnly)
                .keyboardShortcut("r", modifiers: .command)
                .help(Copy.Library2.refresh)
            #endif
            #if os(iOS)
            if tier == .compact {
                LibraryAddMenu(showsFile: model.capabilities.showsFileButton)
            } else {
                PasteFileButtons(showsFile: model.capabilities.showsFileButton)
            }
            #else
            PasteFileButtons(showsFile: model.capabilities.showsFileButton)
            #endif
            if paneBeside, let pane {
                Button(Copy.Library2.toggleDetail, systemImage: Symbol.Library.inspector) {
                    if pane.isVisible { pane.close() } else { pane.reveal() }
                }
                .labelStyle(.iconOnly)
                // with nothing in the pane (never opened, or closed for good) the button has nothing to show
                .disabled(pane.item == nil)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(Copy.Library2.toggleDetail)
            }
        }
        .duoVisibilityPriority(.high)
    }

    private func toggleSelecting() {
        withAnimation(Motion.rows) {
            if controller.selecting { controller.endSelecting() } else { controller.beginSelecting() }
        }
    }

    /// A kind chip's long press: the chip's posts ticked in one go, and shared at once for `share all`.
    private func pickKind(_ kind: LibraryKindFilter, thenShare share: Bool) {
        model.library.showingHidden = false     // a kind chip is the library's, not the album's
        model.library.kindFilter = kind
        withAnimation(Motion.rows) { controller.pickOnly(rows) }
        if share { Task { await controller.shareAndEnd(rows) } }
    }

    #if os(macOS)
    /// `view ▸ as mosaic ⌘1` / `as table ⌘2`: invisible buttons that stay in the hierarchy so the shortcuts work.
    private var macShortcuts: some View {
        Group {
            Button(Copy.Library2.asMosaic) { library.viewMode = .mosaic }.keyboardShortcut("1", modifiers: .command)
            Button(Copy.Library2.asTable) { library.viewMode = .table }.keyboardShortcut("2", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    /// The top bar's working hairline: the whole library's pages (a real fraction), else a sweep while the server searches.
    @ViewBuilder
    private var activityBar: some View {
        let searching = library.searchState == .searching || library.searchState == .waking
        if let progress = library.loadingAll {
            LibraryActivityBar(
                fraction: Double(progress.loaded) / Double(max(progress.total, 1)),
                label: Copy.Library2.loadingAll(progress.loaded, of: progress.total))
        } else if searching, !library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LibraryActivityBar(fraction: nil, label: Copy.Search.searching)
        }
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { controller.deleting != nil }, set: { if !$0 { controller.deleting = nil } })
    }

    private var makingPrivatePresented: Binding<Bool> {
        Binding(get: { controller.makingPrivate != nil }, set: { if !$0 { controller.makingPrivate = nil } })
    }

    // MARK: "open in library"

    /// Loads pages until the post is in, makes sure a filter does not hide it, and shows it: the mosaic scrolls it
    /// to the centre and lights it, the table selects it (the pane beside it shows it).
    private func reveal(_ id: String) async {
        guard await library.locate(postID: id) else {
            shell.showStatus(Copy.Library2.notFound)
            return
        }
        // the rows that follow the pages `locate` loaded (the snapshot on screen may still be a build behind)
        let settled = await model.settledLibraryRows()
        if !settled.contains(where: { $0.id == id }) {
            library.query = ""
            library.show = .everything
        }
        if !controller.compact { controller.selection = id }
        // the table beside the pane has only the selection to show; every other view scrolls to it and lights it
        if controller.compact || library.viewMode == .mosaic { controller.reveal = LibraryReveal(id: id) }
    }
}

/// Isolated overlay reading `controller.peek` so holding a tile never invalidates `LibraryContent` or the mosaic grid.
private struct LibraryPeekOverlay: View {
    let controller: LibraryController
    let paneBeside: Bool
    let haptics: Bool

    var body: some View {
        ZStack {
            if let row = controller.peek, !paneBeside {
                LibraryPeek(row: row)
                    .transition(.opacity)
            }
        }
        .motion(Motion.card, value: controller.peek?.id)
        .haptic(.impact(weight: .light), trigger: controller.peek?.id, enabled: haptics) { $0 != nil }
    }
}

/// Isolated overlay reading `controller.preparingShare` / `sharePrep` so share progress ticks never re-evaluate the grid.
private struct LibrarySharePrepOverlay: View {
    let controller: LibraryController

    var body: some View {
        ZStack {
            if controller.preparingShare, !controller.sharePrep.isEmpty {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .transition(.opacity)
                LibrarySharePrepCard(controller: controller) { controller.shareCancelled = true }
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .motion(Motion.card, value: controller.preparingShare)
    }
}

/// Memoizes `ShareSetIndex` across body passes (not observed) using O(1) CoW storage pointer checks.
private final class ShareSetIndexCache {
    private var lastSets: [ShareSet] = []
    private var lastCollections: [ShareCollection] = []
    private var cached: ShareSetIndex?

    func index(sets: [ShareSet], collections: [ShareCollection]) -> ShareSetIndex {
        if let cached, sets.count == lastSets.count, collections.count == lastCollections.count {
            let sameSets = sets.withUnsafeBufferPointer { a in
                lastSets.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
            }
            let sameCollections = collections.withUnsafeBufferPointer { a in
                lastCollections.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
            }
            if sameSets && sameCollections { return cached }
        }
        let built = ShareSetIndex(sets: sets, collections: collections)
        lastSets = sets
        lastCollections = collections
        cached = built
        return built
    }
}

/// Remembers the rows on screen (whenever there are any) as the ones a search in flight keeps showing; forgets them when
/// the hidden album opens or closes. Its own modifier: the screen's body chain is at the type checker's limit.
private struct LibraryHoldRows: ViewModifier {
    let rows: [LibraryRow]
    let showing: Bool
    let album: Bool
    @Binding var held: [LibraryRow]

    private struct Signature: Equatable {
        let count: Int
        let firstID: String?
        let midID: String?
        let lastID: String?
    }

    func body(content: Content) -> some View {
        let sig = showing
            ? Signature(
                count: rows.count,
                firstID: rows.first?.id,
                midID: rows.isEmpty ? nil : rows[rows.count / 2].id,
                lastID: rows.last?.id)
            : Signature(count: 0, firstID: nil, midID: nil, lastID: nil)
        content
            .onChange(of: sig) { _, now in
                if now.count > 0 { held = rows }
            }
            .onChange(of: album) { held = [] }
    }
}

/// The quiet line under the search field (APP-API-CONTRACT 21): `searching…`, then `12 results` (with a fainter
/// `· 3 still indexing`), `search is waking up…`, or why only name matches show. Nothing while there is no server search.
/// No spinner: the hairline along the bar's bottom (`LibraryActivityBar`) says the app is working.
struct LibraryStatusLine: View {
    let state: LibrarySearchState

    var body: some View {
        if let text = Copy.Search.line(state) {
            HStack(spacing: 0) {
                Text(text)
                    .foregroundStyle(state == .searching ? .tertiary : .secondary)
                if let note = Copy.Search.note(state) {
                    Text(note).foregroundStyle(.tertiary)
                }
            }
            .font(CobaltType.captionSmall)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .transition(.opacity)
        }
    }
}

/// A 2 pt hairline along the bottom of the library's top bar while something is loading: filling up with the whole
/// library's pages, or a calm sweep while the server searches (still under Reduce Motion). Replaces the old
/// `loading the whole library · 60 of 140` text line; VoiceOver still reads that text.
struct LibraryActivityBar: View {
    /// 0...1, or nil for a sweep.
    let fraction: Double?
    let label: String

    var body: some View {
        StoryBar(
            fraction: fraction,
            ink: ProgressInk(
                fill: CobaltColor.text.opacity(0.55), onFill: CobaltColor.onText, track: .clear,
                quiet: CobaltColor.caption, error: CobaltColor.errorText),
            height: 2)
            .padding(.horizontal, 16)
            .transition(.opacity)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - the pane (a post opens there everywhere)

/// Where the library's detail goes (apple/CONTRACT-PANE.md section 5; owner, 2026-11-23: pane everywhere). A post is the
/// pane's `.post` page in every placement: beside the tab where the window has room, the sheet (the cover, spanned) on one
/// narrow screen. The hold's peek and the select actions open beside the tab by themselves. On one narrow screen a hold
/// shows the overlay peek and lifting the finger opens the post (`PeekOnHold.opensOnRelease`), and select mode keeps its
/// pill, which expands into the select actions' sheet on a swipe up or a tap on its count (`LibrarySelectPill`).
/// `selection` is the post the pane shows: set by a tap, a click or "open in library", cleared when the pane shows
/// something else (or is hidden).
private struct LibraryPaneBridge: ViewModifier {
    @Bindable var controller: LibraryController
    let pane: Pane?
    /// The iPhone's way to show a post: push the unified detail instead of opening the pane's sheet (nil elsewhere).
    let push: (@MainActor (MediaDetailRoute) -> Void)?

    /// The pane sits beside the tab (macOS column), not as an iOS single-focus overlay or compact sheet.
    private var beside: Bool { pane?.sitsBesideTab ?? false }

    func body(content: Content) -> some View {
        content
            .onChange(of: beside, initial: true) { _, now in
                controller.compact = !now
                guard let pane else { return }
                if !now {
                    // the pane lost its side position (rotation to a narrow window, a fold): a peek in flight is the overlay's
                    pane.close(ifShowing: .selection)
                    if pane.isPeeking { pane.endPeek() }
                }
            }
            // the select actions page reads the controller from the pane
            .task { pane?.provide(controller) }
            .onChange(of: controller.selection) { old, new in
                // the iPhone: a tap (or a hold's release, the sky map, "said at") pushes the detail, and the library
                // keeps no selection (the pane never shows the post, so nothing would clear it)
                // (never `pane.open(.post)` from here on the iPhone; a post the pane already shows, opened elsewhere,
                // falls through to the pane logic below, so nothing is presented twice)
                if let push, let new, pane?.item != .post(new) {
                    controller.selectionIsAutomatic = false
                    if let post = controller.selectedItem?.post { push(MediaDetailRoute(post: post)) }
                    controller.selection = nil
                    return
                }
                guard let pane else { return }
                if let new {
                    let automatic = controller.selectionIsAutomatic
                    controller.selectionIsAutomatic = false
                    guard pane.item != .post(new) || !pane.isVisible else { return }
                    if automatic {
                        // a search's best match: never over a running stream or a post the owner opened
                        if !pane.openIfIdle(.post(new)) { controller.selection = nil }
                    } else {
                        pane.open(.post(new))
                    }
                } else if let old, pane.item == .post(old), !pane.isPeeking {
                    pane.close(ifShowing: .post(old))
                }
            }
            .onChange(of: pane?.route, initial: true) { _, route in
                guard let pane, !pane.isPeeking else { return }
                var shown: String?
                if let route, route.isVisible, case .post(let id)? = route.item { shown = id }
                // select actions live in LibrarySelectTopBar + LibraryPickedSheet everywhere; close any stale restored route
                if let route, route.isVisible, route.item == .selection { pane.close(ifShowing: .selection) }
                if controller.selection != shown { controller.selection = shown }
            }
            .onChange(of: controller.selecting) { _, selecting in
                guard let pane else { return }
                // close any stale selection pane route; select actions live in the top grid + bottom picked sheet everywhere
                if !selecting { pane.close(ifShowing: .selection) }
            }
            .onChange(of: controller.peek?.id) { _, id in
                guard let pane, beside else { return }
                if let id { pane.peek(id) } else { pane.endPeek() }
            }
    }
}

// MARK: - the states with no rows

/// What the content area shows in place of rows: the spinner of a table's first load, `can't load the
/// library.` with `try again`, the quiet empty line, or `nothing matches "<q>".`. A scroll view, so pulling
/// down still refreshes.
private struct LibraryPlaceholder: View {
    let phase: LibraryPhase
    let controller: LibraryController

    var body: some View {
        ScrollView {
            Group {
                switch phase {
                case .noMatch(let query):
                    Text(Copy.Library2.noMatch(query))
                        .font(CobaltType.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 56)
                case .emptyKind(let kind, let kept):
                    VStack(spacing: 12) {
                        Text(Copy.Library2.nothingOfKind(kind, kept: kept))
                            .font(CobaltType.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(Copy.Library2.showEverythingAgain) {
                            controller.library.kindFilter = .all
                            controller.library.show = .everything
                        }
                        .buttonStyle(.cobaltSecondary(fullWidth: false))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 56)
                case .emptyHidden:
                    HiddenAlbumEmpty()
                case .failed:
                    LibraryProblem(state: .failed) { Task { await controller.refresh() } }
                case .loading:
                    // the list's and the table's first load: grey rows where the rows land, never a spinner
                    LibrarySkeletonRows()
                case .empty, .rows, .locked:
                    LibraryProblem(state: .empty) {}
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, phase == .loading ? 8 : 40)
        }
        .refreshable { controller.pullToRefresh() }
    }
}

/// The list's and the table's skeleton: a dozen rows the shape of a library row (a square thumbnail, a title line, a
/// caption line, a short trailing size), widths varied so it reads as content, under one band of light.
struct LibrarySkeletonRows: View {
    private static let titles: [CGFloat] = [0.62, 0.48, 0.71, 0.55, 0.66, 0.42, 0.58, 0.69, 0.5, 0.64, 0.45, 0.6]

    var body: some View {
        GeometryReader { proxy in
            let text = max(proxy.size.width - 32 - 44 - 10 - 56, 60)
            VStack(spacing: 0) {
                ForEach(Self.titles.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Skeleton.fill)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(Skeleton.fill).frame(width: text * Self.titles[i], height: 10)
                            Capsule().fill(Skeleton.fill).frame(width: text * 0.32, height: 7)
                        }
                        Spacer(minLength: 0)
                        Capsule().fill(Skeleton.fill).frame(width: 36, height: 7)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .skeletonShimmer()
        }
        .frame(height: CGFloat(Self.titles.count) * 60)
        .accessibilityElement()
        .accessibilityLabel(Copy.Library2.loadingA11y)
    }
}

/// What the screen shows in place of tiles: a spinner, "can't load the library." with `try again`, or the
/// quiet empty line.
enum LibraryProblemState: Equatable {
    case failed, loading, empty
}

struct LibraryProblem: View {
    let state: LibraryProblemState
    let retry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .failed:
                ContentUnavailableView {
                    Label(Copy.libraryFailed, systemImage: Symbol.error)
                        .font(CobaltType.body)
                } actions: {
                    Button(Copy.tryAgain, systemImage: Symbol.retry, action: retry)
                        .buttonStyle(.cobaltSecondary(fullWidth: false))
                }
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            case .empty:
                ContentUnavailableView {
                    Label(Copy.libraryEmpty, systemImage: Symbol.library)
                        .font(CobaltType.body)
                }
            }
        }
    }
}

/// Names each file while a share is copying it, then goes away when the sheet is ready.
/// The card while ticked posts are copied for the share sheet: what is going out (`2 videos · 1 photo`), a fan of
/// their pictures, a bar, and each post with its kind, where it stands and a mark. The share sheet opens once every row
/// is done; `cancel` stops before the next post and opens nothing.
private struct LibrarySharePrepCard: View {
    let controller: LibraryController
    let cancel: () -> Void

    private var rows: [SharePrepRow] { controller.sharePrep }

    /// Rows listed before `and n more`.
    private static let listed = 4

    var body: some View {
        let done = rows.filter(\.state.done).count
        VStack(spacing: 14) {
            SharePrepFan(rows: Array(rows.prefix(3)))
            VStack(spacing: 3) {
                Text(Copy.Library2.sharePrepTitle(rows.count))
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                Text(kinds)
                    .font(Font.cobalt(12.5, relativeTo: .subheadline))
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(rows.count, 1)))
                    .tint(CobaltColor.text)
                Text(Copy.Library2.sharePrepCount(done: done, of: rows.count))
                    .font(Font.cobalt(12, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(CobaltColor.caption)
                    .contentTransition(.numericText(value: Double(done)))
            }
            VStack(spacing: 10) {
                ForEach(rows.prefix(Self.listed)) { row in SharePrepLine(row: row, fraction: fraction(of: row)) }
                if rows.count > Self.listed {
                    Text(Copy.Library2.sharePrepMore(rows.count - Self.listed))
                        .font(Font.cobalt(12, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // when the copying pass ended with failures: what failed and the two choices
            SharePrepSummaryBar(controller: controller)
            Button(Copy.Library2.shareCancel, role: .cancel, action: cancel)
                .buttonStyle(.cobaltSecondary(fullWidth: true, compact: true))
        }
        .padding(18)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(CobaltColor.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .padding(24)
        .animation(Motion.rows, value: done)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// How far this post's copy is, from the downloads engine's row for it (the activity list's own status): nil while the copy
    /// reports no bytes, or when the post is not downloading.
    private func fraction(of row: SharePrepRow) -> Double? {
        guard row.state == .downloading else { return nil }
        return controller.model.activity.status("download:" + OfflineDownloads.shareKey(row.id))?.fraction
    }

    private var kinds: String {
        func count(_ kind: SharePrepRow.Kind) -> Int { rows.filter { $0.kind == kind }.count }
        return Copy.Library2.sharePrepKinds(
            videos: count(.video), photos: count(.photo), webps: count(.webp))
    }
}

/// Up to three of the posts' pictures, fanned like a hand of cards, each with its kind in the corner.
private struct SharePrepFan: View {
    let rows: [SharePrepRow]

    var body: some View {
        ZStack {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let spread = Double(index) - Double(rows.count - 1) / 2
                SharePrepThumb(row: row, side: 64)
                    .rotationEffect(.degrees(spread * 9))
                    .offset(x: spread * 30, y: abs(spread) * 5)
                    .zIndex(-abs(spread))
            }
        }
        .frame(height: 78)
        .accessibilityHidden(true)
    }
}

/// A post's picture with a small kind glyph (film, photo, sparkles, stack) in its corner.
private struct SharePrepThumb: View {
    let row: SharePrepRow
    let side: CGFloat

    var body: some View {
        FacePicture(item: row.item, maxPixel: Int(side * 3), showsGlyph: false)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: side > 40 ? 1.5 : 0.75)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: SharePrepThumb.symbol(row.kind))
                    .font(.system(size: side > 40 ? 10 : 7.5, weight: .bold))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .frame(width: side > 40 ? 20 : 14, height: side > 40 ? 20 : 14)
                    .background(CobaltColor.badgeBack, in: Circle())
                    .padding(side > 40 ? 4 : 2)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    static func symbol(_ kind: SharePrepRow.Kind) -> String {
        switch kind {
        case .video: return Symbol.Library.typeVideo
        case .photo: return Symbol.Library.typePhoto
        case .webp: return Symbol.Library.typeWebp
        }
    }
}

/// One post on the share card: its picture, its title, `video · 0:12 · downloading…`, and a mark for where it stands.
private struct SharePrepLine: View {
    let row: SharePrepRow
    /// The copy's progress, when the engine knows it (`OfflineDownloads.transfer`).
    var fraction: Double?

    var body: some View {
        HStack(spacing: 10) {
            SharePrepThumb(row: row, side: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(Font.cobalt(13, relativeTo: .body))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(Font.cobalt(11.5, relativeTo: .caption))
                    .foregroundStyle(row.state == .skipped ? CobaltColor.errorText : CobaltColor.caption)
                    .lineLimit(1)
                if row.state == .skipped, let failure = row.failure {
                    Text(Copy.Save.sharePrepRowFailure(failure))
                        .font(Font.cobalt(11, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            mark
                .frame(width: 20, height: 20)
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var parts = [word(row.kind)]
        if let length = row.length { parts.append(Format.seconds(length)) }
        parts.append(state)
        return parts.joined(separator: " · ")
    }

    private func word(_ kind: SharePrepRow.Kind) -> String {
        switch kind {
        case .video: return Copy.Library2.shareKindVideo
        case .photo: return Copy.Library2.shareKindPhoto
        case .webp: return Copy.Library2.shareKindWebp
        }
    }

    private var state: String {
        switch row.state {
        case .onDevice: return Copy.Library2.shareOnDevice
        case .waiting: return Copy.Library2.shareWaiting
        case .downloading: return Copy.Library2.shareDownloading
        case .ready: return Copy.Library2.shareReady
        case .skipped: return Copy.Library2.shareSkipped
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch row.state {
        case .downloading:
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(CobaltColor.caption)
        case .onDevice, .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(CobaltColor.text)
                .transition(.scale.combined(with: .opacity))
        case .skipped:
            Image(systemName: "exclamationmark.circle").foregroundStyle(CobaltColor.errorText)
        }
    }
}

#if os(iOS)
/// The iPhone library's "more" menu: paste a link, and (where the server takes files) add from photos or files. The same
/// actions as `PasteFileButtons`, folded into one item so the bar fits.
private struct LibraryAddMenu: View {
    let showsFile: Bool
    @Environment(\.shell) private var shell

    var body: some View {
        Menu {
            Button(Copy.pasteA11y, systemImage: Symbol.paste) { shell.paste() }
            if showsFile {
                Button(Copy.sourcePhotos, systemImage: Symbol.sourcePhotos) { shell.choosePhotos() }
                Button(Copy.sourceFiles, systemImage: Symbol.sourceFiles) { shell.chooseFile() }
            }
        } label: {
            Label(Copy.Media.more, systemImage: Symbol.Library.more).labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Copy.Media.more)
        // the layout checks (apple/CobaltUITests): the "…" a stale half-width bar drops
        .accessibilityIdentifier("library.more")
    }
}
#endif

/// What a shift-click range runs through: the posts on screen, in order. Its own modifier: the screen's chain is
/// already at the type-checker's limit on iOS.
private struct LibraryClickRows: ViewModifier {
    let controller: LibraryController
    let rows: [LibraryRow]

    func body(content: Content) -> some View {
        content.onChange(of: rows, initial: true) { controller.shownRows = rows }
    }
}

#if os(iOS)
/// A plain, untouchable view inside the library's content, so the controller can tell whether the grid really is in a
/// window (the stuck zoom back, `LibraryController.checkStackSoon`).
private struct LibraryAnchor: UIViewRepresentable {
    let controller: LibraryController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        controller.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        controller.anchor = view
    }
}
#endif
