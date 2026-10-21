import CobaltKit
import SwiftUI

/// The keyboard of the Mac and iPad editor (apple/CONTRACT-EDITOR.md 4.8). Plain keys (space, J K L, arrows, I O, V B C, delete,
/// esc) are key presses on the screen's own focus, so a text field that has the focus keeps its letters; the command keys
/// (⌘B, ⌘=, ⌘−, ⌘↩, ⌘W) are shortcuts on buttons, hidden behind the screen. ⌘Z and ⇧⌘Z are on the undo and redo buttons.
struct EditorKeyboard: ViewModifier {
    let model: AppModel
    let session: EditSession
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let openRender: () -> Void

    @Environment(EditorHost.self) private var host
    @FocusState private var focused: Bool
    @State private var rate: Double = 0

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
            .onChange(of: session.isPlaying) { _, playing in if !playing { rate = 0 } }
            .onChange(of: session.selection) { _, _ in focused = true }
            .background { shortcuts }
    }

    // MARK: plain keys

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return .ignored
        }
        let big = press.modifiers.contains(.shift)
        switch press.key {
        case .space:
            session.togglePlay()
            return .handled
        case .leftArrow:
            session.step(frames: big ? -session.timing.fps : -1)
            return .handled
        case .rightArrow:
            session.step(frames: big ? session.timing.fps : 1)
            return .handled
        case .delete, .deleteForward:
            guard session.selection != .none else { return .ignored }
            session.remove(session.selection)
            return .handled
        case .escape:
            if session.tool == .crop { session.tool = .select } else if session.selection != .none { session.selection = .none }
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "j": shuttle(backwards: true)
        case "k":
            rate = 0
            session.pause()
        case "l": shuttle(backwards: false)
        case "i":
            guard case .main(let id) = session.selection else { return .ignored }
            session.setIn(atPlayheadFor: id)
        case "o":
            guard case .main(let id) = session.selection else { return .ignored }
            session.setOut(atPlayheadFor: id)
        case "v": session.tool = .select
        case "b": session.tool = .blade
        case "c": session.tool = .crop
        default: return .ignored
        }
        return .handled
    }

    /// J and L: play backwards or forwards; the same key again doubles the rate up to 4×, the other one slows it down.
    private func shuttle(backwards: Bool) {
        let direction: Double = backwards ? -1 : 1
        if rate * direction > 0 {
            rate = direction * min(4, abs(rate) * 2)
        } else {
            rate = direction
        }
        session.shuttle(rate)
    }

    // MARK: command keys

    private var shortcuts: some View {
        ZStack {
            hidden { session.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
            hidden(zoomIn)
                .keyboardShortcut("=", modifiers: .command)
            hidden(zoomOut)
                .keyboardShortcut("-", modifiers: .command)
            hidden(openRender)
                .keyboardShortcut(.return, modifiers: .command)
            #if os(macOS)
            hidden { host.requestClose(model) }
                .keyboardShortcut("w", modifiers: .command)
            #endif
        }
        .accessibilityHidden(true)
    }

    private func hidden(_ action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
    }
}
