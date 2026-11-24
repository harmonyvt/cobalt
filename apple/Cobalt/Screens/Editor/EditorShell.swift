import CobaltKit
import SwiftUI

/// One editor for every screen (apple/CONTRACT-EDITOR.md 15.1, 15.2). `EditorLayout` turns the size into a regime and slot
/// rects; this view puts each part, one instance each, into its slot. Nothing here is `if wide { A } else { B }` around a
/// part that holds state: the picture (and its player), the transport, the timeline, the tools and the inspector are the
/// same views in every regime and only move, so folding, unfolding or turning resets nothing. What the screen remembers
/// (open tool, page, drawer, zoom, scroll) is `EditorHost.ui`.
///
/// - compact and tall: top bar, picture, transport (undo and redo beside play), timeline, a bottom row of tools; the
///   inspector is a drawer over the timeline only.
/// - wide: top bar (undo and redo in it), a tool rail left of the picture, the inspector column right of it, the timeline
///   full width at the bottom.
///
/// The tool row (`EditorShellTools`) and the inspector with its pages (`EditorShellInspector`) are one instance each, whatever
/// the regime; the timeline is the iPhone one on iOS (playhead fixed in the middle, as 15.5 wants everywhere) and the desk one
/// on the Mac.
struct EditorShell: View {
    let model: AppModel
    let session: EditSession

    @Environment(EditorHost.self) private var host
    /// The selected clip's source player. The trim bar and the trim keys share it.
    @State private var clipTrim = ClipTrimPreview()

    private var ui: EditorUI { host.ui }

    static var platform: EditorLayout.Platform { Platform.isMac ? .mac : .ios }

