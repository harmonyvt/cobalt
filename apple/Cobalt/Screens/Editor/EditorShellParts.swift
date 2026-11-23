import CobaltKit
import SwiftUI

// The parts `EditorShell` puts into its slots (apple/CONTRACT-EDITOR.md 15.1): the top bar, the tools (a bottom row or a
// rail) and the inspector (a column or a drawer). Each is one view whatever the regime; only small, stateless pieces inside
// them (undo and redo in the bar, the drawer's handle) come and go with it. Step 3 restyles the tools and the inspector.

// MARK: - the top bar

/// Close (iPhone and iPad), the title (click to rename) over the save line, `more` (canvas, quality, delete) and `render`.
/// Wide adds undo and redo and, on the Mac, the select and blade tools of the desk timeline.
struct EditorShellTopBar: View {
    let model: AppModel
    let session: EditSession
    let wide: Bool

    @Environment(EditorHost.self) private var host
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 8) {
            #if os(iOS)
            CloseButton { host.requestClose(model) }
            #endif
            VStack(alignment: .leading, spacing: 0) {
                EditorTitleField(session: session)
                EditorShellSaveLine(session: session)
            }
            Spacer(minLength: 4)
            if wide {
                history
                #if os(macOS)
                timelineTools
                #endif
            }
            moreMenu
            renderButton
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorColor.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        #if os(iOS)
        // compact and tall: the render card is a sheet (a popover from the corner ran off the iPhone's edge)
        .sheet(isPresented: renderSheet) {
            EditorPhoneRenderSheet(model: model, session: session, close: { host.ui.renderShown = false })
                .presentationDetents([.medium])
                .environment(host)
                .cobaltRoot(model: model)
        }
        #endif
        .confirmationDialog(Copy.Editor.deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(Copy.Editor.deleteConfirm, role: .destructive) { deleteProject() }
            Button(Copy.Editor.cancel, role: .cancel) {}
        } message: {
            Text(Copy.Editor.deleteBody)
        }
    }

    /// The render card, from `EditorUI.renderShown` (⌘↩ and the queue's "try again" set it too): the popover of the old
    /// top bar when wide (and always on the Mac), the iPhone's sheet when compact or tall.
    @ViewBuilder
    private var renderButton: some View {
        #if os(iOS)
        if wide {
            RenderButton(model: model, session: session, shown: Binding(
                get: { host.ui.renderShown && wide }, set: { host.ui.renderShown = $0 }))
        } else {
            EditorPhoneRenderButton(session: session) { host.ui.renderShown = true }
        }
        #else
        RenderButton(model: model, session: session, shown: Bindable(host.ui).renderShown)
        #endif
    }

    #if os(iOS)
    private var renderSheet: Binding<Bool> {
        Binding(get: { host.ui.renderShown && !wide }, set: { if !$0 { host.ui.renderShown = false } })
    }
    #endif

    private var history: some View {
        HStack(spacing: 4) {
            Button { session.undo() } label: { Label(Copy.Editor.undo, systemImage: Symbol.Editor.undo) }
                .buttonStyle(.cobaltIcon(.small))
                .disabled(!session.canUndo)
                .help("\(Copy.Editor.undo) · ⌘Z")
            Button { session.redo() } label: { Label(Copy.Editor.redo, systemImage: Symbol.Editor.redo) }
                .buttonStyle(.cobaltIcon(.small))
                .disabled(!session.canRedo)
                .help("\(Copy.Editor.redo) · ⇧⌘Z")
        }
    }

    #if os(macOS)
    /// Select and blade work on the desk timeline (the blade splits where it clicks). V and B pick them too.
    private var timelineTools: some View {
        HStack(spacing: 4) {
            toolButton(.select, Copy.Editor.toolSelect, symbol: Symbol.Editor.toolSelect)
            toolButton(.blade, Copy.Editor.toolBlade, symbol: Symbol.Editor.toolBlade)
        }
    }

    private func toolButton(_ tool: EditSession.Tool, _ title: String, symbol: String) -> some View {
        let on = session.tool == tool
        return Button { session.tool = tool } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.cobaltIcon(.small, prominent: on))
            .accessibilityAddTraits(on ? .isSelected : [])
    }
    #endif

    private var moreMenu: some View {
        Menu {
            Menu(Copy.Editor.canvas) {
                ForEach(EditCanvas.Shape.allCases, id: \.self) { shape in
                    Button { EditorShellCanvas.set(session, shape: shape) } label: {
                        EditorShellCanvas.choice(shape.rawValue, on: shape == session.timeline.canvas.shape)
                    }
                }
            }
            Menu(Copy.Editor.quality) {
                ForEach(EditorShellCanvas.qualities) { quality in
                    Button { EditorShellCanvas.set(session, quality: quality) } label: {
                        EditorShellCanvas.choice(quality.title, on: quality.matches(session.timeline.canvas))
                    }
                }
            }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label(Copy.Editor.deleteEdit, systemImage: Symbol.Editor.delete)
            }
        } label: {
            EditorShellMenuIcon(name: Copy.Editor.moreOptions, symbol: Symbol.Editor.more)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .iconName(Copy.Editor.moreOptions)
    }

    private func deleteProject() {
        let id = session.project.id
        Task {
            do {
                try await model.editor.delete(id)
            } catch {
                host.show(Copy.Editor.errorLine(EditError.from(error)))
            }
        }
    }
}

