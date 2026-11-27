import CobaltKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

extension AppModel {
    /// The focused pipeline can take a new input (nothing is mid-flight on it). Only the Photos picker still asks:
    /// it resets the focused pipeline before it copies the picked item. A paste, a drop and a file never ask (a new
    /// input goes alongside: CONTRACT-PARALLEL 5.5).
    var pipelineIsFree: Bool {
        switch pipeline.state {
        case .idle, .done, .failed, .savedLocally, .image: return true
        default: return false
        }
    }

    /// The file circle's picker, a file from Photos, a file pasted or dropped: one upload job. Never refused because
    /// something else runs; it takes the focus only on a quiet screen (`JobQueue.add`, CONTRACT-PARALLEL 5.1).
    /// Each upload gets a randomly generated capybara-themed title right away so nothing prompts for a filename.
    @discardableResult
    func importFile(_ url: URL, photosAssetID: String? = nil, via: JobVia = .circle) -> Job? {
        selectedTab = .save
        return queue.add(
            [.file(url, photosAssetID: photosAssetID)],
            via: via,
            options: JobOptions(title: CapybaraUploadNames.random())
        ).first
    }

    var visibleTabs: [AppTab] {
        AppTab.allCases.filter { $0.isAvailable(with: capabilities) }
    }
}

/// The native shell. iPhone and iPad: a `TabView` with the iOS 18 `Tab` API in `.sidebarAdaptable`
/// style (a tab bar when compact, the system sidebar when regular, which the owner can collapse).
/// Mac: a `NavigationSplitView` whose sidebar is a `List(selection:)` of save and library; settings
/// live in the `Settings` scene (⌘,). The shell only measures its width (for the home layout's tier)
/// and owns the file importer, the drop target and the shortcuts.
struct AppShell: View {
    @Bindable var model: AppModel

    @State private var showImporter = false
    @State private var showPhotos = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoImport = PhotoImport()
    @State private var dropTargeted = false
    /// Two or more links pasted or dropped: the review sheet (CONTRACT-PARALLEL 4.5).
    @State private var review: PasteReviewRequest?
    @State private var width: CGFloat = 0
    /// The window's screen pane (apple/CONTRACT-PANE.md): one per scene, drawn by `PaneHost` around the tabs.
    @State private var pane = Pane()
    /// What a screen that has just popped left to say ("deleted."), drawn over the shell for a moment.
    @State private var status: String?
    @State private var statusToken = 0
    @State private var actionsBox = ShellActionsBox()
    /// A status line with an action ("link updated" · "undo"); it takes the place of `status` while it shows.
    @State private var note: StatusNote?
    #if DEBUG
    /// `-previewDetail N`: opens the Nth stored media's detail over the shell (simulator evidence).
    @State private var debugDetail: MediaItem?
    #endif
    @Environment(\.lifecycle) private var lifecycle
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Until the first measurement the size class stands in, so an iPad or a Mac window never draws one compact frame
    /// (which tore the library down and rebuilt it, its toolbar disappearing and coming back at launch).
    private var tier: Tier {
        if width > 0 { return Tier(width: width) }
        #if os(macOS)
        return .regular
        #else
        return sizeClass == .regular ? .regular : .compact
        #endif
    }

    /// The tier of one column: the room the tab keeps beside the screen pane (a screen laid out for the whole width in
    /// half of it opened the library's inspector over its own grid), else the window's. The pane measures its own host,
    /// so on the Mac this is the detail area less the column, not the window less it (the sidebar is not the tab's).
    private var columnTier: Tier {
        if let tabWidth = pane.tabWidth { return Tier(width: tabWidth) }
        return tier
    }

    /// Where the status notice sits: on the hinge of two screens, between them, instead of over either; else at the bottom.
    private var noticeAlignment: Alignment {
        if case .twoScreens = pane.placement { return .center }
        return .bottom
    }

    /// The photo picker: the system sheet.
    private func choosePhotos() {
        showPhotos = true
    }