    var body: some View {
        GeometryReader { geo in
            let layout = EditorLayout(
                size: geo.size, platform: Self.platform, canvas: session.timeline.canvas,
                preferredTimelineHeight: ui.timelineHeight.map { CGFloat($0) })
            EditorShellSlots(model: model, session: session, layout: layout, clipTrim: clipTrim)
                .onChange(of: layout.regime, initial: true) { _, regime in
                    ui.regimeChanged(to: regime) { session.endGesture() }
                }
        }
        .background(EditorColor.panel)
        .modifier(EditorKeyboard(
            model: model, session: session, clipTrim: clipTrim,
            zoomIn: { ui.timelineScale = ui.timelineScale.zoomed(by: 1.25) },
            zoomOut: { ui.timelineScale = ui.timelineScale.zoomed(by: 0.8) },
            openRender: { ui.renderShown = true }))
        .background { EditorShellHistoryKeys(session: session) }
        .modifier(EditorShellPresentations(model: model, session: session))
        .motion(Motion.card, value: session.saveState == .saved)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - the slots

/// Every part placed into its rect. The order is the drawing order: the drawer over the timeline, the tools and the top bar
/// over everything.
private struct EditorShellSlots: View {
    let model: AppModel
    let session: EditSession
    let layout: EditorLayout
    let clipTrim: ClipTrimPreview

    @Environment(EditorHost.self) private var host
    /// Where the inspector should scroll to when a tool opens a page at something (the picture's opacity tool).
    @State private var focus = EditorInspectorFocus()
    /// The drawer's height while its handle is being dragged (nil = at its detent).
    @State private var drawerDrag: CGFloat?

    private var ui: EditorUI { host.ui }
    private var wide: Bool { layout.regime == .wide }

    var body: some View {
        ZStack(alignment: .topLeading) {
            EditorShellPicture(session: session, cornerRadius: wide ? 10 : 0)
                .place(layout.picture)
            EditorShellTransport(session: session, undoRedo: !wide, fit: fitToScreen)
                .place(layout.transport)
            EditorShellTimeline(session: session, layout: layout)
                .place(layout.timeline)
            inspector
            EditorShellTools(model: model, session: session, rail: layout.toolsAreRail, focus: focus)
                .place(layout.tools)
            EditorShellTopBar(model: model, session: session, wide: wide)
                .place(layout.topBar)
            banners
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    /// One inspector: the wide column, or the drawer at its detent (or at the height its handle is dragged to). A closed drawer
    /// stays mounted (so the trim player and the page keep their state) below the timeline's bottom, hidden.
    @ViewBuilder
    private var inspector: some View {
        let closed = !wide && ui.drawer == .closed && drawerDrag == nil
        let low = layout.drawerLow ?? .zero
        let high = layout.drawerHigh ?? low
        let rect: CGRect = {
            if !wide, let height = drawerDrag, let anchor = layout.drawerLow {
                return CGRect(x: anchor.minX, y: anchor.maxY - height, width: anchor.width, height: height)
            }
            return layout.inspectorRect(ui.drawer) ?? low
        }()
        EditorShellInspector(
            model: model, session: session, clipTrim: clipTrim, focus: focus, drawer: !wide,
            heights: (low.height, high.height), dragHeight: $drawerDrag)
            .place(rect)
            .offset(y: closed ? rect.height + 12 : 0)
            .opacity(closed ? 0 : 1)
            .allowsHitTesting(!closed)
            .accessibilityHidden(closed)
            .motion(Motion.card, value: ui.drawer)
    }

    /// Under the top bar: the conflict banner and, when the render poll lost the server, the reconnect banner (both can be up).
    @ViewBuilder
    private var banners: some View {
        let conflict: Bool = { if case .conflict = session.saveState { return true } else { return false } }()
        let reconnecting: Bool = { if case .reconnecting = session.renderPollState { return true } else { return false } }()
        if conflict || reconnecting {
            VStack(spacing: 0) {
                if conflict {
                    #if os(iOS)
                    if wide { EditorConflictBanner(session: session) } else { EditorPhoneConflictBanner(session: session) }
                    #else
                    EditorConflictBanner(session: session)
                    #endif
                }
                if reconnecting {
                    EditorReconnectBanner(session: session)
                }
            }
            .frame(width: layout.size.width)
            .offset(y: layout.topBar.maxY)
            .transition(.opacity)
        }
    }

    /// The transport's fit-to-screen: the picture back to its slot and the whole edit across the timeline.
    private func fitToScreen() {
        ui.pictureZoom = 1
        let width = layout.timeline.width - (Platform.isMac ? 93 : 32)
        withAnimation(.easeOut(duration: 0.2)) {
            ui.timelineScale = TimelineScale.fitting(duration: session.timing.seconds, width: max(1, width))
        }
    }
}

private extension View {
    /// Puts the view into `rect` of the parent's coordinate space (the shell's content).
    func place(_ rect: CGRect) -> some View {
        frame(width: max(0, rect.width), height: max(0, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }
}

extension EditorUI {
    /// The timeline's zoom as the timelines take it.
    var timelineScale: TimelineScale {
        get { TimelineScale(pointsPerSecond: CGFloat(timelinePointsPerSecond)) }
        set { timelinePointsPerSecond = Double(newValue.pointsPerSecond) }
    }
}

// MARK: - presentations and keys

/// The sheets and popovers of the shell (the add sheet on iOS, the cut-out sheet) and what opens them.
private struct EditorShellPresentations: ViewModifier {
    let model: AppModel
    let session: EditSession

    @Environment(EditorHost.self) private var host

    private var ui: EditorUI { host.ui }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .sheet(item: addRequest) { request in
                EditorPhoneAddSheet(model: model, session: session, mode: request.mode)
                    .presentationDetents([.medium, .large])
                    .environment(host)
                    .cobaltRoot(model: model)
            }
            .haptic(.selection, trigger: session.selection)
            #endif
            .sheet(item: cutoutRequest) { request in
                if let source = LaneClipCommands.picture(session, request.id) {
                    EditorCutoutSheet(session: session, source: source, replacing: request.id) {
                        session.cutoutFor = nil
                    }
                }
            }
            .onChange(of: session.noticeNonce) { _, _ in
                // something that did not apply (an overlay that would not fit, a price that would not load): say why, once
                if let notice = session.notice { host.show(Copy.Editor.notice(notice), seconds: 4) }
            }
            .onChange(of: session.renderConfirmRequested, initial: true) { _, requested in
                guard requested else { return }
                session.renderConfirmRequested = false
                ui.renderShown = true
            }
            .onChange(of: session.effectsFor) { _, id in
                // the effects menu (from the tools, a clip's or a layer's page) is an inspector page
                if id != nil { ui.show(.effects) } else if ui.page == .effects { ui.page = .project }
            }
            .onChange(of: session.selection) { _, selection in
                // picking a clip while the Mac's library is up shows that clip; the canvas page gives way to the clip's own
                if ui.page == .library, selection != .none { ui.closeTool() }
                if ui.openTool == .canvas, selection != .none { ui.closeTool() }
                // letting go of the picture's pick (or of everything) takes the picture tools away
                if selection == .none { ui.pickedOnPicture = false }
            }
    }

    private var cutoutRequest: Binding<CutoutRequest?> {
        Binding(
            get: { session.cutoutFor.map { CutoutRequest(id: $0) } },
            set: { session.cutoutFor = $0?.id })
    }

    #if os(iOS)
    private var addRequest: Binding<EditorShellAddRequest?> {
        Binding(
            get: {
                switch ui.openTool {
                case .addClip: return EditorShellAddRequest(mode: .main)
                case .addLayer: return EditorShellAddRequest(mode: .overlay)
                default: return nil
                }
            },
            set: { if $0 == nil, ui.openTool == .addClip || ui.openTool == .addLayer { ui.openTool = nil } })
    }
    #endif
}

#if os(iOS)
private struct EditorShellAddRequest: Identifiable {
    let mode: EditorPhoneAddMode
    var id: String { mode.rawValue }
}
#endif

/// ⌘Z and ⇧⌘Z in every regime. The visible undo and redo move between the top bar and the transport, so the shortcuts sit
/// here, once.
private struct EditorShellHistoryKeys: View {
    let session: EditSession

    var body: some View {
        ZStack {
            Button("") { session.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!session.canUndo)
            Button("") { session.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!session.canRedo)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - the picture

/// The picture slot: exactly the canvas's shape. The player is always mounted (the crop stage covers it rather than
/// replacing it), so it is never rebuilt.
private struct EditorShellPicture: View {
    let session: EditSession
    let cornerRadius: CGFloat

    private var cropClip: EditClip? {
        guard session.tool == .crop else { return nil }
        return session.selectedMain?.clip
    }

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        ZStack {
            EditorShellCanvasView(session: session, cornerRadius: cornerRadius) { size in
                EditorShellCanvasLayer(session: session, size: size)
            }
            .opacity(cropClip == nil ? 1 : 0)
            .allowsHitTesting(cropClip == nil)
            if let clip = cropClip {
                EditorCropStage(session: session, clip: clip)
                    .background(EditorColor.panel)
            }
        }
        .overlay(alignment: .bottom) { EditorShellNotices(session: session) }
        .mediaMask()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.previewA11y)
    }
}

/// The canvas in the picture slot: the player at the canvas's own shape, the line for a missing or loading file, and the preview
/// failure. `EditorCanvasView` (shared with the older screens) also draws a "this overlay covers the whole picture" banner;
/// that was a hint and the shell does not (15.6), so the shell draws its own.
private struct EditorShellCanvasView<Overlay: View>: View {
    let session: EditSession
    var cornerRadius: CGFloat = 10
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let fit = EditorCanvasFit.size(canvas: session.timeline.canvas, in: geo.size)
            ZStack {
                EditorPlayerView(player: session.player)
                    .opacity(session.isPlayerReady ? 1 : 0)
                stateLine
                overlay(fit)
            }
            .frame(width: fit.width, height: fit.height)
            .overlay(alignment: .bottom) {
                if session.previewFailed { failure }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CobaltColor.border.opacity(0.35), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Editor.canvasA11y)
        }
    }

    private var failure: some View {
        Text(session.previewFailure ?? Copy.Editor.previewFailed)
            .font(CobaltType.captionSmall)
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var stateLine: some View {
        if let line {
            Text(line)
                .font(CobaltType.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(12)
                .transition(.opacity)
        }
    }

    /// The one line over the canvas: a missing file first, then the download, then a file that would not come.
    private var line: String? {
        if session.hasMissingSources { return Copy.Editor.missingClip }
        if let fraction = session.loadingFraction { return Copy.Editor.loadingSources(Int((fraction * 100).rounded())) }
        if !session.sourceFailures.isEmpty { return Copy.Editor.sourceFailed }
        return nil
    }
}

/// What stops a render, on the picture's bottom edge (not a band of its own): a file that would not come with `try again`, a
/// deleted file, and a clip the preview left out. Two hints sit with them: lots of videos at once (the preview may stutter, the
/// render is fine: `EditorPreviewCrowdedNote`, 15.6's hint is back) and a pitch the preview could not make (with `try again`).
/// One view for every regime, as the picture is.
private struct EditorShellNotices: View {
    let session: EditSession

    var body: some View {
        VStack(spacing: 4) {
            if !session.sourceFailures.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: Symbol.Editor.missing)
                        .accessibilityHidden(true)
                    Text(Copy.Editor.sourceFailed)
                    Button { retryAll() } label: { Label(Copy.Editor.tryAgain, systemImage: Symbol.Editor.retry) }
                        .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.linkBlue))
                }
                .notice()
            } else if session.hasMissingSources {
                Label(Copy.Editor.removeMissing, systemImage: Symbol.Editor.missing)
                    .notice()
            }
            if !session.previewSkips.isEmpty {
                Text(Copy.Editor.previewSkipped(session.previewSkips.count))
                    .notice()
            }
            EditorPreviewCrowdedNote(session: session, onPicture: true, includeSkipped: false)
            let pitch = session.pitchPreviewFailures
            if pitch > 0 {
                HStack(spacing: 8) {
                    Text(Copy.Editor.pitchPreviewFailed(pitch))
                    Button { session.retryPitchPreview() } label: { Label(Copy.Editor.tryAgain, systemImage: Symbol.Editor.retry) }
                        .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.linkBlue))
                }
                .notice()
            }
        }
        .padding(8)
    }

    private func retryAll() {
        for item in session.sourceFailures.keys { session.retrySource(item) }
    }
}

