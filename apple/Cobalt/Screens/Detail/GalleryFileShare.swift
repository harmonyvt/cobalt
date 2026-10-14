import SwiftUI

#if os(iOS)
import UIKit

/// Presents the system share sheet for file URLs only. Anchored in the background of the gallery actions.
/// One sheet per list: a second update while one is up does not present another. Finishing (share or cancel) clears the list.
struct GalleryFileShare: UIViewControllerRepresentable {
    @Binding var fileURLs: [URL]

    func makeUIViewController(context: Context) -> UIViewController {
        let host = AnchorController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let host = controller as? AnchorController else { return }
        let coordinator = context.coordinator
        coordinator.fileURLs = $fileURLs
        host.onReady = { [weak host] in
            guard let host else { return }
            coordinator.present(from: host)
        }
        coordinator.present(from: host)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var fileURLs: Binding<[URL]> = .constant([])
        var presenting = false

        fileprivate func present(from host: AnchorController) {
            let urls = fileURLs.wrappedValue.filter(\.isFileURL)
            guard !urls.isEmpty else {
                if host.presentedViewController == nil { presenting = false }
                return
            }
            // already up: do not present a second controller
            guard host.presentedViewController == nil, !presenting else { return }
            guard host.view.window != nil else { return }
            presenting = true
            let urlsToShare = urls
            // The next turn: not inside the SwiftUI update, and not on the click that asked for the sheet.
            Task { @MainActor [weak self, weak host] in
                guard let self, let host else { return }
                guard host.presentedViewController == nil, host.view.window != nil else {
                    self.presenting = false
                    return
                }
                let sheet = UIActivityViewController(activityItems: urlsToShare, applicationActivities: nil)
                if let popover = sheet.popoverPresentationController {
                    popover.sourceView = host.view
                    let bounds = host.view.bounds
                    popover.sourceRect = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
                }
                sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
                    Task { @MainActor in
                        self?.presenting = false
                        self?.fileURLs.wrappedValue = []
                    }
                }
                host.present(sheet, animated: true)
            }
        }
    }
}

/// A clear controller whose only job is to present the sheet. `didMoveToWindow` retries a present that arrived early.
private final class AnchorController: UIViewController {
    var onReady: (@MainActor () -> Void)?

    override func loadView() {
        let anchor = AnchorView()
        anchor.owner = self
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        view = anchor
    }
}

private final class AnchorView: UIView {
    weak var owner: AnchorController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let owner = owner
        Task { @MainActor in owner?.onReady?() }
    }
}
#else
import AppKit

/// Presents the system share picker for file URLs only. `updateNSView` shows it once per list, not on every pass.
struct GalleryFileShare: NSViewRepresentable {
    @Binding var fileURLs: [URL]

    func makeNSView(context: Context) -> NSView {
        AnchorView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let host = view as? AnchorView else { return }
        let coordinator = context.coordinator
        coordinator.fileURLs = $fileURLs
        host.onReady = { [weak host] in
            guard let host else { return }
            coordinator.present(from: host)
        }
        coordinator.present(from: host)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var fileURLs: Binding<[URL]> = .constant([])
        /// The list currently shown. Equal to the binding means this pass must not show another picker.
        var shown: [URL] = []
        var picker: NSSharingServicePicker?

        fileprivate func present(from host: AnchorView) {
            let urls = fileURLs.wrappedValue.filter(\.isFileURL)
            guard !urls.isEmpty else {
                shown = []
                return
            }
            guard host.window != nil else { return }
            guard shown != urls else { return }
            shown = urls
            let urlsToShare = urls
            // The next turn: the click's mouse-up has landed, so it does not dismiss the picker.
            // The picker is kept after a service is chosen; releasing it there cancels the send.
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, host.window != nil,
                      self.fileURLs.wrappedValue.filter(\.isFileURL) == urlsToShare else {
                    if self?.shown == urlsToShare { self?.shown = [] }
                    return
                }
                let picker = NSSharingServicePicker(items: urlsToShare)
                picker.delegate = self
                self.picker = picker
                let bounds = host.bounds
                picker.show(
                    relativeTo: bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds,
                    of: host, preferredEdge: .minY)
            }
        }

        /// Chosen service, or nil when the picker is dismissed. The list clears either way.
        /// A chosen service keeps the picker: dropping it here cancels the send.
        nonisolated func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
        ) {
            let cancelled = service == nil
            Task { @MainActor in
                if cancelled { picker = nil }
                shown = []
                fileURLs.wrappedValue = []
            }
        }
    }
}

/// A clear view the picker is positioned against. It does not take clicks.
private final class AnchorView: NSView {
    var onReady: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let ready = onReady
        Task { @MainActor in ready?() }
    }
}
#endif