    var body: some View {
        gatedNavigation
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // a tab laid out for a new tier while on screen (the pane beside it opening or closing, a fold, a rotation):
            // the library measures its own width and reports itself
            .onChange(of: columnTier) { old, new in
                guard Analytics.currentScreen != "library" else { return }
                LayoutSwap.report(screen: Analytics.currentScreen, from: old, to: new, width: pane.tabWidth ?? width, pane: pane)
            }
            .modifier(EditorPresenter(model: model))
            .cobaltRoot(model: model)
            .environment(\.shell, actions)
            .environment(\.photoImport, photoImport)
            .environment(pane)
            .overlay { if dropTargeted { dropHighlight } }
            #if os(iOS)
            .background { KeyboardShelfPublisher(store: model.store) }
            .modifier(AlertsPromptPresenter(model: model, blocked: review != nil))
            #endif
            .overlay(alignment: noticeAlignment) {
                if let note {
                    StatusToast(text: note.text, detail: note.detail, actionTitle: note.actionTitle) {
                        let action = note.action
                        self.note = nil
                        action?()
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if let status {
                    StatusToast(text: status)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Motion.card, value: status)
            .animation(Motion.card, value: note)
            // files, web links and text on the whole window (CONTRACT-PARALLEL 4.6): a drop is a paste
            .dropDestination(for: PastedContent.self) { items, _ in
                handle(items, via: .drop, dropped: true)
                return true
            } isTargeted: { dropTargeted = $0 }
            // ⌘V and Edit > Paste anywhere in the window; a text field that has the focus takes them first
            .modifier(PasteAnywhere { handle($0, via: .paste, dropped: false) })
            #if os(macOS)
            .modifier(MacShellLifecycle(model: model) { handle(Pasteboard.contents(), via: .paste, dropped: false) })
            #endif
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .image, .gif, .webP]) { result in
                if case .success(let url) = result { intake(url) }
            }
            // single selection, the original as stored (a HEVC video or a HEIC photo is not transcoded);
            // the system picker needs no photo-library permission
            .photosPicker(
                isPresented: $showPhotos, selection: $pickedPhoto, matching: .any(of: [.videos, .images]),
                preferredItemEncoding: .current,
                // `.shared()` gives each item its PHAsset id, so a picked video joins the cobalt album as
                // itself instead of a second copy (PhotosSync.adoptExistingAsset). Still no library permission.
                photoLibrary: .shared())
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                // the picker's asset id rides with the file, so the upload joins the cobalt album as that asset
                photoImport.load(item, into: model) { [id = item.itemIdentifier] in intake($0, photosAssetID: id) }
            }
            // the shell's own sheets wear `coversPane`: a pane opened under one waits for it to go (one narrow screen)
            .sheet(item: $review) { request in
                PasteReviewSheet(request: request) {
                    finishReview(request, saving: [])
                } save: { urls in
                    finishReview(request, saving: urls)
                }
                .cobaltRoot(model: model)
                .coversPane(pane)
            }
            // deep links and Shortcuts that open a single item (`AppModel.openInPane`): this window's pane opens it
            .onChange(of: model.paneRequest, initial: true) { _, request in
                guard request != nil, let item = model.takePaneRequest() else { return }
                pane.open(item)
            }
            .onAppear { consumeMenuBarHandoff() }
            .onChange(of: MenuBarHandoff.shared.token) { _, _ in consumeMenuBarHandoff() }
            .background { shortcuts }
            #if DEBUG
            .onAppear {
                if let n = UserDefaults.standard.string(forKey: "previewDetail").flatMap(Int.init), model.store.media.indices.contains(n) {
                    debugDetail = model.mediaItem(for: model.store.media[n])
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $debugDetail) { item in
                NavigationStack {
                    Group {
                        if let padded = DetailDebug.padded(item) {
                            MediaDetail(preview: model, item: padded, initial: DetailDebug.initial(padded))
                        } else {
                            MediaDetail(model: model, item: item, initial: DetailDebug.initial(item))
                        }
                    }
                    .sheetClose { debugDetail = nil }
                }
                .cobaltRoot(model: model)
                .transformEnvironment(\.dynamicTypeSize) { if DetailDebug.ax5 { $0 = .accessibility5 } }
                .environment(\.shell, actions)
                .coversPane(pane)
            }
            #else
            .sheet(item: $debugDetail) { item in
                NavigationStack {
                    MediaDetail(model: model, item: item, initial: DetailDebug.initial(item))
                        .sheetClose { debugDetail = nil }
                }
                .modifier(MacSheetSize())
            }
            #endif
            #endif
            .task {
                #if DEBUG
                DebugHooks.log("AppShell .task")
                #endif
                #if os(iOS)
                TouchProbe.install()                         // also feeds the frame monitor its touches
                #else
                FrameMonitor.install()
                #endif
                model.warmLibraryRows()                      // the library's rows are built off the main thread from the start
                await model.foreground()
                // the "swarms" badge: what waits for the owner is known before the tab is opened
                if model.visibleTabs.contains(.swarms) { await model.swarms.loadList() }
            }
            // Only this window's own UI here. What the whole app does on leaving and coming back (the line's summary
            // opt-in, the queue tab's polling, the server check and pickup, the swarms badge, preview frames) is done by
            // the process objects themselves, through `AppLifecycle` (`AppModel.observeLifecycle`).
            .onChange(of: lifecycle.phase) { _, phase in
                #if DEBUG
                DebugHooks.log("lifecycle \(phase.rawValue)")
                #endif
                #if os(iOS)
                // where taps really land (the library freeze hunt, owner 2026-11-14)
                if phase == .active { TouchProbe.install() }
                #endif
            }
    }

    // MARK: paste, drop and file intake

    /// What was pasted (⌘V, Edit > Paste, the paste circle, the menu bar) or dropped. Files are uploads, web links
    /// and text are read for links; nothing here is ever silent (CONTRACT-PARALLEL 4). The decision is `PasteRouter`,
    /// which the menu bar uses too.
    private func handle(_ items: [PastedContent], via: JobVia, dropped: Bool) {
        apply(PasteRouter.perform(items, via: via, dropped: dropped, model: model), via: via)
    }

    private func apply(_ effect: PasteRouter.Effect, via: JobVia) {
        switch effect {
        case .status(let text):
            showStatus(text)
        case .queued(let message, _):
            if let message { showStatus(message) }
        case .review(let request):
            review = request
        }
    }

    /// The review's end: "save N" sends the ticked links to the line at once, "cancel" sends nothing.
    private func finishReview(_ request: PasteReviewRequest, saving urls: [URL]) {
        review = nil
        let duplicates = request.rows.filter { $0.status != .new }.count
        PasteRouter.log(via: .review, found: request.found, kept: urls.count, duplicates: duplicates, model: model)
        guard !urls.isEmpty else { return }
        if case .queued(let message, _) = PasteRouter.commitLinks(urls, via: .review, model: model), let message {
            showStatus(message)
        }
    }

    /// Files from the picker, Photos, a paste and a drop upload immediately with a randomly generated
    /// capybara-themed title (`importFile`) — no filename prompt blocks the upload.
    private func intake(_ url: URL, photosAssetID: String? = nil, via: JobVia = .circle) {
        model.importFile(url, photosAssetID: photosAssetID, via: via)
    }

    /// A paste the menu bar handed over, or a job it started that now needs a choice. The window may not have
    /// existed when the menu bar staged it, so both appear and a later change take the one pending request.
    private func consumeMenuBarHandoff() {
        guard let request = MenuBarHandoff.shared.take() else { return }
        if let id = request.focus {
            guard model.queue.job(id) != nil else { return }
            model.queue.focus(id)
            model.selectedTab = .save
            return
        }
        handle(request.items, via: .paste, dropped: false)
    }

    // MARK: navigation

    /// Accounts (APP-API-CONTRACT 42.6): with no token on a device that never signed in, the sign-in screen stands in for
    /// the shell. Otherwise the shell, with "sign in again" pinned while signed out (floating on iPhone and iPad, in the
    /// window toolbar on the Mac) and the move-over offered once to a device with a pasted key.
    @ViewBuilder
    private var gatedNavigation: some View {
        if model.needsFirstSignIn {
            SignInScreen(model: model)
                .transition(.opacity)
        } else {
            navigation
                #if os(iOS)
                .modifier(SignInAgainPin(model: model))
                #else
                .toolbar {
                    if model.signInPinned {
                        ToolbarItem(placement: .primaryAction) { SignInAgainButton(model: model) }
                    }
                }
                #endif
                .modifier(MoveOverPresenter(model: model))
                // PostHog (APP-API-CONTRACT 58): each tab the owner opens is a `$screen`, so a replay reads by tab
                .onChange(of: model.selectedTab, initial: true) {
                    Analytics.screen(model.selectedTab.rawValue)
                    Breadcrumbs.add("tab.\(model.selectedTab.rawValue)")
                }
        }
    }

    @ViewBuilder
    private var navigation: some View {
        #if os(iOS)
        // the screen pane wraps the tab views, so it is one per window and switching tabs keeps it (a stream plays on)
        PaneHost(model: model, dragging: dropTargeted) {
            iosTabs
        }
        .sheet(isPresented: $model.queueShown) { queueSheet }
        .modifier(QueueTabRedirect(model: model))
        #else
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(model.visibleTabs.filter { $0 != .settings }, id: \.self) { tab in
                    Label(Copy.tab(tab), systemImage: icon(for: tab))
                        .font(Font.cobalt(13, .regular, relativeTo: .body))
                        .badge(tab == .queue ? model.activity.activeCount : tab == .swarms ? model.swarms.waitingCount : 0)
                        .tag(tab)
                }
            }
            .tint(CobaltColor.text)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            // the screen pane: a 400 pt column after the sidebar, the whole detail area spanned, the bar at its bottom
            PaneHost(model: model, dragging: dropTargeted) {
                Group {
                    let tier = columnTier
                    switch model.selectedTab {
                    case .save, .tools: HomeScreen(model: model, tier: tier)
                    case .library: LibraryScreen(model: model, tier: tier)
                    case .links: NavigationStack { LinksScreen(model: model) }
                    case .chat: NavigationStack { ChatScreen(model: model, tier: tier) }
                    case .swarms: NavigationStack { SwarmsScreen(model: model, tier: tier) }
                    case .stage: NavigationStack { StageScreen(model: model, tier: tier) }
                    case .sevenTv: NavigationStack { SevenTvScreen(model: model, tier: tier) }
                    case .twitch: NavigationStack { TwitchScreen(model: model, tier: tier) }
                    case .booru: NavigationStack { BooruScreen(model: model, tier: tier) }
                    case .names: NavigationStack { NamesScreen(model: model) }
                    case .queue: NavigationStack { QueueScreen(model: model) }
                    case .settings: SettingsScreen(model: model)
                    }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    /// Wide regular canvases (iPad landscape >= 1000 pt) have a real sidebar for `.sidebarOnly` sections;
    /// narrower regular widths (iPhone Duo portrait 669 pt / landscape 951 pt, iPad portrait) use the
    /// floating tab bar / vertical controls rail, where `.sidebarOnly` tabs would flatten into an 8-item bar.
    private var showsSidebarSection: Bool { width >= 1000 }

    /// The iPhone's and the iPad's tab views (inside `PaneHost`). The bar of a running pane item is the tab view's bottom
    /// accessory (`PaneBarAccessory`).
    @ViewBuilder
    private var iosTabs: some View {
        if sizeClass == .compact {
            // Compact width (iPhone, Duo Outer, narrow Split View): four tabs, no "more" (see `PhoneTabs`)
            PhoneTabs(model: model) { tab in
                tabScreen(tab)
            }
        } else if showsSidebarSection {
            let primary = regularPrimaryTabs
            let secondary = regularSecondaryTabs
            TabView(selection: $model.selectedTab) {
                ForEach(primary, id: \.self) { tab in
                    Tab(Copy.tab(tab), systemImage: icon(for: tab), value: tab) {
                        tabRoot(tab)
                    }
                }

                if !secondary.isEmpty {
                    Tab(Copy.tab(.tools), systemImage: icon(for: .tools), value: AppTab.tools) {
                        NavigationStack {
                            RegularToolsHub(model: model, tabs: secondary) { tab in
                                model.selectedTab = tab
                            }
                        }
                    }
                    .badge(model.swarms.waitingCount)

                    TabSection(Copy.PhoneNav.tools) {
                        ForEach(secondary, id: \.self) { tab in
                            Tab(Copy.tab(tab), systemImage: icon(for: tab), value: tab) {
                                tabRoot(tab)
                            }
                            .badge(tab == .swarms ? model.swarms.waitingCount : 0)
                        }
                    }
                    .tabPlacement(.sidebarOnly)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .modifier(PaneBarAccessory(model: model))
        } else {
            // Regular width without a sidebar (iPhone Duo unfolded portrait/landscape, narrow iPad):
            // strictly 4 top-level tabs matching PhoneTabs (Save, Library, Live, Tools) on the vertical rail.
            RegularFourTabs(model: model) { tab in
                tabScreen(tab)
            }
        }
    }

    /// The primary top-level tabs shown directly in the bar / Duo Vertical Controls rail (at most 3 + Tools = 4).
    private var regularPrimaryTabs: [AppTab] {
        let visible = model.visibleTabs.filter { $0 != .queue && $0 != .tools }
        var primary: [AppTab] = []
        for candidate in [AppTab.save, .library] where visible.contains(candidate) {
            primary.append(candidate)
        }
        if let live = [AppTab.twitch, .stage, .sevenTv].first(where: { visible.contains($0) }) {
            primary.append(live)
        }
        return primary
    }

    /// Secondary workspaces tucked into the sidebar section and reachable in one tap from `RegularToolsHub`.
    private var regularSecondaryTabs: [AppTab] {
        let primary = Set(regularPrimaryTabs)
        return model.visibleTabs.filter { $0 != .queue && $0 != .tools && !primary.contains($0) }
    }
    #endif

    #if os(iOS)
    /// A tab's screen with no navigation stack around it.
    @ViewBuilder
    private func tabScreen(_ tab: AppTab, tier: Tier? = nil) -> some View {
        let tier = tier ?? columnTier
        switch tab {
        case .save: HomeScreen(model: model, tier: tier)
        // the screen brings its own navigation stack, so a width change (a rotation, a split view) never replaces it and its
        // selection, scroll and controller survive
        case .library: LibraryScreen(model: model, tier: tier)
        case .links: LinksScreen(model: model)
        case .chat: ChatScreen(model: model, tier: tier)
        case .swarms: SwarmsScreen(model: model, tier: tier)
        case .stage: StageScreen(model: model, tier: tier)
        case .sevenTv: SevenTvScreen(model: model, tier: tier)
        case .twitch: TwitchScreen(model: model, tier: tier)
        case .booru: BooruScreen(model: model, tier: tier)
        case .names: NamesScreen(model: model)
        case .queue: QueueScreen(model: model)
        case .settings: SettingsScreen(model: model)
        // never asked for here: the iPhone's tools list is `ToolsScreen`, built by `PhoneTabs`
        case .tools: ToolsScreen(model: model)
        }
    }

    /// A tab's screen in the stack of its own (the iPad's tabs).
    @ViewBuilder
    private func tabRoot(_ tab: AppTab, tier: Tier? = nil) -> some View {
        if tab == .library {
            tabScreen(tab, tier: tier)
        } else {
            NavigationStack { tabScreen(tab, tier: tier) }
        }
    }

    #endif

    #if os(iOS)
    /// The activity and health sheet on iPhone and iPad (apple 03-PHASE3 3.4.2): the whole screen in a large sheet, closed with the
    /// x like the other sheets. The activity segment is the queue (`model.activity`), the system segment the health inspector.
    private var queueSheet: some View {
        NavigationStack {
            ActivityAndHealthSheet(model: model)
                .sheetCorner()
                .sheetClose { model.queueShown = false }
        }
        .presentationDetents([.large])
        .cobaltRoot(model: model)
        .environment(\.shell, actions)
        // a job opened from here closes the queue first: the pane sheet waits for this one to finish going
        .coversPane(pane)
    }
    #endif

    #if os(macOS)
    private var sidebarSelection: Binding<AppTab?> {
        Binding(
            get: { model.selectedTab == .settings ? nil : model.selectedTab },
            set: { if let tab = $0 { model.selectedTab = tab } })
    }
    #endif

    /// Built once and kept (the closures write through @State and the model, so the first copy stays right).
    private var actions: ShellActions {
        if let made = actionsBox.value, actionsBox.model === model { return made }
        var made = makeActions()
        actionsBox.generation += 1
        made.generation = actionsBox.generation
        actionsBox.value = made
        actionsBox.model = model
        return made
    }

    private func makeActions() -> ShellActions {
        ShellActions(
            paste: { Task { handle(await Pasteboard.contentsOffMain(), via: .circle, dropped: false) } },
            chooseFile: { showImporter = true },
            choosePhotos: { choosePhotos() },
            trimNewWebp: { post in
                TrimIntent.request()
                Task { await model.trimNewWebp(from: post) }
            },
            makeWebp: { item in
                #if DEBUG
                DebugHooks.log("shell.makeWebp \(item.id) post=\(item.post?.id ?? "-") local=\(item.local?.id ?? "-")")
                #endif
                TrimIntent.request()
                Task { await model.makeWebp(for: item) }
            },
            showStatus: { text in showStatus(text) },
            showNote: { note in showNote(note) },
            openSettings: {
                #if os(macOS)
                openSettings()
                #else
                model.selectedTab = .settings
                #endif
            },
            recheckServer: { Task { await model.refreshServer() } })
    }

    /// A line over the shell for a few seconds; a longer one stays longer. VoiceOver hears it, since the screen it
    /// described is gone.
    private func showStatus(_ text: String) {
        statusToken += 1
        let token = statusToken
        note = nil
        status = text
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(text.count > 40 ? 6 : 2.4))
            if statusToken == token { status = nil }
        }
    }

    /// A line with an action, over the shell for five seconds (a plain status after it replaces it).
    private func showNote(_ next: StatusNote) {
        statusToken += 1
        let token = statusToken
        status = nil
        note = next
        AccessibilityNotification.Announcement([next.text, next.detail].compactMap { $0 }.joined(separator: " ")).post()
        Task {
            try? await Task.sleep(for: .seconds(5))
            if statusToken == token { note = nil }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(CobaltColor.focus, lineWidth: 2)
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// ⌘T trims on an iPad with a keyboard (the Mac's lives in the menus). ⌘V on an iPad is the system's: the shell is a
    /// paste destination (`PasteAnywhere`); only before iOS 27, which has no `pasteDestination`, a hidden button keeps
    /// the shortcut and reads the pasteboard when it is pressed.
    @ViewBuilder
    private var shortcuts: some View {
        #if os(iOS)
        VStack {
            if #unavailable(iOS 27.0) {
                Button(Copy.pasteA11y, systemImage: Symbol.paste) { Task { handle(await Pasteboard.contentsOffMain(), via: .paste, dropped: false) } }
                    .keyboardShortcut("v", modifiers: .command)
            }
            Button(Copy.trimNewWebp, systemImage: Symbol.trim) { trimSelected(model) }.keyboardShortcut("t", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        #endif
    }
}

/// Holds the shell's actions once made (not observed: writing it never re-runs a body).
@MainActor
private final class ShellActionsBox {
    var value: ShellActions?
    /// The model the actions were made for (a new one, and they are made again).
    weak var model: AppModel?
    var generation = 0
}

#if os(iOS)
/// Anything that still selects the queue tab (a launch argument, a preview) opens the sheet instead.
/// Its own modifier, so the tab is read here and not in the shell's body.
private struct QueueTabRedirect: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.onChange(of: model.selectedTab, initial: true) { _, tab in
            guard tab == .queue else { return }
            model.selectedTab = .save
            model.queueShown = true
        }
    }
}

/// Regular-width four-tab shell for non-sidebar canvases (iPhone Duo unfolded portrait 669 pt & landscape 951 pt,
/// narrow iPad). Mirrors the compact 4-tab vertical rail (Save, Library, Live, Tools) with consistent
/// `PhoneRootToolbar` (Activity pill + Settings gear), unified `CobaltSettingsSheet`, and fold-safe 2-column
/// `RegularToolsHub` so folding/unfolding an iPhone Duo keeps the exact same 4 tabs and navigation rhythm.
private struct RegularFourTabs<Screen: View>: View {
    let model: AppModel
    @ViewBuilder let screen: (AppTab) -> Screen

    @State private var nav: PhoneNavState
    @State private var toolsPath: [AppTab]
    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?

    init(
        model: AppModel,
        @ViewBuilder screen: @escaping (AppTab) -> Screen
    ) {
        self.model = model
        self.screen = screen
        let nav = PhoneNavState()
        let initial = model.selectedTab
        let liveTabs: Set<AppTab> = [.stage, .twitch, .sevenTv]
        if initial == .save {
            nav.slot = .capture
            _toolsPath = State(initialValue: [])
        } else if initial == .library {
            nav.slot = .library
            _toolsPath = State(initialValue: [])
        } else if liveTabs.contains(initial) {
            nav.slot = .live
            if let segment = LiveSegment(tab: initial) { nav.live = segment }
            _toolsPath = State(initialValue: [])
        } else if initial == .settings {
            nav.slot = .capture
            nav.settingsShown = true
            _toolsPath = State(initialValue: [])
        } else if initial == .tools {
            nav.slot = .tools
            _toolsPath = State(initialValue: [])
        } else if initial != .queue {
            nav.slot = .tools
            _toolsPath = State(initialValue: [initial])
        } else {
            nav.slot = .capture
            _toolsPath = State(initialValue: [])
        }
        _nav = State(initialValue: nav)
    }

    private var hasLiveTab: Bool {
        LiveSegment.allCases.contains { $0.tab.isAvailable(with: model.capabilities) }
    }

    /// Secondary workspaces tucked into `RegularToolsHub` (Save, Library, Live segments, Queue, and Settings sheet excluded).
    private var toolsTabs: [AppTab] {
        let excluded: Set<AppTab> = [.save, .library, .stage, .twitch, .sevenTv, .queue, .tools, .settings]
        return model.visibleTabs.filter { !excluded.contains($0) }
    }

    private var slots: [PhoneSlot] {
        var list: [PhoneSlot] = [.capture]
        if AppTab.library.isAvailable(with: model.capabilities) { list.append(.library) }
        if hasLiveTab { list.append(.live) }
        if !toolsTabs.isEmpty { list.append(.tools) }
        return list
    }

    private var activeTab: AppTab {
        switch nav.slot {
        case .capture: return .save
        case .library: return .library
        case .live: return nav.live.tab
        case .tools: return toolsPath.last ?? .tools
        }
    }

    var body: some View {
        @Bindable var nav = nav
        TabView(selection: $nav.slot) {
            ForEach(slots, id: \.self) { slot in
                Tab(slot.title, systemImage: slot.symbol, value: slot) {
                    root(slot)
                }
                .badge(slot == .tools ? model.swarms.waitingCount : 0)
            }
        }
        .environment(nav)
        .modifier(PaneBarAccessory(model: model))
        .sheet(isPresented: $nav.settingsShown) {
            CobaltSettingsSheet(model: model, shell: shell, pane: pane) {
                nav.settingsShown = false
            }
        }
        .onChange(of: activeTab, initial: true) { _, active in
            if model.selectedTab != active { model.selectedTab = active }
        }
        .onChange(of: model.tabSets) { _, _ in
            follow(model.selectedTab)
        }
        .onChange(of: model.capabilities) { _, _ in
            if !slots.contains(nav.slot) { nav.slot = .capture }
            if nav.slot == .tools, let top = toolsPath.last, !toolsTabs.contains(top) { toolsPath = [] }
        }
    }

    @ViewBuilder
    private func root(_ slot: PhoneSlot) -> some View {
        switch slot {
        case .capture:
            NavigationStack {
                screen(.save)
                    .environment(\.phoneHeaderOwnsActivity, true)
                    .toolbar { PhoneRootToolbar(model: model) }
            }
        case .library:
            // LibraryScreen brings its own NavigationStack and pushes MediaDetail inside it so the Duo rail stays visible.
            screen(.library)
        case .live:
            NavigationStack {
                LiveScreen(model: model) { segment in screen(segment.tab) }
            }
        case .tools:
            NavigationStack(path: $toolsPath) {
                RegularToolsHub(model: model, tabs: toolsTabs) { tab in
                    toolsPath.append(tab)
                }
                .navigationDestination(for: AppTab.self) { tab in
                    screen(tab)
                }
            }
        }
    }

    private func follow(_ tab: AppTab) {
        guard tab != .queue, tab != activeTab || tab == .settings else { return }
        switch tab {
        case .save:
            nav.slot = .capture
        case .library:
            nav.slot = .library
        case .stage, .twitch, .sevenTv:
            nav.slot = .live
            if let segment = LiveSegment(tab: tab) { nav.live = segment }
        case .settings:
            nav.settingsShown = true
            if model.selectedTab != activeTab { model.selectedTab = activeTab }
        case .tools:
            nav.slot = .tools
            if !toolsPath.isEmpty { toolsPath = [] }
        default:
            if toolsTabs.contains(tab) {
                nav.slot = .tools
                if toolsPath != [tab] { toolsPath = [tab] }
            }
        }
    }
}

/// Clean fold-safe hub for secondary workspaces on iOS `.regular` (iPhone Duo unfolded & iPad),
/// keeping the top-level tab bar / Duo Vertical Controls rail crisp at 4 items.
private struct RegularToolsHub: View {
    let model: AppModel
    let tabs: [AppTab]
    let onSelect: (AppTab) -> Void
    @Environment(PhoneNavState.self) private var phoneNav: PhoneNavState?
    @Environment(\.shell) private var shell

    var body: some View {
        ScrollView {
            DuoAdaptiveGrid(minItemWidth: 220, spacing: 12, minColumns: 2) {
                ForEach(tabs, id: \.self) { tab in
                    hubCard(for: tab)
                }
            }
            .padding(16)
        }
        .background(CobaltColor.bg.ignoresSafeArea())
        .navigationTitle(Copy.PhoneNav.tools)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if phoneNav != nil {
                PhoneRootToolbar(model: model) {
                    Menu {
                        Button(Copy.pasteA11y, systemImage: Symbol.paste) { shell.paste() }
                        if model.capabilities.showsFileButton {
                            Button(Copy.sourcePhotos, systemImage: Symbol.sourcePhotos) { shell.choosePhotos() }
                            Button(Copy.sourceFiles, systemImage: Symbol.sourceFiles) { shell.chooseFile() }
                        }
                    } label: {
                        Label(Copy.pasteA11y, systemImage: "plus").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("duo.quickAdd")
                }
            } else {
                QueueToolbarItem(model: model)
            }
        }
    }

    private func hubCard(for tab: AppTab) -> some View {
        let waiting = tab == .swarms ? model.swarms.waitingCount : 0
        let detail = detailText(for: tab)
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            onSelect(tab)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: tab))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CobaltColor.text)
                    .frame(width: 36, height: 36)
                    .background(
                        Color(light: 0x000000, dark: 0xffffff).opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.tab(tab))
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if waiting > 0 {
                    Text("\(waiting)")
                        .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(CobaltColor.linkBlue, in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption.opacity(0.75))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: max(62, Metrics.hit), alignment: .leading)
            .background(Color(light: 0x000000, dark: 0xffffff).opacity(0.045), in: cardShape)
            .overlay(
                cardShape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(light: 0x000000, dark: 0xffffff).opacity(0.09),
                            Color(light: 0x000000, dark: 0xffffff).opacity(0.02),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            )
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tools.hub.\(tab.rawValue)")
    }

    private func detailText(for tab: AppTab) -> String? {
        switch tab {
        case .links: return Copy.PhoneNav.toolsLinksNote
        case .chat, .swarms: return Copy.PhoneNav.toolsAssistantsNote
        case .booru: return Copy.PhoneNav.toolsBooruNote
        case .names: return Copy.PhoneNav.toolsNamesNote
        default: return nil
        }
    }
}
#endif

/// ⌘V and Edit > Paste anywhere in the window (CONTRACT-PARALLEL 4.1): the content is a paste destination, so a text
/// field that has the focus takes ⌘V itself and the shell sees only the pastes nothing else
/// wants. Replaces the old global menu command, which bound ⌘V even over a text field.
private struct PasteAnywhere: ViewModifier {
    let received: @MainActor ([PastedContent]) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.0, macOS 13.0, *) {
            content.pasteDestination(for: PastedContent.self) { received($0) }
        } else {
            content
        }
    }
}

