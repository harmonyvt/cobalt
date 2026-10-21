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
                EditorOpeningView(model: model)
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
#endif
