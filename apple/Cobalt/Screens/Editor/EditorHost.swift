import CobaltKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// What the open editor shares between its parts (the Mac and iPad screen, the iPhone screen, the presenter): the toast, the
/// unsaved-changes alert, and the one way to close. `EditorRoot` makes one and puts it in the environment
/// (`@Environment(EditorHost.self)`), so lane 6's `EditorPhoneScreen` reads the same instance.
@MainActor @Observable
final class EditorHost {
    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
    }

    /// The line at the bottom of the editor (a few seconds, then gone). VoiceOver hears it.
    private(set) var toast: Toast?
    /// `closeUnsavedTitle` / `closeUnsavedBody` with `keepEditing` and `closeAnyway`.
    var confirmingClose = false
    /// +1 whenever a render finishes (the success haptic).
    private(set) var doneTick = 0

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ text: String, actionTitle: String? = nil, seconds: Double = 6, action: (@MainActor () -> Void)? = nil) {
        let toast = Toast(text: text, actionTitle: actionTitle, action: action)
        self.toast = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
        EditorAnnouncer.post(text)
    }

    func dismissToast() {
        dismissTask?.cancel()
        toast = nil
    }

    func noteRenderDone() { doneTick += 1 }

    /// The close button, `⌘W` and the window's red button: flushes the autosave and closes; when changes are still unsaved
    /// (or the edit is in conflict) the alert comes up instead. A render in flight does not block closing: it says once, on
    /// the screen underneath, that the render keeps going.
    func requestClose(_ model: AppModel) {
        guard let session = model.editor.session else {
            EditorLauncher.shared.dismiss()
            return
        }
        let rendering = session.activeRender?.isActive == true
        Task {
            if await model.editor.close() {
                if rendering { EditorLauncher.shared.afterClose = Copy.Editor.closeRendering }
            } else {
                confirmingClose = true
            }
        }
    }

    /// `closeAnyway`: leaves whatever is unsaved behind.
    func closeAnyway(_ model: AppModel) {
        let rendering = model.editor.session?.activeRender?.isActive == true
        model.editor.closeAnyway()
        if rendering { EditorLauncher.shared.afterClose = Copy.Editor.closeRendering }
    }
}

/// Posts a VoiceOver announcement (a toast may appear where VoiceOver is not looking).
enum EditorAnnouncer {
    @MainActor
    static func post(_ text: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #elseif canImport(AppKit)
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #endif
    }
}

/// The toast, drawn at the bottom of the editor's root.
struct EditorToastView: View {
    let toast: EditorHost.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(Font.cobalt(13, .medium, relativeTo: .footnote))
                .foregroundStyle(CobaltColor.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    dismiss()
                }
                .font(Font.cobalt(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(CobaltColor.linkBlue)
                .buttonStyle(.plain)
                .frame(minHeight: Metrics.hit)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 520)
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
    }
}