#if os(macOS)
/// What the Mac window needs from the app as a whole: ⌘V when no view of the window has the focus to receive a paste
/// command, the Dock's badge, and one summary opt-in when the window closes or the app quits with work on the server.
private struct MacShellLifecycle: ViewModifier {
    let model: AppModel
    /// ⌘V reached the window with no text field to take it: a paste, like Edit > Paste.
    let paste: @MainActor () -> Void
    @State private var window = WindowBox()

    func body(content: Content) -> some View {
        content
            // kept when the view leaves its window: the close notification arrives while the window is still going
            .background(WindowReader { if let found = $0 { window.window = found } })
            .onAppear {
                window.installPasteKey(paste)
                CobaltAppDelegate.onQuit = { [model] in await leave(model) }
            }
            .onDisappear { window.removePasteKey() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                // the main window going (not a sheet, not Settings): the owner has left cobalt
                if let closing = note.object as? NSWindow, closing === window.window { model.queue.appLeft() }
            }
    }
}

/// Quitting with work on the server: the summary opt-in goes out first, bounded, so the process does not exit under it.
@MainActor
private func leave(_ model: AppModel) async {
    guard model.queue.live.contains(where: { $0.pipeline.sessionID != nil }) else { return }
    model.queue.appLeft()
    try? await Task.sleep(for: .milliseconds(1200))
}