private extension View {
    func notice() -> some View {
        font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.errorText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - the timeline

/// The timeline slot. iOS: the playhead-centred timeline in every regime (touch first; 15.5's direction). The Mac: the
/// scrolling desk timeline, with its top edge draggable (the height is `EditorUI.timelineHeight`).
private struct EditorShellTimeline: View {
    let session: EditSession
    let layout: EditorLayout

    @Environment(EditorHost.self) private var host
    #if os(macOS)
    @State private var resizeBase: CGFloat?
    #endif

    private var ui: EditorUI { host.ui }

    private var scale: Binding<TimelineScale> {
        Binding(get: { ui.timelineScale }, set: { ui.timelineScale = $0 })
    }

    var body: some View {
        #if os(iOS)
        EditorPhoneTimeline(session: session, scale: scale, openAdd: { ui.open(.addClip, page: nil) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(EditorColor.lane)
        #else
        EditorTimelinePane(session: session, scale: scale, height: layout.timeline.height)
            .overlay(alignment: .top) { resizeEdge }
        #endif
    }

    #if os(macOS)
    /// The timeline's top edge (wide): drag to make it taller or shorter.
    private var resizeEdge: some View {
        Rectangle()
            .fill(EditorColor.line)
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .rowResizePointer()
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = resizeBase ?? layout.timeline.height
                                resizeBase = base
                                ui.timelineHeight = Double(base - value.translation.height)
                            }
                            .onEnded { _ in resizeBase = nil })
            }
            .opacity(layout.regime == .wide ? 1 : 0)
            .allowsHitTesting(layout.regime == .wide)
            .accessibilityHidden(true)
    }
    #endif
}

// MARK: - the transport

/// 48 pt under the picture: the time on the left; play in the middle, with undo and redo either side when compact or tall;
/// fit-to-screen on the right. No hint text.
private struct EditorShellTransport: View {
    let session: EditSession
    let undoRedo: Bool
    let fit: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                EditorShellClock(session: session)
                Spacer(minLength: 8)
                Button(action: fit) { Label(Copy.Editor.shellFitToScreen, systemImage: Symbol.Editor.shellFitToScreen) }
                    .buttonStyle(.cobaltIcon(.small))
                    .help(Copy.Editor.shellFitToScreen)
            }
            HStack(spacing: 6) {
                if undoRedo {
                    Button { session.undo() } label: { Label(Copy.Editor.undo, systemImage: Symbol.Editor.undo) }
                        .buttonStyle(.cobaltIcon(.small))
                        .disabled(!session.canUndo)
                }
                EditorShellPlayButton(session: session)
                if undoRedo {
                    Button { session.redo() } label: { Label(Copy.Editor.redo, systemImage: Symbol.Editor.redo) }
                        .buttonStyle(.cobaltIcon(.small))
                        .disabled(!session.canRedo)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorColor.panel)
        .accessibilityElement(children: .contain)
    }
}

