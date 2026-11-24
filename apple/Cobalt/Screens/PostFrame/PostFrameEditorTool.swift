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
struct PostToolAutoOpen: ViewModifier {
    let model: AppModel
    let open: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: model.postFrames.postToolRequested, initial: true) { _, requested in
            guard requested else { return }
            model.postFrames.postToolRequested = false
            Task {
                // the editor's cover or window is still settling: a sheet asked for in the same pass would not show
                try? await Task.sleep(for: .milliseconds(450))
                open()
            }
        }
    }
}