/// The main window and the ⌘V key monitor. The monitor sees ⌘V before the menu does and takes it only in this window,
/// with no sheet over it and no text field (or any text view) holding the first responder.
@MainActor
private final class WindowBox {
    weak var window: NSWindow?
    private var monitor: Any?

    func installPasteKey(_ paste: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let take = MainActor.assumeIsolated { self?.takes(event) ?? false }
            guard take else { return event }
            MainActor.assumeIsolated { paste() }
            return nil
        }
    }

    func removePasteKey() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func takes(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command,   // Caps Lock is on and ⌘V is still paste
              event.charactersIgnoringModifiers?.lowercased() == "v"
        else { return false }
        if let responder = window.firstResponder, responder is NSText || responder is NSTextInputClient { return false }
        return true
    }
}

/// Hands the hosting `NSWindow` to `onWindow` as soon as the view is in one (and `nil` when it leaves).
private struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { view.onWindow = onWindow }

    final class Probe: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            MainActor.assumeIsolated { onWindow?(window) }
        }
    }
}
#endif

/// The environment every scene shares: monochrome tint, Dynamic Type up to the accessibility sizes,
/// the haptics setting. The app's window and the Mac's Settings window both wear it.
extension View {
    func cobaltRoot(model: AppModel) -> some View {
        self
            .environment(\.hapticsEnabled, model.settings.haptics)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .tint(CobaltColor.text)
    }
}

