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
/// Step 2 of 5: the tool row and the inspector are the existing pieces put in their slots (step 3 restyles them); the
/// timeline is the iPhone one on iOS (playhead fixed in the middle, as 15.5 wants everywhere) and the desk one on the Mac.
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
            EditorShellTools(model: model, session: session, rail: layout.toolsAreRail)
                .place(layout.tools)
            EditorShellTopBar(model: model, session: session, wide: wide)
                .place(layout.topBar)
            conflictBanner
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    /// One inspector: the wide column, or the drawer at its detent. A closed drawer stays mounted (so the trim player and
    /// the page keep their state) below the timeline's bottom, hidden.
    @ViewBuilder
    private var inspector: some View {
        let closed = !wide && ui.drawer == .closed
        let rect = layout.inspectorRect(ui.drawer) ?? layout.drawerLow ?? .zero
        EditorShellInspector(model: model, session: session, clipTrim: clipTrim, drawer: !wide)
            .place(rect)
            .offset(y: closed ? rect.height + 12 : 0)
            .opacity(closed ? 0 : 1)
            .allowsHitTesting(!closed)
            .accessibilityHidden(closed)
            .motion(Motion.card, value: ui.drawer)
    }

    @ViewBuilder
    private var conflictBanner: some View {
        if case .conflict = session.saveState {
            Group {
                #if os(iOS)
                if wide { EditorConflictBanner(session: session) } else { EditorPhoneConflictBanner(session: session) }
                #else
                EditorConflictBanner(session: session)
                #endif
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
            .onChange(of: session.renderConfirmRequested, initial: true) { _, requested in
                guard requested else { return }
                session.renderConfirmRequested = false
                ui.renderShown = true
            }
            .onChange(of: session.effectsFor) { _, id in
                // the effects menu (from the tools, the picture's hint, a layer's row) is an inspector page
                if id != nil { ui.show(.effects) } else if ui.page == .effects { ui.page = .project }
            }
            .onChange(of: session.selection) { _, selection in
                // picking a clip while the Mac's library is up shows that clip
                if ui.page == .library, selection != .none { ui.closeTool() }
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
            EditorCanvasView(session: session, cornerRadius: cornerRadius) { size in
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

/// On the canvas: a tap plays or pauses, a pinch sizes the selected overlay about its centre (aspect kept), and while that
/// overlay is on the canvas at the playhead its outline with the drag and the corner handles. Step 4 replaces this with the
/// touchable picture of 15.3.
private struct EditorShellCanvasLayer: View {
    let session: EditSession
    let size: CGSize

    @State private var pinchStart: EditFrame?

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.togglePlay() }
                .gesture(pinch)
                .accessibilityHidden(true)
            if session.tool != .crop, let overlay = session.selectedOverlay, EditorPreviewPane.isVisible(overlay, in: session) {
                EditorOverlayHandles(session: session, overlay: overlay, canvasSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let overlay = session.selectedOverlay else { return }
                let first = pinchStart ?? overlay.frame
                pinchStart = first
                session.setOverlayFrame(id: overlay.id, scaled(first, by: Double(value.magnification), overlay: overlay))
            }
            .onEnded { _ in
                pinchStart = nil
                session.endGesture()
            }
    }

    private func scaled(_ first: EditFrame, by factor: Double, overlay: EditOverlay) -> EditFrame {
        let canvas = session.timeline.canvas
        let display = session.source(for: overlay.item)?.display ?? PixelSize(w: 16, h: 9)
        let h0 = EditGeometry.overlayHeightFraction(display: display, frame: first, canvas: canvas)
        let w = min(1, max(0.05, first.w * factor))
        let h = h0 * w / max(0.001, first.w)
        let centerX = first.x + first.w / 2
        let centerY = first.y + h0 / 2
        return EditFrame(x: centerX - w / 2, y: centerY - h / 2, w: w)
    }
}

/// What stops a render, on the picture's bottom edge (not a band of its own): a file that would not come with `try again`,
/// a deleted file, and the crowded-preview note.
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
            EditorPreviewCrowdedNote(session: session)
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
