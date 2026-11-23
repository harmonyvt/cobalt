import CobaltKit
import SwiftUI

/// One inspector (apple/CONTRACT-EDITOR.md 15.1): the wide column (always there; nothing selected is the project page) or, when
/// compact or tall, a drawer over the timeline with a handle that moves it between its detents (closed, low, high) by drag.
/// It shows one page at a time (`EditorInspectorPages.swift`), the one `EditorUI.page` says, made to fit the selection. The Mac's
/// library takes its place while adding.
struct EditorShellInspector: View {
    let model: AppModel
    let session: EditSession
    let clipTrim: ClipTrimPreview
    let focus: EditorInspectorFocus
    /// Compact and tall: drawn as the drawer.
    let drawer: Bool
    /// The drawer's heights at its low and high detents.
    var heights: (low: CGFloat, high: CGFloat) = (0, 0)
    /// The height the handle is being dragged to (nil = at the detent). The shell sizes the drawer from it, live.
    @Binding var dragHeight: CGFloat?

    @Environment(EditorHost.self) private var host
    @State private var dragBase: CGFloat?

    private var ui: EditorUI { host.ui }

    private var page: EditorUI.Page {
        ui.page.resolved(selection: session.selection, effectsOpen: session.effectsFor != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
        if page == .library {
            EditorBin(model: model, session: session)
        } else {
            EditorInspectorPageView(model: model, session: session, clipTrim: clipTrim, focus: focus, page: page)
        }
    }

    // MARK: the header

    /// The page's name on the left. The drawer adds its handle (drag it, or tap to switch detents) and a close; the library
    /// has a close in both.
    @ViewBuilder
    private var header: some View {
        if drawer {
            drawerHandle
        } else if page == .library {
            HStack {
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        } else {
            title
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        }
    }

    private var title: some View {
        Text(Self.title(of: page))
            .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
            .foregroundStyle(CobaltColor.caption)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var closeButton: some View {
        Button { close() } label: { Label(Copy.Editor.shellClosePanel, systemImage: Symbol.Editor.close) }
            .buttonStyle(.cobaltIcon(.small))
            .help(Copy.Editor.shellClosePanel)
    }

    private var drawerHandle: some View {
        ZStack {
            Capsule()
                .fill(CobaltColor.border)
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            HStack {
                title.padding(.leading, 14)
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.card) { ui.drawer = ui.drawer == .high ? .low : .high } }
        .gesture(handleDrag)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.shellPanel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ui.stepDrawer(up: true)
            case .decrement:
                if ui.drawer == .low { close() } else { ui.stepDrawer(up: false) }
            @unknown default: break
            }
        }
    }

    // MARK: the drag

    private var currentHeight: CGFloat {
        switch ui.drawer {
        case .closed: return 0
        case .low: return heights.low
        case .high: return heights.high
        }
    }

    /// The drawer follows the finger between closed and high, and lets go at the nearest detent to where a fling would end.
    private var handleDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let base = dragBase ?? currentHeight
                dragBase = base
                dragHeight = min(heights.high, max(0, base - value.translation.height))
            }
            .onEnded { value in
                let base = dragBase ?? currentHeight
                dragBase = nil
                let end = min(heights.high, max(0, base - value.predictedEndTranslation.height))
                let detents: [(EditorLayout.DrawerDetent, CGFloat)] = [(.closed, 0), (.low, heights.low), (.high, heights.high)]
                let target = detents.min { abs($0.1 - end) < abs($1.1 - end) }?.0 ?? .low
                if target == .closed {
                    withAnimation(Motion.card) { dragHeight = nil }
                    close()
                } else {
                    withAnimation(Motion.card) {
                        dragHeight = nil
                        ui.drawer = target
                    }
                }
            }
    }

    private func close() {
        if session.tool == .crop { session.tool = .select }
        if session.effectsFor != nil { session.closeEffects() }
        focus.section = nil
        ui.closeTool()
    }

    // MARK: names

    static func title(of page: EditorUI.Page) -> String {
        switch page {
        case .project: return Copy.Editor.shellProject
        case .library: return Copy.Editor.shellLibrary
        case .clip: return Copy.Editor.shellClip
        case .layer: return Copy.Editor.shellLayer
        case .sound: return Copy.Editor.shellSound
        case .speed: return Copy.Editor.speed
        case .crop: return Copy.Editor.crop
        case .trim: return Copy.Editor.trim
        case .effects: return Copy.Editor.effects
        }
    }
}
