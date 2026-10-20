#if os(iOS) && DEBUG
import CobaltKit
import SwiftUI

/// `#Preview`s of the iPhone editor over `AppModel.previewEditor(...)` (apple/CONTRACT-EDITOR.md 4.7), one per state, light and
/// dark, forced to the compact width. The preview model opens the project a moment after it is built, so the host shows the
/// opening screen until the session exists. Pair with `-previewEditor` for simulator runs.
private struct EditorPhonePreviewHost: View {
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
        .environment(\.horizontalSizeClass, .compact)
        .cobaltRoot(model: model)
    }
}

#Preview("phone · beach · light") { EditorPhonePreviewHost(.happy, open: "beach").preferredColorScheme(.light) }
#Preview("phone · beach · dark") { EditorPhonePreviewHost(.happy, open: "beach").preferredColorScheme(.dark) }
#Preview("phone · cats · light") { EditorPhonePreviewHost(.happy, open: "cats").preferredColorScheme(.light) }
#Preview("phone · cats · dark") { EditorPhonePreviewHost(.happy, open: "cats").preferredColorScheme(.dark) }
#Preview("phone · empty · light") { EditorPhonePreviewHost(.editorEmpty, open: "beach").preferredColorScheme(.light) }
#Preview("phone · empty · dark") { EditorPhonePreviewHost(.editorEmpty, open: "beach").preferredColorScheme(.dark) }
#Preview("phone · rendering · light") { EditorPhonePreviewHost(.editorRendering, open: "beach").preferredColorScheme(.light) }
#Preview("phone · rendering · dark") { EditorPhonePreviewHost(.editorRendering, open: "beach").preferredColorScheme(.dark) }
#Preview("phone · render failed · light") { EditorPhonePreviewHost(.editorRenderFails, open: "beach").preferredColorScheme(.light) }
#Preview("phone · render failed · dark") { EditorPhonePreviewHost(.editorRenderFails, open: "beach").preferredColorScheme(.dark) }
#Preview("phone · conflict · light") { EditorPhonePreviewHost(.editorConflict, open: "beach").preferredColorScheme(.light) }
#Preview("phone · conflict · dark") { EditorPhonePreviewHost(.editorConflict, open: "beach").preferredColorScheme(.dark) }
#Preview("phone · server down · light") { EditorPhonePreviewHost(.editorFail, open: "beach").preferredColorScheme(.light) }
#Preview("phone · server down · dark") { EditorPhonePreviewHost(.editorFail, open: "beach").preferredColorScheme(.dark) }
#endif
