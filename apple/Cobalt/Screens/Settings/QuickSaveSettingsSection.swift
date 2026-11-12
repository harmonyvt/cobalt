#if os(macOS)
import AppKit
import CobaltKit
import SwiftUI

/// "from other apps": the keys that save the clipboard while another app is in front, and where the right-click
/// service lives. The row's button records the next key combination pressed in this window; esc leaves it as it was.
struct QuickSaveSettingsSection: View {
    let model: AppModel

    @State private var recorder = ShortcutRecorder()
    @State private var problem: String?

    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Button(title) { toggleRecording() }
                        .font(Font.cobalt(12.5))
                        .accessibilityIdentifier("quick-save-keys")
                    if settings.pasteShortcut != nil, !recorder.isRecording {
                        Button(role: .destructive) { store(nil) } label: {
                            Label(Copy.MenuBar.quickClear, systemImage: Symbol.close)
                        }
                        .buttonStyle(.cobaltIcon(.small))
                        .help(Copy.MenuBar.quickClear)
                    }
                }
            } label: {
                Label(Copy.MenuBar.quickPaste, systemImage: "keyboard")
            }
            if let problem {
                Text(problem).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
            }
        } header: {
            Text(Copy.MenuBar.quickSection).font(CobaltType.caption).textCase(nil)
        } footer: {
            Text(Copy.MenuBar.quickFooter).font(CobaltType.captionSmall).lineSpacing(2)
        }
        .onDisappear { stopRecording() }
    }

    private var title: String {
        if recorder.isRecording { return Copy.MenuBar.quickRecording }
        return settings.pasteShortcut?.display ?? Copy.MenuBar.quickSet
    }

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
            return
        }
        problem = nil
        // the keys in use would fire instead of being read
        GlobalHotKey.shared.set(nil)
        recorder.start { result in
            switch result {
            case .cancelled:
                QuickSave.applyShortcut()
            case .recorded(let shortcut):
                if shortcut.isUsable {
                    store(shortcut)
                } else {
                    problem = Copy.MenuBar.quickNeedsModifier
                    QuickSave.applyShortcut()
                }
            }
        }
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
        QuickSave.applyShortcut()
    }

    private func store(_ shortcut: GlobalShortcut?) {
        let before = settings.pasteShortcut
        settings.pasteShortcut = shortcut
        if QuickSave.applyShortcut() {
            problem = nil
        } else {
            // the system refused them (another app holds them): keep what worked before
            settings.pasteShortcut = before
            QuickSave.applyShortcut()
            problem = Copy.MenuBar.quickTaken
        }
    }
}

/// Reads one key combination from the key window: the next key pressed, with whatever modifiers are held. Esc cancels.
@MainActor @Observable
private final class ShortcutRecorder {
    enum Result {
        case recorded(GlobalShortcut)
        case cancelled
    }

    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var finish: (@MainActor (Result) -> Void)?

    func start(_ finish: @escaping @MainActor (Result) -> Void) {
        stop()
        self.finish = finish
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.take(event) }
            return nil
        }
    }

    /// Ends the recording without a result.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finish = nil
        isRecording = false
    }

    private func take(_ event: NSEvent) {
        let done = finish
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: GlobalShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if event.keyCode == 53, modifiers.isEmpty {                 // esc
            stop()
            done?(.cancelled)
            return
        }
        // a key with no name (a dead key) is not a shortcut: keep listening
        guard let key = GlobalShortcut.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        else { return }
        stop()
        done?(.recorded(GlobalShortcut(keyCode: event.keyCode, modifiers: modifiers, key: key)))
    }
}
#endif
