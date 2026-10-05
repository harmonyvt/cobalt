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
/// Compact (iPhone, or any narrow window): the shell provides the navigation stack. Regular and wide: this screen
/// brings its own on iOS; the Mac's window toolbar is already there.
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
            if tier == .compact {
                LibraryContent(model: model, tier: tier, controller: controller)
            } else {
                NavigationStack { LibraryContent(model: model, tier: tier, controller: controller) }
            }
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
    }
}

// MARK: - what the library shows

/// What the content area is: the rows, or the reason there are none.
enum LibraryPhase: Equatable {
    case rows, loading, failed, empty
    case noMatch(String)
}

private struct LibraryContent: View {
    let model: AppModel
    let tier: Tier
    @Bindable var controller: LibraryController

    @Environment(\.shell) private var shell
    @Namespace private var zoomSpace
    #if DEBUG
    @Environment(\.libraryDebugRows) private var debugRows
    #endif

    private var library: LibraryModel { model.library }

    private var rows: [LibraryRow] {
        #if DEBUG
        if LibraryDebug.state != nil { return [] }
        if !debugRows.isEmpty { return LibraryDebug.merged(model.libraryRows, with: debugRows, query: library.query) }
        #endif
        return model.libraryRows
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
        if !rows.isEmpty { return .rows }
        if library.failure != nil, library.posts.isEmpty { return .failed }
        if library.isLoading || library.loadingAll != nil { return .loading }
        let query = library.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return .noMatch(query) }
        return .empty
    }

    private var footer: LibraryFooter {
        if library.failure != nil, !library.posts.isEmpty { return .failed }
        return library.hasMore ? .loading : .none
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
        let rows = self.rows
        let phase = phase(rows)
        content(rows: rows, phase: phase)
            .navigationTitle(Copy.library)
            .navigationSubtitle(Copy.libraryCounts(posts: library.postCount, files: library.fileCount))
            .searchable(text: $library.query, placement: searchPlacement, prompt: Copy.Library2.searchPrompt)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) { loadingAllLine }
            .modifier(LibraryInspector(model: model, controller: controller, enabled: tier != .compact))
            .modifier(LibraryPush(model: model, controller: controller, zoom: zoomSpace, enabled: tier == .compact))
            .renameAlert(item: $controller.renaming, model: model)
            .confirmationDialog(
                Copy.Media.deleteEverythingTitle, isPresented: deletingPresented, titleVisibility: .visible,
                presenting: controller.deleting
            ) { item in
                Button(Copy.Media.deleteEverything, role: .destructive) { controller.deleteEverything(item) }
                Button(Copy.Media.keep, role: .cancel) {}
            } message: { item in
                Text(controller.deleteMessage(item))
            }
            #if os(macOS)
            .background { macShortcuts }
            #endif
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controller.decideInspector(width: $0) }
            .onChange(of: tier, initial: true) { controller.compact = tier == .compact }
            .onAppear { controller.showStatus = { shell.showStatus($0) } }
            .task(id: library.needsWholeLibrary) {
                if library.needsWholeLibrary { await library.loadAll() }
            }
            .onChange(of: library.expandedPostID, initial: true) { _, id in
                guard let id else { return }
                library.expandedPostID = nil
                Task { await reveal(id) }
            }
    }

    @ViewBuilder
    private func content(rows: [LibraryRow], phase: LibraryPhase) -> some View {
        switch phase {
        case .rows:
            switch library.viewMode {
            case .mosaic:
                LibraryMosaic(rows: rows, controller: controller, tier: tier, footer: footer, skeleton: false, zoom: zoomSpace)
            case .table:
                if tier == .compact {
                    LibraryList(rows: rows, controller: controller, footer: footer, zoom: zoomSpace)
                } else {
                    LibraryTable(rows: rows, controller: controller, footer: footer)
                }
            }
        case .loading where library.viewMode == .mosaic:
            LibraryMosaic(rows: [], controller: controller, tier: tier, footer: .none, skeleton: true)
        default:
            LibraryPlaceholder(phase: phase, controller: controller)
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) { LibraryViewSwitcher(library: library) }
        #else
        ToolbarItem(placement: .navigation) { LibraryViewSwitcher(library: library) }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            LibrarySortMenu(library: library)
            #if os(macOS)
            Button(Copy.Library2.refresh, systemImage: Symbol.Library.refresh) { Task { await controller.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .help(Copy.Library2.refresh)
            #endif
            PasteFileButtons(showsFile: model.capabilities.showsFileButton)
            if tier != .compact {
                Button(Copy.Library2.toggleDetail, systemImage: Symbol.Library.inspector) {
                    controller.inspectorOpen.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(Copy.Library2.toggleDetail)
            }
        }
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

    @ViewBuilder
    private var loadingAllLine: some View {
        if let progress = library.loadingAll {
            LibraryLoadingLine(loaded: progress.loaded, total: progress.total)
        }
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { controller.deleting != nil }, set: { if !$0 { controller.deleting = nil } })
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

/// The quiet line above the results while the whole library loads: `loading the whole library · 60 of 140`.
struct LibraryLoadingLine: View {
    let loaded: Int
    let total: Int

    var body: some View {
        Text(Copy.Library2.loadingAll(loaded, of: total))
            .font(CobaltType.captionSmall)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.bar)
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
                case .failed:
                    LibraryProblem(state: .failed) { Task { await controller.refresh() } }
                case .loading:
                    LibraryProblem(state: .loading) {}
                case .empty, .rows:
                    LibraryProblem(state: .empty) {}
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
        .refreshable { await controller.refresh() }
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