/// `0:09.0 / 0:26.0`. Its own view: it reads the playhead, so playing redraws only this.
private struct EditorShellClock: View {
    let session: EditSession

    var body: some View {
        Text("\(Copy.Editor.clockTenths(session.playheadSeconds)) / \(Copy.Editor.clockTenths(session.timing.seconds))")
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.caption)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Editor.transportTime)
            .accessibilityValue(Copy.Editor.a11yPlayheadValue(
                Copy.Editor.clockTenths(session.playheadSeconds), of: Copy.Editor.clockTenths(session.timing.seconds)))
    }
}

private struct EditorShellPlayButton: View {
    let session: EditSession

    var body: some View {
        Button { session.togglePlay() } label: {
            Label(
                session.isPlaying ? Copy.Editor.pause : Copy.Editor.play,
                systemImage: session.isPlaying ? Symbol.Editor.pause : Symbol.Editor.play)
        }
        .buttonStyle(.cobaltIcon(.small, prominent: true))
        .disabled(!session.isPlayerReady)
    }
}

// MARK: - copy and symbols the shell added

extension Copy.Editor {
    static let shellAddLayer = "add layer"
    static let shellSound = "sound"
    static let shellFitToScreen = "fit to screen"
    static let shellLetGo = "done"
    static let shellClosePanel = "close panel"
    static let shellPanel = "panel"
    static let shellLibrary = "library"
}

extension Symbol.Editor {
    static let shellAddLayer = "plus.square.on.square"
    static let shellFitToScreen = "viewfinder"
    static let shellLetGo = "checkmark"
}
