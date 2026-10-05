import CobaltKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension AppModel {
    /// The pipeline can take a new input (nothing is mid-flight).
    var pipelineIsFree: Bool {
        switch pipeline.state {
        case .idle, .done, .failed, .savedLocally, .image: return true
        default: return false
        }
    }

    /// The paste circle, ⌘V and the library's toolbar button.
    func pasteFromClipboard() {
        guard pipelineIsFree else { return }
        selectedTab = .save
        pipeline.start(pastedText: Pasteboard.string())
    }

    /// The file circle's picker, and a file dropped on the window.
    func importFile(_ url: URL) {
        guard pipelineIsFree else { return }
        selectedTab = .save
        pipeline.start(file: url)
    }

    /// The title sheet for the file upload `importFile` just started (CONTRACT-LIBRARY2 decision 3): nil when no
    /// upload began (a refused or unreadable file) or when the server cannot keep a title (rename later is then
    /// this device only). The default is the file's name without its media extension, which for a Photos pick is
    /// `from photos · 4 oct`.
    var titleRequestForRun: TitleRequest? {
        guard capabilities.titles, case .uploading = pipeline.state, case .file(let name, _, _) = pipeline.input else { return nil }
        return TitleRequest(defaultTitle: MediaTitle.stripExtension(name))
    }

    var visibleTabs: [AppTab] {
        AppTab.allCases.filter { $0 != .library || capabilities.library }
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
    /// The `name it` sheet over the save tab while a picked file uploads.
    @State private var titleRequest: TitleRequest?
    @State private var width: CGFloat = 0
    /// What a screen that has just popped left to say ("deleted."), drawn over the shell for a moment.
    @State private var status: String?
    @State private var statusToken = 0
    #if DEBUG
    /// `-previewDetail N`: opens the Nth stored media's detail over the shell (simulator evidence).
    @State private var debugDetail: MediaItem?
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var tier: Tier { Tier(width: width) }

    var body: some View {
        navigation
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .cobaltRoot(model: model)
            .environment(\.shell, actions)
            .environment(\.photoImport, photoImport)
            .overlay { if dropTargeted { dropHighlight } }
            .overlay(alignment: .bottom) {
                if let status {
                    StatusToast(text: status)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Motion.card, value: status)
            .dropDestination(for: URL.self) { urls, _ in
                guard let file = urls.first(where: \.isFileURL) else { return false }
                intake(file)
                return true
            } isTargeted: { dropTargeted = $0 }
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
                photoImport.load(item, into: model) { intake($0) }
            }
            .sheet(item: $titleRequest) { request in
                TitleSheet(pipeline: model.pipeline, defaultTitle: request.defaultTitle) { titleRequest = nil }
                    .cobaltRoot(model: model)
            }
            .background { shortcuts }
            #if DEBUG
            .onAppear {
                if let kind = UserDefaults.standard.string(forKey: "previewTitleSheet") { debugTitleSheet(kind) }
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
                    .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { debugDetail = nil } } }
                }
                .cobaltRoot(model: model)
                .transformEnvironment(\.dynamicTypeSize) { if DetailDebug.ax5 { $0 = .accessibility5 } }
                .environment(\.shell, actions)
            }
            #else
            .sheet(item: $debugDetail) { item in
                NavigationStack { MediaDetail(model: model, item: item, initial: DetailDebug.initial(item)) }
                    .frame(minWidth: 900, minHeight: 640)
            }
            #endif
            #endif
            .task {
                #if DEBUG
                DebugHooks.log("AppShell .task")
                #endif
                await model.refreshServer()
                await model.pickUpSharedJobs()
            }
            .onChange(of: scenePhase) { _, phase in
                #if DEBUG
                DebugHooks.log("scenePhase \(String(describing: phase))")
                #endif
                guard phase == .active else { return }
                Task {
                    await model.pickUpSharedJobs()
                    await model.refreshServer()
                    await model.store.backfillPreviewFrames()
                }
            }
    }

    // MARK: file intake

    /// Files, a drop on the window and Photos all come through here: the upload starts first (`importFile`), then
    /// the title sheet rises over it (never in its way: the run does not wait for it). A beat later, so the
    /// picker that returned the file has finished leaving, and only if the run is still that upload.
    private func intake(_ url: URL) {
        let wasFree = model.pipelineIsFree
        model.importFile(url)
        guard wasFree, let request = model.titleRequestForRun else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if model.pipeline.state != .idle, case .file = model.pipeline.input { titleRequest = request }
        }
    }

    #if DEBUG
    /// `-previewTitleSheet files|photos|long` (simulator evidence, over a preview scenario): picks a file the way
    /// the importer would, so the upload starts and the `name it` sheet rises with that default.
    private func debugTitleSheet(_ kind: String) {
        let name = switch kind {
        case "photos": "from photos · 4 oct.mov"
        case "long": "the whole afternoon at the harbour, before the wind came up and everyone left.mov"
        default: "IMG_0412.mov"
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            intake(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name))
        }
    }
    #endif

    // MARK: navigation

    @ViewBuilder
    private var navigation: some View {
        #if os(iOS)
        TabView(selection: $model.selectedTab) {
            Tab(Copy.tab(.save), systemImage: icon(for: .save), value: AppTab.save) {
                NavigationStack { HomeScreen(model: model, tier: tier) }
            }
            if model.capabilities.library {
                Tab(Copy.tab(.library), systemImage: icon(for: .library), value: AppTab.library) {
                    // Regular widths bring their own split view (and its navigation bars).
                    if tier == .compact {
                        NavigationStack { LibraryScreen(model: model, tier: tier) }
                    } else {
                        LibraryScreen(model: model, tier: tier)
                    }
                }
            }
            Tab(Copy.tab(.settings), systemImage: icon(for: .settings), value: AppTab.settings) {
                NavigationStack { SettingsScreen(model: model) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // always expanded: a collapsed bar hid the other two tabs after any scroll (owner's live run)
        .tabBarMinimizeBehavior(.never)
        #else
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(model.visibleTabs.filter { $0 != .settings }, id: \.self) { tab in
                    Label(Copy.tab(tab), systemImage: icon(for: tab))
                        .font(Font.cobalt(13, .regular, relativeTo: .body))
                        .tag(tab)
                }
            }
            .tint(CobaltColor.text)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            switch model.selectedTab {
            case .save: HomeScreen(model: model, tier: tier)
            case .library: LibraryScreen(model: model, tier: tier)
            case .settings: SettingsScreen(model: model)
            }
        }
        #endif
    }

    #if os(macOS)
    private var sidebarSelection: Binding<AppTab?> {
        Binding(
            get: { model.selectedTab == .settings ? nil : model.selectedTab },
            set: { if let tab = $0 { model.selectedTab = tab } })
    }
    #endif

    private var actions: ShellActions {
        ShellActions(
            paste: { model.pasteFromClipboard() },
            chooseFile: { showImporter = true },
            choosePhotos: { showPhotos = true },
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
        status = text
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(text.count > 40 ? 6 : 2.4))
            if statusToken == token { status = nil }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(CobaltColor.focus, lineWidth: 2)
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// ⌘V pastes and ⌘T trims on an iPad with a keyboard; on the Mac the same two live in the menus.
    @ViewBuilder
    private var shortcuts: some View {
        #if os(iOS)
        VStack {
            Button(Copy.pasteA11y, systemImage: Symbol.paste) { model.pasteFromClipboard() }.keyboardShortcut("v", modifiers: .command)
            Button(Copy.trimNewWebp, systemImage: Symbol.trim) { trimSelected(model) }.keyboardShortcut("t", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        #endif
    }
}

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
    case .settings: return Symbol.settings
    }
}

#if DEBUG
#Preview("shell · compact") {
    PreviewHost(.happy) { AppShell(model: $0) }
}
#Preview("shell · library tab") {
    PreviewHost(.happy, tab: .library) { AppShell(model: $0) }
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
