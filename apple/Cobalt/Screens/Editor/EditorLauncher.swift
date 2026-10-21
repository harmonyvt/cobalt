import CobaltKit
import SwiftUI

/// The editor's way in and out of the screen, one for the app (`EditorLauncher.shared`). `EditorStore.open` shows nothing
/// until the project has been read, so this holds the "opening" and "couldn't open" states (apple/CONTRACT-EDITOR.md 4.7)
/// that the editor window or cover shows before the session exists, and the two lines other parts leave for each other:
/// the editor's first toast (what `edit` left out) and the line the shell shows once the editor is gone.
@MainActor @Observable
final class EditorLauncher {
    static let shared = EditorLauncher()

    enum State: Equatable {
        case idle
        case opening(String)
        case failed(String, EditError)
    }

    private(set) var state: State = .idle
    /// A line for the editor's first toast (`leftOut`, `notOnServer`), taken by the editor when it appears.
    var firstToast: String?
    /// A line the shell shows once the editor has closed (`closeRendering`, `editorOff`, `projectGone`).
    var afterClose: String?

    private init() {}

    /// The project is being opened, or could not be: the editor shows its opening screen.
    var isBusy: Bool { state != .idle }

    /// Opens a project (the shelf's tap, a context menu's `open`). Success hands over to the session; a failure is shown in
    /// the opening screen with `try again` and `close`. A project that is gone says so on the screen underneath.
    func open(_ projectID: String, model: AppModel) async {
        if model.editor.session?.project.id == projectID { return }
        state = .opening(projectID)
        do {
            try await model.editor.open(projectID)
            state = .idle
        } catch {
            let failure = EditError.from(error)
            switch failure {
            case .notFound:
                afterClose = Copy.Editor.projectGone
                state = .idle
                await model.editor.refresh()
            case .other("unsaved"), .other("cancelled"):
                state = .idle
            default:
                state = .failed(projectID, failure)
            }
        }
    }

    func retry(model: AppModel) async {
        guard case .failed(let id, _) = state else { return }
        await open(id, model: model)
    }

    /// `close` on the opening screen.
    func dismiss() { state = .idle }
}
