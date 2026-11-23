#if DEBUG
import CobaltKit
import SwiftUI

/// `#Preview`s of the editor over `AppModel.previewEditor(...)` (apple/CONTRACT-EDITOR.md 4.7), one per state, light and dark.
/// The preview model opens the project a moment after it is built, so the host shows the opening skeleton until the session
/// exists. Pair with `-previewEditor` for simulator runs.
private struct EditorPreviewHost: View {
    @State private var model: AppModel

    init(_ scenario: PreviewScenario, open: String) {
        _model = State(initialValue: AppModel.previewEditor(scenario, open: open))
    }

    var body: some View {
        Group {
            if let session = model.editor.session {
                EditorRoot(model: model, session: session)
            } else {
                EditorOpeningView(model: model, previewWaiting: true)
            }
        }
        .cobaltRoot(model: model)
        .frame(minWidth: 1100, minHeight: 700)
    }
}

#Preview("editor · beach · light") { EditorPreviewHost(.happy, open: "beach").preferredColorScheme(.light) }
#Preview("editor · beach · dark") { EditorPreviewHost(.happy, open: "beach").preferredColorScheme(.dark) }
#Preview("editor · cats · light") { EditorPreviewHost(.happy, open: "cats").preferredColorScheme(.light) }
#Preview("editor · cats · dark") { EditorPreviewHost(.happy, open: "cats").preferredColorScheme(.dark) }
#Preview("editor · empty · light") { EditorPreviewHost(.editorEmpty, open: "beach").preferredColorScheme(.light) }
#Preview("editor · empty · dark") { EditorPreviewHost(.editorEmpty, open: "beach").preferredColorScheme(.dark) }
#Preview("editor · rendering · light") { EditorPreviewHost(.editorRendering, open: "beach").preferredColorScheme(.light) }
#Preview("editor · rendering · dark") { EditorPreviewHost(.editorRendering, open: "beach").preferredColorScheme(.dark) }
#Preview("editor · render failed · light") { EditorPreviewHost(.editorRenderFails, open: "beach").preferredColorScheme(.light) }
#Preview("editor · render failed · dark") { EditorPreviewHost(.editorRenderFails, open: "beach").preferredColorScheme(.dark) }
#Preview("editor · conflict · light") { EditorPreviewHost(.editorConflict, open: "beach").preferredColorScheme(.light) }
#Preview("editor · conflict · dark") { EditorPreviewHost(.editorConflict, open: "beach").preferredColorScheme(.dark) }
#Preview("editor · server down · light") { EditorPreviewHost(.editorFail, open: "beach").preferredColorScheme(.light) }
#Preview("editor · server down · dark") { EditorPreviewHost(.editorFail, open: "beach").preferredColorScheme(.dark) }
/// `EditorShell` (CONTRACT-EDITOR 15.1) at the six sizes of the layout tests, the content size after the safe area. The
/// shell lays itself out from the size alone, so each one shows its regime: compact, tall or wide.
private struct EditorShellPreviewHost: View {
    @State private var model: AppModel
    @State private var host = EditorHost()
    let size: CGSize

    init(_ scenario: PreviewScenario, open: String, width: CGFloat, height: CGFloat) {
        _model = State(initialValue: AppModel.previewEditor(scenario, open: open))
        size = CGSize(width: width, height: height)
    }

    var body: some View {
        Group {
            if let session = model.editor.session {
                EditorShell(model: model, session: session)
                    .environment(host)
            } else {
                EditorOpeningView(model: model, previewWaiting: true)
            }
        }
        .cobaltRoot(model: model)
        .frame(width: size.width, height: size.height)
    }
}

#Preview("shell · iPhone 402×874") { EditorShellPreviewHost(.happy, open: "beach", width: 402, height: 874) }
#Preview("shell · Duo folded 461×940") { EditorShellPreviewHost(.happy, open: "cats", width: 461, height: 940) }
#Preview("shell · Duo open 669×951") { EditorShellPreviewHost(.happy, open: "beach", width: 669, height: 951) }
#Preview("shell · Duo turned 951×669") { EditorShellPreviewHost(.happy, open: "beach", width: 951, height: 669) }
#Preview("shell · iPad 1180×820 · dark") {
    EditorShellPreviewHost(.happy, open: "cats", width: 1180, height: 820).preferredColorScheme(.dark)
}
#Preview("shell · Mac 1280×800") { EditorShellPreviewHost(.happy, open: "beach", width: 1280, height: 800) }
#endif