/// `saved · 4 clips · 0:26`, the first problem, `not saved · retrying` (tap to retry now).
private struct EditorShellSaveLine: View {
    let session: EditSession

    var body: some View {
        switch session.saveState {
        case .failed:
            Button { Task { await session.retrySave() } } label: { line(session.saveLine, error: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.Editor.tryAgain)
        case .conflict, .needsUpdate:
            line(session.saveLine, error: true)
        case .saved, .saving, .unsaved:
            if let problem = session.problemLine {
                line(problem, error: true)
            } else {
                line(session.saveLine, error: false)
            }
        }
    }

    private func line(_ text: String, error: Bool) -> some View {
        Text(text)
            .font(Font.cobalt(10, .regular, relativeTo: .caption2))
            .foregroundStyle(error ? CobaltColor.errorText : CobaltColor.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A menu's trigger drawn like a small `.cobaltIcon()` circle (menus can't take that button style).
private struct EditorShellMenuIcon: View {
    let name: String
    let symbol: String

    var body: some View {
        Label(name, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(CobaltColor.text)
            .frame(width: 34, height: 34)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
    }
}

/// The canvas shape and quality choices (the old top bar's and the iPhone header's menus).
private enum EditorShellCanvas {
    struct Quality: Identifiable {
        let resolution: EditCanvas.Resolution
        let fps: Int
        var id: String { title }
        var title: String { Copy.Editor.qualityLabel(resolution.rawValue, fps) }
        func matches(_ canvas: EditCanvas) -> Bool { canvas.resolution == resolution && canvas.fps == fps }
    }

    static let qualities: [Quality] = [
        Quality(resolution: .p1080, fps: 30), Quality(resolution: .p1080, fps: 60),
        Quality(resolution: .p720, fps: 30), Quality(resolution: .p720, fps: 60),
    ]

    @MainActor
    static func set(_ session: EditSession, shape: EditCanvas.Shape) {
        let c = session.timeline.canvas
        session.setCanvas(EditCanvas(shape: shape, resolution: c.resolution, fps: c.fps))
    }

    @MainActor
    static func set(_ session: EditSession, quality: Quality) {
        session.setCanvas(EditCanvas(shape: session.timeline.canvas.shape, resolution: quality.resolution, fps: quality.fps))
    }

    @ViewBuilder
    static func choice(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: Symbol.keep) } else { Text(title) }
    }
}

// MARK: - the tools

/// Icons only, 44 pt targets, the name on a long press (and `.help` on the Mac); never captions. A bottom row (compact,
/// tall) or a rail left of the picture (wide), the same view either way. Contextual (15.1):
/// - nothing selected: add clip, add layer, canvas, effects, post;
/// - a clip or layer: trim, split, speed, crop, sound, effects, delete, and `done` at the end to let go of it.
/// Opening a tool opens its inspector page (the drawer when compact or tall). Overflow scrolls; step 3 adds `more`.
struct EditorShellTools: View {
    let model: AppModel
    let session: EditSession
    let rail: Bool

    @Environment(EditorHost.self) private var host
    @State private var splitTick = 0
    /// The playhead as the buttons see it, set by `EditorPlayheadSpotReader` when it changes.
    @State private var spot: EditorPlayheadSpot?

    private var ui: EditorUI { host.ui }

    var body: some View {
        let stack = rail ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        GeometryReader { geo in
            ScrollView(rail ? .vertical : .horizontal, showsIndicators: false) {
                stack { buttons }
                    .padding(rail ? .vertical : .horizontal, 8)
                    .frame(
                        minWidth: rail ? geo.size.width : geo.size.width, minHeight: geo.size.height,
                        alignment: rail ? .top : .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(EditorColor.bar)
        .overlay(alignment: rail ? .trailing : .top) {
            Rectangle().fill(EditorColor.line).frame(width: rail ? 1 : nil, height: rail ? nil : 1)
        }
        .background { EditorPlayheadSpotReader(session: session) { spot = $0 } }
        .haptic(.impact(weight: .light), trigger: splitTick)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        if session.selection == .none {
            tool(Copy.Editor.addClip, Symbol.Editor.add) { add(.addClip) }
            tool(Copy.Editor.shellAddLayer, Symbol.Editor.shellAddLayer) { add(.addLayer) }
            canvasMenu
            tool(Copy.Editor.effects, Symbol.Editor.effects, enabled: LaneClipCommands.videoClipID(session) != nil) { openEffects() }
            PostToolButton(model: model, session: session)
        } else {
            tool(Copy.Editor.toolTrim, Symbol.Editor.trim, on: ui.openTool == .trim) { open(.trim, .trim) }
            splitButton
            tool(Copy.Editor.toolSpeed, Symbol.Editor.speed, on: ui.openTool == .speed) { open(.speed, .speed) }
            tool(Copy.Editor.toolCrop, Symbol.Editor.toolCrop, on: ui.openTool == .crop) { crop() }
            tool(Copy.Editor.shellSound, Symbol.Editor.volume, on: ui.openTool == .sound) { open(.sound, .sound) }
            tool(Copy.Editor.effects, Symbol.Editor.effects, enabled: LaneClipCommands.videoClipID(session) != nil,
                 on: session.effectsFor != nil) { openEffects() }
            tool(Copy.Editor.deleteClipShort, Symbol.Editor.delete) { delete() }
            tool(Copy.Editor.shellLetGo, Symbol.Editor.shellLetGo, on: true) { letGo() }
        }
    }

    private func tool(
        _ title: String, _ symbol: String, enabled: Bool = true, on: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.cobaltIcon(.small, prominent: on))
            .disabled(!enabled)
            .help(title)
            .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
    }

    private var canvasMenu: some View {
        Menu {
            ForEach(EditCanvas.Shape.allCases, id: \.self) { shape in
                Button { EditorShellCanvas.set(session, shape: shape) } label: {
                    EditorShellCanvas.choice(shape.rawValue, on: shape == session.timeline.canvas.shape)
                }
            }
        } label: {
            EditorShellMenuIcon(name: Copy.Editor.canvas, symbol: Symbol.Editor.canvas)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .iconName(Copy.Editor.canvas)
        .accessibilityValue(session.timeline.canvas.shape.rawValue)
    }

    // MARK: split

    private var currentSpot: EditorPlayheadSpot { spot ?? EditorPlayheadSpot(session) }

    /// Any version 2 clip contains the playhead, so split is not limited to the bottom lane.
    private var splitReady: Bool {
        guard session.timeline.isV2 else { return currentSpot.canSplit }
        return session.timing.laneClips.contains { session.playhead > $0.start && session.playhead < $0.start + $0.frames }
    }

    /// Stays tappable while it cannot split (dimmed) and answers with the line that says why.
    private var splitButton: some View {
        Button { split() } label: { Label(Copy.Editor.toolSplit, systemImage: Symbol.Editor.split) }
            .buttonStyle(.cobaltIcon(.small))
            .opacity(splitReady ? 1 : 0.45)
            .help(Copy.Editor.toolSplit)
            .accessibilityHint(splitReady ? "" : Copy.Editor.nothingToSplit)
            .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
    }

    private func split() {
        guard splitReady else {
            host.show(Copy.Editor.nothingToSplit)
            return
        }
        session.splitAtPlayhead()
        splitTick += 1
    }

    // MARK: actions

    /// iOS: the add sheet (a presentation, 15.1). The Mac: the library takes the inspector's place (drag in or double-click).
    private func add(_ tool: EditorUI.Tool) {
        #if os(iOS)
        ui.open(tool, page: nil)
        #else
        ui.open(tool, page: .library)
        #endif
    }

    private func open(_ tool: EditorUI.Tool, _ page: EditorUI.Page) {
        if ui.openTool == tool, ui.drawer != .closed || rail {
            ui.closeTool()
            return
        }
        ui.open(tool, page: page)
    }

    /// A main clip: the crop frame on the picture (the crop tool) and the crop rows. A picture layer: its crop is in the page.
    private func crop() {
        if ui.openTool == .crop {
            if session.tool == .crop { session.tool = .select }
            ui.closeTool()
            return
        }
        if session.selectedMain != nil { session.tool = .crop }
        ui.open(.crop, page: .crop)
    }

    private func openEffects() {
        guard let id = LaneClipCommands.videoClipID(session) else {
            host.show(Copy.Editor.effectsNeedVideo)
            return
        }
        if let clip = session.timeline.clips.first(where: { $0.id == id }) {
            LaneClipCommands.select(session, clip)
        } else {
            session.selection = .overlay(id)
        }
        ui.open(.effects, page: .effects)
        session.openEffects(id)
    }

    private func delete() {
        session.remove(session.selection)
        letGo()
    }

    /// `done`: lets go of the selection, the crop frame, the effects menu and the open tool.
    private func letGo() {
        if session.tool == .crop { session.tool = .select }
        if session.effectsFor != nil { session.closeEffects() }
        session.selection = .none
        ui.closeTool()
    }
}

// MARK: - the inspector

/// One inspector: the wide column (always there) or the drawer over the timeline (compact, tall) with its handle. Today it
/// is the desk inspector, which follows the selection (and the effects menu); the Mac's library takes its place while
/// adding. Step 3 turns `EditorUI.page` into the pages of 15.1.
struct EditorShellInspector: View {
    let model: AppModel
    let session: EditSession
    let clipTrim: ClipTrimPreview
    /// Compact and tall: drawn as the drawer.
    let drawer: Bool

    @Environment(EditorHost.self) private var host

    private var ui: EditorUI { host.ui }


    var body: some View {
        VStack(spacing: 0) {
            if drawer { handle }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(EditorColor.panel)
        // the selected main clip's source player, loaded whatever the page: the trim keys (I, O, space, arrows) use it
        .modifier(ClipTrimSync(session: session, clip: session.selectedMain?.clip, preview: clipTrim))
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: drawer ? 16 : 0, topTrailingRadius: drawer ? 16 : 0, style: .continuous))
        .overlay(alignment: .leading) {
            if !drawer { Rectangle().fill(EditorColor.line).frame(width: 1) }
        }
        .shadow(color: .black.opacity(drawer ? 0.18 : 0), radius: 12, y: -2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if ui.page == .library {
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    Button { ui.closeTool() } label: { Label(Copy.Editor.close, systemImage: Symbol.Editor.close) }
                        .buttonStyle(.cobaltIcon(.small))
                        .help(Copy.Editor.close)
                }
                .padding(.horizontal, 8)
                .padding(.top, drawer ? 0 : 6)
                EditorBin(model: model, session: session)
            }
        } else if ui.page == .trim, let (_, clip) = session.selectedMain {
            // the trim page: the clip's source picture and strip (the desk had them under the picture)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ClipTrimPicture(session: session, clip: clip, preview: clipTrim)
                        .aspectRatio(Self.aspect(session, clip), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 112)
                    ClipTrimStrip(session: session, clip: clip, preview: clipTrim)
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        } else {
            EditorInspector(session: session, pitchEnabled: model.capabilities.limits.editPitch, clipTrim: clipTrim)
        }
    }

    private static func aspect(_ session: EditSession, _ clip: EditClip) -> CGFloat {
        guard let display = session.source(for: clip.item)?.display, display.h > 0 else { return 16.0 / 9.0 }
        return CGFloat(display.w) / CGFloat(display.h)
    }

    /// The drawer's handle: drag up or down a detent (down from the low one closes), tap to switch detents, or the close.
    private var handle: some View {
        ZStack {
            Capsule()
                .fill(CobaltColor.border)
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            HStack {
                Spacer(minLength: 0)
                Button { close() } label: { Label(Copy.Editor.shellClosePanel, systemImage: Symbol.Editor.close) }
                    .buttonStyle(.cobaltIcon(.small))
                    .help(Copy.Editor.shellClosePanel)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture { ui.drawer = ui.drawer == .high ? .low : .high }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    guard abs(value.translation.height) > 24 else { return }
                    let up = value.translation.height < 0
                    if !up, ui.drawer == .low { close() } else { ui.stepDrawer(up: up) }
                })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.shellPanel)
    }

    private func close() {
        if session.tool == .crop { session.tool = .select }
        if session.effectsFor != nil { session.closeEffects() }
        ui.closeTool()
    }
}
