import CobaltKit
import SwiftUI

// The top bar `EditorShell` puts into its slot (apple/CONTRACT-EDITOR.md 15.1). The tools are in `EditorShellTools.swift`, the
// inspector in `EditorShellInspector.swift` and its pages in `EditorInspectorPages.swift`.

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
            EditorShellRenderButton(session: session) { host.ui.renderShown = true }
                .popover(isPresented: Binding(
                    get: { host.ui.renderShown && wide }, set: { host.ui.renderShown = $0 }), arrowEdge: .bottom) {
                    EditorRenderCard(model: model, session: session, close: { host.ui.renderShown = false })
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            EditorShellRenderButton(session: session) { host.ui.renderShown = true }
        }
        #else
        EditorShellRenderButton(session: session) { host.ui.renderShown = true }
            .popover(isPresented: Bindable(host.ui).renderShown, arrowEdge: .bottom) {
                EditorRenderCard(model: model, session: session, close: { host.ui.renderShown = false })
            }
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

/// `render` in the 48 pt top bar: the black pill, as tall as the close and `more` circles (a 34 pt face in a 44 pt touch
/// target, so nothing is cut off by the bar). While a render of this project runs it carries the progress
/// (`waiting · 1 ahead`, `preparing`, `rendering 40%`, `finishing`); either way it opens the render card.
struct EditorShellRenderButton: View {
    let session: EditSession
    let action: () -> Void

    private var running: EditRender? {
        guard let r = session.activeRender, r.isActive else { return nil }
        return r
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let running {
                    ProgressView(value: running.progress.map { min(1, max(0, $0)) })
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(CobaltColor.onText)
                    Text(Copy.Editor.renderLine(running))
                        .monospacedDigit()
                        .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                } else {
                    Text(Copy.Editor.render)
                        .font(CobaltType.buttonSmall)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(CobaltColor.onText)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(CobaltColor.text, in: Capsule())
            .glassEffect(.regular.tint(CobaltColor.text).interactive(), in: .capsule)
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help("\(Copy.Editor.render) · ⌘↩")
        #endif
        .accessibilityLabel(running.map { "\(Copy.Editor.render), \(Copy.Editor.renderLine($0))" } ?? Copy.Editor.render)
    }
}

/// A menu's trigger drawn like a small `.cobaltIcon()` circle (menus can't take that button style).
struct EditorShellMenuIcon: View {
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
enum EditorShellCanvas {
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
