import CobaltKit
import SwiftUI

// The editor's "post" tool (APP-API-CONTRACT 52.6, the mockup's section 3): the post-frame sheet on the main clip's source
// item, with the clip's trim as `from`/`to` and the details editable. Overlays and text are not drawn into a framed copy in
// this version (the sheet says so). The editor's tool row has it (`EditorShellTools`).

extension PostFrameTarget {
    /// The editor's target: the selected main clip, else the one under the playhead, else the first; nil when that clip's
    /// file is not a video in the library.
    @MainActor
    static func editor(_ session: EditSession) -> PostFrameTarget? {
        guard let clip = session.selectedMain?.clip ?? session.clipUnderPlayhead?.clip ?? session.timeline.main.first,
              let source = session.source(for: clip.item), source.kind == .video, source.available else { return nil }
        return PostFrameTarget(
            itemID: clip.item, mode: .editor(from: clip.in, to: clip.out), link: nil, poster: source.posterURL,
            width: source.width, height: source.height, duration: source.duration, media: nil)
    }
}

/// Opens the "post" tool once when the editor came up from "open in editor for more" (`PostFrameStore.postToolRequested`).
/// The editor's cover or window is still presenting when the request arrives, and a sheet asked for then would not show: the
/// request is queued (`pending`) and promoted the moment the editor's presentation has settled (`PresentationSettled`:
/// the hosting controller's `viewDidAppear`, which UIKit sends when the transition ends), not after a guessed delay.
struct PostToolAutoOpen: ViewModifier {
    let model: AppModel
    let open: () -> Void

    @State private var pending = false
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .background { PresentationSettled { settled = true } }
            .onChange(of: model.postFrames.postToolRequested, initial: true) { _, requested in
                guard requested else { return }
                model.postFrames.postToolRequested = false
                pending = true
            }
            .onChange(of: pending && settled, initial: true) { _, ready in
                guard ready else { return }
                pending = false
                open()
            }
    }
}

#if os(iOS)
import UIKit

/// Calls `settled` once the view controller it sits in has finished appearing (the end of a cover's or sheet's present
/// transition). A view that appears in a window already on screen reports at once.
private struct PresentationSettled: UIViewControllerRepresentable {
    let settled: () -> Void

    func makeUIViewController(context: Context) -> Probe {
        let probe = Probe()
        probe.settled = settled
        return probe
    }

    func updateUIViewController(_ probe: Probe, context: Context) { probe.settled = settled }

    final class Probe: UIViewController {
        var settled: (() -> Void)?

        override func loadView() {
            let clear = UIView()
            clear.backgroundColor = .clear
            clear.isUserInteractionEnabled = false
            view = clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            settled?()
        }
    }
}
#else
import AppKit

/// The editor is a window on the Mac: settled once its view is in one.
private struct PresentationSettled: NSViewRepresentable {
    let settled: () -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.settled = settled
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.settled = settled }

    final class Probe: NSView {
        var settled: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            let settled = settled
            DispatchQueue.main.async { settled?() }
        }
    }
}
#endif