/// ⌘T: trim a new webp from the library's selected post.
@MainActor
func trimSelected(_ model: AppModel) {
    let library = model.library
    guard model.selectedTab == .library,
          let post = library.posts.first(where: { $0.id == library.expandedPostID }) ?? library.posts.first
    else { return }
    TrimIntent.request()
    Task { await model.trimNewWebp(from: post) }
}

func icon(for tab: AppTab) -> String {
    switch tab {
    case .save: return Symbol.save
    case .library: return Symbol.library
    case .links: return Symbol.links
    case .chat: return Symbol.chat
    case .swarms: return Symbol.Swarms.tab
    case .stage: return Symbol.stage
    case .sevenTv: return Symbol.SevenTv.tab
    case .twitch: return Symbol.Twitch.tab
    case .booru: return Symbol.Booru.tab
    case .names: return Symbol.Names.menu
    case .queue: return Symbol.queue
    case .settings: return Symbol.settings
    case .tools: return Symbol.PhoneNav.tools
    }
}

#if DEBUG
/// The shell over `AppModel.previewQueue(.busy)`: two links waiting and downloads running, so the toolbar button
/// carries its badge; `sheet` opens the queue sheet over it (iPhone and iPad; the Mac has the tab).
private struct QueueShellPreview: View {
    @State private var model: AppModel

