#if os(iOS)
import CobaltKit
import SwiftUI

/// The top of the iPhone editor (apple/CONTRACT-EDITOR.md 4.4, 10): `close`, `undo`, `redo`; the title with the save line under
/// it (tap renames, hold or `…` opens canvas, quality, rename and delete); and `render`, which shows the progress while one runs.
struct EditorPhoneHeader: View {
    let model: AppModel
    let session: EditSession
    let openRender: () -> Void

    @Environment(EditorHost.self) private var host
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 4) {
            leading
            titleBlock
            EditorPhoneRenderButton(session: session, action: openRender)
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .alert(Copy.Editor.renameTitle, isPresented: $renaming) {
            TextField(Copy.Editor.renamePlaceholder, text: $draft)
            Button(Copy.Editor.cancel, role: .cancel) {}
            Button(Copy.Editor.done) { commitRename() }
        }
        .confirmationDialog(Copy.Editor.deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(Copy.Editor.deleteConfirm, role: .destructive) { deleteProject() }
            Button(Copy.Editor.cancel, role: .cancel) {}
        } message: {
            Text(Copy.Editor.deleteBody)
        }
    }

    // MARK: close, undo, redo

    private var leading: some View {
        HStack(spacing: 0) {
            EditorPhoneIconButton(symbol: Symbol.Editor.close, label: Copy.Editor.close, enabled: true) {
                host.requestClose(model)
            }
            EditorPhoneIconButton(symbol: Symbol.Editor.undo, label: Copy.Editor.undo, enabled: session.canUndo) {
                session.undo()
            }
            EditorPhoneIconButton(symbol: Symbol.Editor.redo, label: Copy.Editor.redo, enabled: session.canRedo) {
                session.redo()
            }
        }
    }

    // MARK: the title and the save line

    private var titleBlock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { startRename() } label: {
                    Text(session.project.title.isEmpty ? Copy.Editor.untitled : session.project.title)
                        .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { menuItems }
                .accessibilityLabel(session.project.title)
                .accessibilityHint(Copy.Editor.renameTitle)
                Menu { menuItems } label: {
                    Image(systemName: Symbol.Editor.more)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(CobaltColor.caption)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Copy.Editor.moreOptions)
            }
            saveLine
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var saveLine: some View {
        switch session.saveState {
        case .failed:
            Button { Task { await session.retrySave() } } label: { line(session.saveLine, error: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.Editor.tryAgain)
        case .conflict:
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

    // MARK: the menu: canvas, quality, rename, delete

    @ViewBuilder
    private var menuItems: some View {
        Menu(Copy.Editor.canvas) {
            ForEach(EditCanvas.Shape.allCases, id: \.self) { shape in
                Button { setCanvas(shape: shape) } label: { choice(shape.rawValue, on: shape == session.timeline.canvas.shape) }
            }
        }
        Menu(Copy.Editor.quality) {
            ForEach(Self.qualities) { quality in
                Button { setCanvas(resolution: quality.resolution, fps: quality.fps) } label: {
                    choice(quality.title, on: quality.matches(session.timeline.canvas))
                }
            }
        }
        Button { startRename() } label: { Label(Copy.Editor.rename, systemImage: "pencil") }
        Button(role: .destructive) { confirmingDelete = true } label: {
            Label(Copy.Editor.deleteEdit, systemImage: Symbol.Editor.delete)
        }
    }

    @ViewBuilder
    private func choice(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: Symbol.keep) } else { Text(title) }
    }

    private struct Quality: Identifiable {
        let resolution: EditCanvas.Resolution
        let fps: Int
        var id: String { title }
        var title: String { Copy.Editor.qualityLabel(resolution.rawValue, fps) }
        func matches(_ canvas: EditCanvas) -> Bool { canvas.resolution == resolution && canvas.fps == fps }
    }

    private static let qualities: [Quality] = [
        Quality(resolution: .p1080, fps: 30), Quality(resolution: .p1080, fps: 60),
        Quality(resolution: .p720, fps: 30), Quality(resolution: .p720, fps: 60),
    ]

    private func setCanvas(shape: EditCanvas.Shape) {
        let c = session.timeline.canvas
        session.setCanvas(EditCanvas(shape: shape, resolution: c.resolution, fps: c.fps))
    }

    private func setCanvas(resolution: EditCanvas.Resolution, fps: Int) {
        session.setCanvas(EditCanvas(shape: session.timeline.canvas.shape, resolution: resolution, fps: fps))
    }

    // MARK: rename and delete

    private func startRename() {
        draft = session.project.title
        renaming = true
    }

    private func commitRename() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { session.rename(clean) }
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

/// A 44 pt round icon button of the header; the label is what VoiceOver reads.
struct EditorPhoneIconButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 34, height: 34)
                .background(CobaltColor.elevated, in: Circle())
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// `render` (primary pill). While a render of this project runs it carries the progress (`waiting · 1 ahead`, `preparing`,
/// `rendering 40%`, `finishing`); either way it opens the render sheet.
struct EditorPhoneRenderButton: View {
    let session: EditSession
    let action: () -> Void

    private var running: EditRender? {
        guard let r = session.activeRender, r.isActive else { return nil }
        return r
    }

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            .accessibilityLabel(running.map { "\(Copy.Editor.render), \(Copy.Editor.renderLine($0))" } ?? Copy.Editor.render)
    }

    @ViewBuilder
    private var content: some View {
        if let running {
            HStack(spacing: 5) {
                ProgressView(value: running.progress.map { min(1, max(0, $0)) })
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text(Copy.Editor.renderLine(running))
                    .monospacedDigit()
                    .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
            }
            .lineLimit(1)
        } else {
            Text(Copy.Editor.render)
                .lineLimit(1)
        }
    }
}
#endif
