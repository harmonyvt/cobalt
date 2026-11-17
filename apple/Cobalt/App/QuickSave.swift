#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CobaltKit

/// Saving from outside the window, with nothing of capystore on screen: the right-click service ("save to
/// capystore", on a selected link or a file in any app) and the "paste from anywhere" keys (settings). Both run the
/// menu bar's paste: one new link, or several files, are queued silently and the menu bar ring shows them; anything
/// the window has to ask about (several links, one file's name, a post with several items) opens the window.
@MainActor
enum QuickSave {
    private static var model: AppModel?
    private static let provider = ServiceProvider()

    /// From the app's `init`, before any scene: a service that launches the app is delivered right after launch.
    static func install(_ model: AppModel) {
        self.model = model
        GlobalHotKey.shared.action = { save(Pasteboard.contents(), via: .shortcut) }
        applyShortcut()
    }

    /// From the delegate, once `NSApp` exists.
    static func registerService() {
        NSApp.servicesProvider = provider
    }

    /// Registers the keys in settings, or takes them away. False when the system refused them.
    @discardableResult
    static func applyShortcut() -> Bool {
        GlobalHotKey.shared.set(model?.settings.pasteShortcut)
    }

    static func save(_ items: [PastedContent], via: JobVia) {
        guard let model else { return }
        if case .needsAttention = PasteRouter.plan(for: items, model: model) {
            handOver(items)
            return
        }
        switch PasteRouter.perform(items, via: via, dropped: false, model: model) {
        case .status:
            // no link, or a link already saving: nothing of capystore is on screen to say so
            NSSound.beep()
        case .queued(_, let ids):
            watch(ids, model: model)
        case .review, .nameFile:
            handOver(items)
        }
    }

    private static func handOver(_ items: [PastedContent]) {
        MenuBarHandoff.shared.stage(items: items)
        reveal()
    }

    /// A job started here that later waits on the owner (a post with several items): the window comes forward with
    /// that job in focus, as the menu bar does for its own.
    private static func watch(_ ids: [Job.ID], model: AppModel) {
        Task { @MainActor in
            var waiting = Set(ids)
            let giveUp = ContinuousClock.now + .seconds(600)
            while !waiting.isEmpty, ContinuousClock.now < giveUp {
                try? await Task.sleep(for: .seconds(1))
                for id in waiting {
                    guard let job = model.queue.job(id), !job.isFinished, !job.isFailed else {
                        waiting.remove(id)
                        continue
                    }
                    if MenuBarPaste.jobNeedsOwner(isPicker: job.isPicker, waitsForTitle: job.pipeline.waitsForTitle) {
                        waiting.remove(id)
                        MenuBarHandoff.shared.stage(focus: id)
                        reveal()
                    }
                }
            }
        }
    }

    private static func reveal() {
        if let reveal = MenuBarHandoff.shared.reveal {
            reveal()
            return
        }
        // the menu bar icon is off, so the window is still there (closing it would have quit)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.title == "capystore" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// The services in the Info.plist (`NSServices`, message `saveToCapystore`): the system calls this with what was
/// selected, a link's text or files.
private final class ServiceProvider: NSObject {
    @MainActor @objc func saveToCapystore(
        _ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        QuickSave.save(Pasteboard.contents(of: pasteboard), via: .share)
    }
}

/// One system-wide hot key (Carbon's `RegisterEventHotKey`, which needs no accessibility permission and works in the
/// sandbox). The key is taken only while capystore is running.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var action: (@MainActor () -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Replaces the registered keys. Nil only unregisters. False when the system refused the new ones.
    @discardableResult
    func set(_ shortcut: GlobalShortcut?) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let shortcut else { return true }
        installHandler()
        let id = EventHotKeyID(signature: 0x6370_7374, id: 1)          // 'cpst'
        var made: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetEventDispatcherTarget(), 0, &made)
        guard status == noErr, let made else { return false }
        hotKey = made
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), globalHotKeyPressed, 1, &spec, nil, &handler)
    }
}

/// Carbon's callback is a C function: no captures, so it goes through the one shared instance.
private func globalHotKeyPressed(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    Task { @MainActor in GlobalHotKey.shared.action?() }
    return noErr
}
#endif
