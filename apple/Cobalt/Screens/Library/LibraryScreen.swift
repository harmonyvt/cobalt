import CobaltKit
import SwiftUI

/// The library tab (CONTRACT-LIBRARY2): the owner's media as a mosaic or a table, one remembered switcher.
///
/// The **mosaic** is a dense masonry of faces at their real aspect (`LibraryMosaic`); the **table** is a real
/// sortable `Table` on the iPad and Mac and a dense two-line list on the iPhone (`LibraryTable`). Search, sort and
/// show live in the toolbar; a search, a filter or a sort other than newest first loads the whole library first
/// (the server pages by date only). Tapping opens the same tabbed `MediaDetail` as the orbit: pushed on the
/// phone (with the zoom from the tile), in a trailing inspector on the iPad and Mac. The context menu, rename and
/// `delete everything` are the same in every view.
///
/// iOS: this screen always brings its own navigation stack. Mac: a narrow window gets one; otherwise the window's
/// toolbar is already there.
struct LibraryScreen: View {
    let model: AppModel
    let tier: Tier

    @State private var controller: LibraryController

    init(model: AppModel, tier: Tier) {
        self.model = model
        self.tier = tier
        _controller = State(initialValue: LibraryController(model: model))
    }

    var body: some View {
        Group {
            #if os(iOS)
            // Always its own stack (the shell adds none), so the tier never changes this screen's identity.
            NavigationStack { LibraryContent(model: model, tier: tier, controller: controller) }
            #else
            if tier == .compact {
                NavigationStack { LibraryContent(model: model, tier: tier, controller: controller) }
            } else {
                LibraryContent(model: model, tier: tier, controller: controller)
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

    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var zoomSpace
    /// File URLs for the system share sheet. Assigned only once they are ready; the sheet clears this when it finishes.
    @State private var filesToShare: [URL] = []
    /// The last rows a search showed, kept on screen (dimmed) while the next words are still being searched, so each
    /// keystroke does not flash the tiles away to grey and back.
    @State private var heldRows: [LibraryRow] = []
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

    /// The iPhone puts its own search field in the top bar, so it folds away with the chips; the iPad and Mac keep the
    /// system's field. By device, not tier: an iPad resized to compact keeps the same field (no identity change).
    private var ownSearchField: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

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
        // `libraryRows` joins every post: built once here, not once per reader
        let unfiltered = unfilteredRows
        let shareIndex = self.shareIndex
        let rows = self.rows(from: unfiltered, index: shareIndex)
        let phase = phase(rows)
        let holding = holdsRows(phase)
        // Ticks a search, a filter or a delete took off screen are neither counted nor shared.
        let pickedCount = controller.selecting ? controller.pickedRows(rows).count : 0
        let shownRows: [LibraryRow] = holding ? heldRows : rows
        let shownPhase: LibraryPhase = holding ? .rows : phase
        content(rows: shownRows, phase: shownPhase, shareIndex: shareIndex, held: holding)
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
            .modifier(LibrarySearchable(
                text: $library.query, placement: searchPlacement, prompt: searchPrompt, enabled: !ownSearchField))
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    #if os(iOS)
                    if ownSearchField {
                        LibrarySearchField(text: $library.query, prompt: searchPrompt, fold: controller.fold)
                    }
                    #endif
                    if model.capabilities.gallery || model.capabilities.hidden {
                        LibraryKindChips(
                            model: model, extra: debugExtra,
                            pickAll: { kind, share in pickKind(kind, thenShare: share) })
                        .equatable()
                    }
                    if controller.albumOpen {
                        HiddenAlbumNote(count: library.hiddenCount)
                    }
                    if model.capabilities.shareSets, !model.shareSets.sets.isEmpty, !library.showingHidden {
                        LibraryShareChips(
                            model: model, rows: unfiltered, index: shareIndex, filter: $controller.shareFilter)
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
                .overlay(alignment: .bottom) { activityBar }
                .motion(Motion.rows, value: library.searchState)
                .motion(Motion.fade, value: library.loadingAll == nil)
                // folds away with the scroll and comes back on the way up (`LibraryTopBar.swift`)
                .modifier(LibraryBarFoldEffect(fold: controller.fold))
            }
            // select, by the thumb: the `select` pill, which grows into the panel with the picks and their actions
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !rows.isEmpty {
                    LibrarySelectPill(
                        model: model, controller: controller, rows: rows, toggle: toggleSelecting,
                        makeLink: { Task { await makeShareLink() } },
                        file: { target in Task { await makeShareLink(into: target) } },
                        share: { Task { await sharePicked() } })
                }
            }
            .motion(Motion.rows, value: controller.selecting)
            // hold a tile or a pick to see its media; lifting the finger closes it
            .overlay {
                if let row = controller.peek {
                    LibraryPeek(row: row)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .motion(Motion.card, value: controller.peek?.id)
            .haptic(.impact(weight: .light), trigger: controller.peek?.id, enabled: haptics) { $0 != nil }
            .statusConfirm(controller: controller)
            .modifier(LibraryInspector(model: model, controller: controller, enabled: tier != .compact))
            .modifier(LibraryPush(model: model, controller: controller, zoom: zoomSpace, enabled: tier == .compact))
            .modifier(LibrarySkyMapPresenter(model: model, controller: controller))
            .modifier(NamesPresenter(model: model))
            // a collection chip on the shelves pushes the same screen the links tab does
            .navigationDestination(for: CollectionRoute.self) { route in
                CollectionScreen(model: model, collectionID: route.id)
            }
            .renameAlert(item: $controller.renaming, model: model)
            .modifier(LibraryCombineSheet(model: model, controller: controller))
            .modifier(LibraryImageCropPresenter(
                model: model, target: $controller.croppingPicture, done: { line in controller.showStatus(line) }))
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controller.decideInspector(width: $0) }
            .onChange(of: tier, initial: true) { controller.compact = tier == .compact }
            .modifier(LibraryClickRows(controller: controller, rows: rows))
            .background { GalleryFileShare(fileURLs: $filesToShare) }
            // centred over a light scrim: at the bottom it sat under the floating tab bar
            .overlay {
                if controller.preparingShare, !controller.sharePrep.isEmpty {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                            .transition(.opacity)
                        LibrarySharePrepCard(rows: controller.sharePrep) { controller.shareCancelled = true }
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                }
            }
            .motion(Motion.card, value: controller.preparingShare)
            // a tick, select mode on and off, and the share sheet ready: felt as well as seen (Settings › haptics)
            .haptic(.selection, trigger: controller.picked, enabled: haptics)
            .haptic(.impact(weight: .light), trigger: controller.selecting, enabled: haptics)
            .haptic(.success, trigger: filesToShare.isEmpty, enabled: haptics) { !$0 }
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
            // the album: locked at every open, its first page once the owner is in
            .onChange(of: library.showingHidden, initial: true) { _, open in
                if open, !model.capabilities.hidden { library.showingHidden = false; return }
                controller.hiddenAlbumChanged(open: open)
                #if DEBUG
                if open, previewUnlocked { controller.hiddenUnlocked = true }
                #endif
            }
            .task(id: controller.albumOpen) { await controller.loadAlbum() }
            .onChange(of: scenePhase) { _, phase in
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
            // a different scroll view (or none): the top bar opens again
            .onChange(of: phase) { controller.fold.reset() }
            .onChange(of: library.viewMode) { controller.fold.reset() }
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
                skeleton: loading, zoom: zoomSpace, shareIndex: shareIndex, shelves: loading ? nil : shelves)
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

    // MARK: what is already shared

    /// The links and collections the tiles badge (empty while the server makes no share links).
    private var shareIndex: ShareSetIndex {
        guard model.capabilities.shareSets else { return .empty }
        return ShareSetIndex(sets: model.shareSets.sets, collections: model.shareSets.collections)
    }

    /// The shelves over the mosaic: while not selecting or searching (iPhone, iPad and Mac alike).
    private var shelves: LibraryShelves? {
        guard !controller.selecting, !library.showingHidden, LibraryShelves.hasContent(model),
              library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return LibraryShelves(model: model, controller: controller)
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        // Two plain buttons in one group, drawn as one glass capsule like the trailing group. A segmented `Picker` in a
        // toolbar item got a second glass capsule behind it on iOS 26 (the bar's and the control's own).
        ToolbarItemGroup(placement: .topBarLeading) {
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                LibraryViewButton(library: library, mode: mode)
            }
            // the sky map is a third way to look at the library (only where the search has embedded the posts)
            if model.capabilities.search, !controller.selecting { LibrarySkyMapButton(controller: controller) }
        }
        #else
        ToolbarItem(placement: .navigation) { LibraryViewSwitcher(library: library) }
        if model.capabilities.search, !controller.selecting {
            ToolbarItem(placement: .navigation) { LibrarySkyMapButton(controller: controller) }
        }
        #endif
        #if os(iOS)
        // the queue is a sheet on iPhone and iPad (not a tab); select mode keeps its controls and drops this button
        if !controller.selecting { QueueToolbarItem(model: model) }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            // select lives in the pill at the bottom (`LibrarySelectPill`), not here
            LibrarySortMenu(library: library, offersOffline: model.store.canKeep, offersKinds: model.capabilities.gallery)
            #if os(macOS)
            Button(Copy.Library2.refresh, systemImage: Symbol.Library.refresh) { Task { await controller.refresh() } }
                .labelStyle(.iconOnly)
                .keyboardShortcut("r", modifiers: .command)
                .help(Copy.Library2.refresh)
            #endif
            #if os(iOS)
            // the iPhone's bar is full: paste and file share one "more" menu there
            if tier == .compact {
                LibraryAddMenu(showsFile: model.capabilities.showsFileButton)
            } else {
                PasteFileButtons(showsFile: model.capabilities.showsFileButton)
            }
            #else
            PasteFileButtons(showsFile: model.capabilities.showsFileButton)
            #endif
            if tier != .compact {
                Button(Copy.Library2.toggleDetail, systemImage: Symbol.Library.inspector) {
                    controller.inspectorOpen.toggle()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(Copy.Library2.toggleDetail)
            }
        }
    }

    private func toggleSelecting() {
        withAnimation(Motion.rows) {
            if controller.selecting { controller.endSelecting() } else { controller.beginSelecting() }
        }
    }

    /// Copies each ticked face that is on screen, then presents the sheet and leaves select mode (as saving a
    /// gallery's photos does). A second tap while that runs does nothing.
    private func sharePicked() async {
        let urls = await controller.sharePicked(rows)
        guard !urls.isEmpty else { return }
        filesToShare = urls
        withAnimation(Motion.rows) { controller.endSelecting() }
    }

    /// Makes one link for the ticked posts that are on screen and copies it, then leaves select mode (as the share sheet
    /// does). The bar's verdict keeps the button off for too few, too many and private files; a second tap while this
    /// runs does nothing.
    private func makeShareLink() async {
        if await controller.makeShareLink(rows) {
            withAnimation(Motion.rows) { controller.endSelecting() }
        }
    }

    /// The pill's `collection`: the same link, filed in a collection (an existing one or a new one).
    private func makeShareLink(into target: LibraryController.CollectionTarget) async {
        if await controller.makeShareLink(rows, into: target) {
            withAnimation(Motion.rows) { controller.endSelecting() }
        }
    }

    /// A kind chip's long press: the chip's posts ticked in one go, and shared at once for `share all`.
    private func pickKind(_ kind: LibraryKindFilter, thenShare share: Bool) {
        model.library.showingHidden = false     // a kind chip is the library's, not the album's
        model.library.kindFilter = kind
        withAnimation(Motion.rows) { controller.pickOnly(rows) }
        if share { Task { await sharePicked() } }
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
    /// to the centre and lights it, the table selects it (the iPad and Mac's inspector shows it).
    private func reveal(_ id: String) async {
        guard await library.locate(postID: id) else {
            shell.showStatus(Copy.Library2.notFound)
            return
        }
        if !model.libraryRows.contains(where: { $0.id == id }) {
            library.query = ""
            library.show = .everything
        }
        if tier != .compact {
            controller.selection = id
            controller.inspectorOpen = true
        }
        // the iPad and Mac's table has only the selection to show; every other view scrolls to it and lights it
        if tier == .compact || library.viewMode == .mosaic { controller.reveal = LibraryReveal(id: id) }
    }
}

/// Remembers the rows on screen (whenever there are any) as the ones a search in flight keeps showing; forgets them when
/// the hidden album opens or closes. Its own modifier: the screen's body chain is at the type checker's limit.
private struct LibraryHoldRows: ViewModifier {
    let rows: [LibraryRow]
    let showing: Bool
    let album: Bool
    @Binding var held: [LibraryRow]

    func body(content: Content) -> some View {
        let ids: [String] = showing ? rows.map(\.id) : []
        content
            .onChange(of: ids) { _, now in
                if !now.isEmpty { held = rows }
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

// MARK: - the pushed detail (phone) and the inspector (iPad, Mac)

/// The phone's detail: pushed on the media's face, with the zoom from the tile it was opened from.
private struct LibraryPush: ViewModifier {
    let model: AppModel
    @Bindable var controller: LibraryController
    let zoom: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        content.navigationDestination(item: $controller.opened) { target in
            detail(target)
        }
    }

    @ViewBuilder
    private func detail(_ target: OpenedMedia) -> some View {
        let screen = MediaDetail(model: model, item: target.item, initial: target.initial)
            .hiddenCover(controller)
        #if os(iOS)
        screen.navigationTransition(.zoom(sourceID: target.item.post?.id ?? target.item.id, in: zoom))
        #else
        screen
        #endif
    }
}

/// The detail column of the iPad and Mac: a trailing inspector (360-460 pt, resizable) holding the same
/// `MediaDetail` in its own navigation stack, following the selection. Its state is remembered per device.
private struct LibraryInspector: ViewModifier {
    let model: AppModel
    @Bindable var controller: LibraryController
    let enabled: Bool

    func body(content: Content) -> some View {
        content.inspector(isPresented: enabled ? $controller.inspectorOpen : .constant(false)) {
            Group {
                if let item = controller.selectedItem {
                    NavigationStack {
                        MediaDetail(model: model, item: item, initial: item.face.id)
                    }
                    .hiddenCover(controller)
                    .id(controller.selection)
                } else {
                    Text(Copy.Library2.pickSomething)
                        .font(CobaltType.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .inspectorColumnWidth(min: 360, ideal: 420, max: 460)
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
                    LibraryProblem(state: .loading) {}
                case .empty, .rows, .locked:
                    LibraryProblem(state: .empty) {}
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
        .refreshable { controller.pullToRefresh() }
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
    let rows: [SharePrepRow]
    let cancel: () -> Void

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
                ForEach(rows.prefix(Self.listed)) { row in SharePrepLine(row: row) }
                if rows.count > Self.listed {
                    Text(Copy.Library2.sharePrepMore(rows.count - Self.listed))
                        .font(Font.cobalt(12, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
            ProgressView().controlSize(.small)
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
