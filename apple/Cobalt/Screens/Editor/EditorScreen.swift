import CobaltKit
import SwiftUI

/// The Mac and iPad editor, the approved board "Mac A" (apple/CONTRACT-EDITOR.md 4.3): a 48 pt top bar; the library bin
/// (236 pt), the preview and the inspector (272 pt); and the timeline (268 pt, resizable by its top edge from 180 to 480).
struct EditorScreen: View {
    let model: AppModel
    let session: EditSession

    @Environment(EditorHost.self) private var host
    @State private var scale = TimelineScale.standard
    @State private var timelineHeight: CGFloat = 268
    @State private var resizeBase: CGFloat?
    @State private var renderShown = false

    static let binWidth: CGFloat = 236
    static let inspectorWidth: CGFloat = 272

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model, session: session, renderShown: $renderShown)
            if case .conflict = session.saveState {
                EditorConflictBanner(session: session)
            }
            middle
            resizeEdge
            EditorTimelinePane(session: session, scale: $scale, height: timelineHeight)
                .frame(height: timelineHeight)
        }
        .background(EditorColor.panel)
        .modifier(EditorKeyboard(
            model: model, session: session,
            zoomIn: { scale = scale.zoomed(by: 1.25) }, zoomOut: { scale = scale.zoomed(by: 0.8) },
            openRender: { renderShown = true }))
        .onChange(of: session.renderConfirmRequested, initial: true) { _, requested in
            guard requested else { return }
            session.renderConfirmRequested = false
            renderShown = true
        }
        .motion(Motion.card, value: session.saveState == .saved)
        .accessibilityElement(children: .contain)
    }

    private var middle: some View {
        HStack(spacing: 0) {
            EditorBin(model: model, session: session)
                .frame(width: Self.binWidth)
            divider
            EditorPreviewPane(session: session)
                .background(EditorColor.lane.opacity(0.5))
            divider
            EditorInspector(session: session)
                .frame(width: Self.inspectorWidth)
        }
        .frame(maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(EditorColor.line).frame(width: 1)
    }

    /// The timeline's top edge: drag to make it taller or shorter.
    private var resizeEdge: some View {
        Rectangle()
            .fill(EditorColor.line)
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = resizeBase ?? timelineHeight
                                resizeBase = base
                                timelineHeight = min(480, max(180, base - value.translation.height))
                            }
                            .onEnded { _ in resizeBase = nil })
            }
            .accessibilityHidden(true)
    }
}

/// `conflictTitle` / `conflictBody` with `useTheirs` and `keepMine`, under the top bar while the server's copy moved on.
struct EditorConflictBanner: View {
    let session: EditSession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: Symbol.Editor.missing)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CobaltColor.errorText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Editor.conflictTitle)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                Text(Copy.Editor.conflictBody)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ButtonRow {
                Button(Copy.Editor.useTheirs) { Task { await session.resolveConflict(keepMine: false) } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Button(Copy.Editor.keepMine) { Task { await session.resolveConflict(keepMine: true) } }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CobaltColor.error.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
