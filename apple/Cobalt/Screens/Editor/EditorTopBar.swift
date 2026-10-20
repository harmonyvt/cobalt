import CobaltKit
import SwiftUI

/// The top bar (apple/CONTRACT-EDITOR.md 4.3, 48 pt): the title (click to rename), the save line, undo and redo, the tools
/// `select` `blade` `crop`, the canvas and quality menus, and `render`.
struct EditorTopBar: View {
    let model: AppModel
    let session: EditSession
    @Binding var renderShown: Bool

    @Environment(EditorHost.self) private var host

    var body: some View {
        HStack(spacing: 10) {
            #if os(iOS)
            CloseButton { host.requestClose(model) }
            #endif
            EditorTitleField(session: session)
            saveLine
            Spacer(minLength: 8)
            undoRedo
            tools
            Rectangle().fill(CobaltColor.border).frame(width: 1, height: 20)
            canvasMenu
            qualityMenu
            RenderButton(model: model, session: session, shown: $renderShown)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(EditorColor.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
    }

    // MARK: the save line

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
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(error ? CobaltColor.errorText : CobaltColor.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .layoutPriority(-1)
            .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: undo and redo

    private var undoRedo: some View {
        HStack(spacing: 4) {
            barButton(Symbol.Editor.undo, Copy.Editor.undo, help: "\(Copy.Editor.undo) · ⌘Z", enabled: session.canUndo) { session.undo() }
                .keyboardShortcut("z", modifiers: .command)
            barButton(Symbol.Editor.redo, Copy.Editor.redo, help: "\(Copy.Editor.redo) · ⇧⌘Z", enabled: session.canRedo) { session.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private func barButton(_ symbol: String, _ label: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Platform.isMac ? 30 : 40, height: Platform.isMac ? 30 : 40)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(CobaltColor.text)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: tools

    private var tools: some View {
        HStack(spacing: 4) {
            toolButton(.select, Copy.Editor.toolSelect, key: "V")
            toolButton(.blade, Copy.Editor.toolBlade, key: "B")
            toolButton(.crop, Copy.Editor.toolCrop, key: "C")
        }
    }

    private func toolButton(_ tool: EditSession.Tool, _ title: String, key: String) -> some View {
        let on = session.tool == tool
        return Button { session.tool = tool } label: {
            Text(title)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
                .padding(.horizontal, 11)
                .frame(minHeight: Platform.isMac ? 30 : 40)
                .background(on ? CobaltColor.text : CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(title) · \(key)")
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: canvas and quality

    private var canvasMenu: some View {
        Menu {
            ForEach(EditCanvas.Shape.allCases, id: \.self) { shape in
                Button { setCanvas(shape: shape) } label: {
                    if shape == session.timeline.canvas.shape { Label(shape.rawValue, systemImage: Symbol.keep) } else { Text(shape.rawValue) }
                }
            }
        } label: {
            menuLabel(session.timeline.canvas.shape.rawValue)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(Copy.Editor.canvas)
        .accessibilityLabel(Copy.Editor.canvas)
        .accessibilityValue(session.timeline.canvas.shape.rawValue)
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(Self.qualities, id: \.id) { choice in
                Button { setCanvas(resolution: choice.resolution, fps: choice.fps) } label: {
                    if choice.matches(session.timeline.canvas) {
                        Label(choice.title, systemImage: Symbol.keep)
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            menuLabel(session.qualityLine)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(Copy.Editor.quality)
        .accessibilityLabel(Copy.Editor.quality)
        .accessibilityValue(session.qualityLine)
    }

    private func menuLabel(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(12, .regular, relativeTo: .caption))
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 11)
            .frame(minHeight: Platform.isMac ? 30 : 40)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private struct Quality {
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
}

// MARK: - the title

/// The project's name; a click turns it into a field (return saves, esc cancels, an empty one goes back).
struct EditorTitleField: View {
    let session: EditSession

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(Copy.Editor.renamePlaceholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                    .frame(minWidth: 120, maxWidth: 240)
                    .padding(.horizontal, 8)
                    .frame(minHeight: Platform.isMac ? 28 : 36)
                    .background(EditorColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit(commit)
                    .onKeyPress(.escape) {
                        editing = false
                        return .handled
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused && editing { commit() } }
                    .accessibilityLabel(Copy.Editor.renameField)
            } else {
                Button {
                    text = session.project.title
                    editing = true
                    focused = true
                } label: {
                    Text(session.project.title.isEmpty ? Copy.Editor.untitled : session.project.title)
                        .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 240, alignment: .leading)
                        .frame(minHeight: Platform.isMac ? 28 : 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Copy.Editor.rename)
                .accessibilityLabel(session.project.title)
                .accessibilityHint(Copy.Editor.renameTitle)
            }
        }
    }

    private func commit() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !clean.isEmpty { session.rename(clean) }
    }
}
