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
    @discardableResult
    func importFile(_ url: URL, photosAssetID: String? = nil, via: JobVia = .circle) -> Job? {
        selectedTab = .save
        return queue.add([.file(url, photosAssetID: photosAssetID)], via: via).first
    }

    /// The title sheet for the file upload `importFile` just started (CONTRACT-LIBRARY2 decision 3): nil when no
    /// upload began (a refused or unreadable file) or when the server cannot keep a title (rename later is then
    /// this device only). The default is the file's name without its media extension, which for a Photos pick is
    /// `from photos · 4 oct`.
    func titleRequest(for pipeline: Pipeline) -> TitleRequest? {
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
    /// The `name it` sheet over the save tab while a picked file uploads, with the upload it names.
    @State private var titleSheet: TitleSheetRequest?
    /// Two or more links pasted or dropped: the review sheet (CONTRACT-PARALLEL 4.5).
    @State private var review: PasteReviewRequest?
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
            .sheet(item: $titleSheet) { sheet in
                TitleSheet(pipeline: sheet.pipeline, defaultTitle: sheet.request.defaultTitle) { titleSheet = nil }
                    .cobaltRoot(model: model)
            }
            .sheet(item: $review) { request in
                PasteReviewSheet(request: request) {
                    finishReview(request, saving: [])
                } save: { urls in
                    finishReview(request, saving: urls)
                }
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
                NavigationStack {
                    MediaDetail(model: model, item: item, initial: DetailDebug.initial(item))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton(cancels: true) { debugDetail = nil } } }
                }
                .modifier(MacSheetSize())
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
                // leaving with work on the server: one summary opt-in for all of it (CONTRACT-PARALLEL 6; idempotent)
                if phase == .background { model.queue.appLeft() }
                guard phase == .active else { return }
                Task {
                    await model.pickUpSharedJobs()
                    await model.refreshServer()
                    await model.store.backfillPreviewFrames()
                }
            }
    }

    // MARK: paste, drop and file intake

    /// What was pasted (⌘V, Edit > Paste, the paste circle) or dropped. Files are uploads, web links and text are read
    /// for links; nothing here is ever silent (CONTRACT-PARALLEL 4).
    private func handle(_ items: [PastedContent], via: JobVia, dropped: Bool) {
        let files = items.compactMap(\.fileURL)
        if !files.isEmpty {
            addFiles(files, via: via)
            return
        }
        let text = items.compactMap(\.text).joined(separator: "\n")
        let source: PasteReviewRequest.Source = dropped ? .dropped : .clipboard
        switch PasteIntake.outcome(for: text, source: source, model: model) {
        case .none:
            logPaste(via: via, found: 0, kept: 0, duplicates: 0)
            showStatus(dropped ? Copy.Jobs.nothingDropped : Copy.Jobs.noLink)
        case .duplicate:
            logPaste(via: via, found: 1, kept: 0, duplicates: 1)
            showStatus(Copy.Jobs.duplicate)
        case .one(let url):
            logPaste(via: via, found: 1, kept: 1, duplicates: 0)
            addLinks([url], via: via)
        case .review(let request):
            review = request
        }
    }

    /// The review's end: "save N" sends the ticked links to the line at once, "cancel" sends nothing.
    private func finishReview(_ request: PasteReviewRequest, saving urls: [URL]) {
        review = nil
        let duplicates = request.rows.filter { $0.status != .new }.count
        logPaste(via: .review, found: request.found, kept: urls.count, duplicates: duplicates)
        guard !urls.isEmpty else { return }
        addLinks(urls, via: .review)
    }

    /// Links go to the queue; whatever did not take the focus says where it went.
    private func addLinks(_ urls: [URL], via: JobVia) {
        model.selectedTab = .save
        let jobs = model.queue.add(urls.map(JobInput.link), via: via)
        let alongside = jobs.filter { $0.id != model.queue.focusedID }.count
        if alongside > 0 { showStatus(Copy.Jobs.savingAlongside(alongside)) }
    }

    /// One file: the upload and its `name it` sheet, as always. Several files: several upload jobs alongside.
    private func addFiles(_ urls: [URL], via: JobVia) {
        if urls.count == 1 {
            intake(urls[0], via: via)
            return
        }
        model.selectedTab = .save
        let jobs = model.queue.add(urls.map { JobInput.file($0, photosAssetID: nil) }, via: via)
        showStatus(Copy.Jobs.uploadingAlongside(jobs.count))
    }

    /// Files from the picker, Photos, a paste and a drop come through here: the upload starts first
    /// (`importFile`), then the title sheet rises over it (never in its way: the run does not wait for it). A beat
    /// later, so the picker that returned the file has finished leaving, and only if the run is still that upload.
    private func intake(_ url: URL, photosAssetID: String? = nil, via: JobVia = .circle) {
        guard let job = model.importFile(url, photosAssetID: photosAssetID, via: via),
              let request = model.titleRequest(for: job.pipeline)
        else { return }
        let pipeline = job.pipeline
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if pipeline.state != .idle, case .file = pipeline.input {
                titleSheet = TitleSheetRequest(request: request, pipeline: pipeline)
            }
        }
    }

    /// `paste` (CONTRACT-PARALLEL 8): counts only, never a link.
    private func logPaste(via: JobVia, found: Int, kept: Int, duplicates: Int) {
        Telemetry.log(.info, .pipeline, "paste", data: [
            "via": .string(via.rawValue), "links": .int(found), "kept": .int(kept), "duplicates": .int(duplicates),
            "concurrent": .int(model.queue.live.count),
            "line": .string(model.queue.lineMode == .server ? "server" : "device"),
        ])
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
            paste: { handle(Pasteboard.contents(), via: .circle, dropped: false) },
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

    /// ⌘T trims on an iPad with a keyboard (the Mac's lives in the menus). ⌘V on an iPad is the system's: the shell is a
    /// paste destination (`PasteAnywhere`); only before iOS 27, which has no `pasteDestination`, a hidden button keeps
    /// the shortcut and reads the pasteboard when it is pressed.
    @ViewBuilder
    private var shortcuts: some View {
        #if os(iOS)
        VStack {
            if #unavailable(iOS 27.0) {
                Button(Copy.pasteA11y, systemImage: Symbol.paste) { handle(Pasteboard.contents(), via: .paste, dropped: false) }
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

/// The `name it` sheet and the upload it names (the sheet follows that run, focused or not).
private struct TitleSheetRequest: Identifiable {
    let request: TitleRequest
    let pipeline: Pipeline
    var id: UUID { request.id }
}

/// ⌘V and Edit > Paste anywhere in the window (CONTRACT-PARALLEL 4.1): the content is a paste destination, so a text
/// field that has the focus (the `name it` sheet's) takes ⌘V itself and the shell sees only the pastes nothing else
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
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
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