    init(sheet: Bool) {
        let model = AppModel.previewQueue(.busy)
        model.queueShown = sheet
        _model = State(initialValue: model)
    }

    var body: some View { AppShell(model: model) }
}

#Preview("shell · compact") {
    PreviewHost(.happy) { AppShell(model: $0) }
}
#Preview("shell · library tab") {
    PreviewHost(.happy, tab: .library) { AppShell(model: $0) }
}
#Preview("shell · links tab") {
    PreviewHost(.happy, tab: .links) { AppShell(model: $0) }
}
#Preview("shell · chat tab") {
    PreviewHost(.happy, tab: .chat) { AppShell(model: $0) }
}
#Preview("shell · studio tab") {
    PreviewHost(.happy, tab: .stage) { AppShell(model: $0) }
}
#Preview("shell · 7tv tab") {
    PreviewHost(.happy, tab: .sevenTv) { AppShell(model: $0) }
}
#Preview("shell · queue sheet") {
    PreviewHost(.happy, tab: .queue) { AppShell(model: $0) }
}
#Preview("shell · queue badge") {
    QueueShellPreview(sheet: false)
}
#Preview("shell · queue badge, sheet open") {
    QueueShellPreview(sheet: true)
}
#Preview("shell · settings tab") {
    PreviewHost(.happy, tab: .settings) { AppShell(model: $0) }
}
#Preview("shell · regular", traits: .fixedLayout(width: 820, height: 760)) {
    PreviewHost(.happy, script: .input) { AppShell(model: $0) }
}
#Preview("shell · wide", traits: .fixedLayout(width: 1280, height: 780)) {
    PreviewHost(.happy, script: .input) { AppShell(model: $0) }
}
#Preview("shell · wide library", traits: .fixedLayout(width: 1280, height: 780)) {
    PreviewHost(.happy, tab: .library) { AppShell(model: $0) }
}
#endif
