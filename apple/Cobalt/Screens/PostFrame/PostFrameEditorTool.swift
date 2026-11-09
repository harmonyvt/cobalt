import CobaltKit
import SwiftUI

// The editor's "post" tool (APP-API-CONTRACT 52.6, the mockup's section 3): the post-frame sheet on the main clip's source
// item, with the clip's trim as `from`/`to` and the details editable. Overlays and text are not drawn into a framed copy in
// this version (the sheet says so). The Mac and iPad have it in the top bar; the iPhone in the tool tray
// (`EditorPhoneSheet.post`).

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

/// The top bar's "post" button (Mac and iPad): opens the sheet on the main clip. Shown only with `features.post_frame`. It
/// also opens by itself once when "open in editor for more" made this project.
struct PostToolButton: View {
    let model: AppModel
    let session: EditSession

    @Environment(EditorHost.self) private var host
    @State private var target: PostFrameTarget?

    var body: some View {
        if model.canMakePostFrames {
            Button { open() } label: { Label(Copy.PostFrame.toolPost, systemImage: Symbol.PostFrame.frame) }
                .buttonStyle(.cobaltIcon(.small, prominent: target != nil))
                .help(Copy.PostFrame.postFrame)
                .sheet(item: $target) { current in
                    PostFrameSheet(model: model, target: current)
                        .cobaltRoot(model: model)
                }
                .modifier(PostToolAutoOpen(model: model, open: open))
        }
    }

    private func open() {
        guard let next = PostFrameTarget.editor(session) else {
            host.show(session.timeline.main.isEmpty ? Copy.PostFrame.noClip : Copy.PostFrame.notOnServer)
            return
        }
        target = next
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
