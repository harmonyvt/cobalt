import Foundation

/// The editor's routes (APP-API-CONTRACT 31.12). `HTTPCobaltClient` and `PreviewClient` conform (in `Editor/`); `EditorStore` reaches
/// it as `ctx.client as? EditorClient` and treats a client that is not one like `features.editor` false. Kept apart from
/// `CobaltClient` so no existing fake has to change. Every call throws `EditError` for the server's refusals (and for the
/// network: `.offline`); a `409 error.edit.conflict` is `.conflict(<the server's current project>)`.
public protocol EditorClient: Sendable {
    /// `GET /edits`: the live projects (summaries, no timeline), most recently updated first.
    func editProjects() async throws -> [EditProject]
    /// `POST /edits`: a new project at revision 1 (`title` nil: "untitled edit").
    func createEditProject(title: String?, timeline: EditTimeline) async throws -> EditProject
    /// `GET /edits/<id>`: the project with its timeline, and the library file every item names.
    func editProject(id: String) async throws -> (EditProject, [String: EditSource])
    /// `PUT /edits/<id>`: the project at `revision + 1`; `409` (the server holds another revision) is `.conflict`.
    func saveEditProject(id: String, timeline: EditTimeline, baseRevision: Int, title: String?) async throws -> EditProject
    /// `PATCH /edits/<id>`: only the title (no revision check, `revision + 1`).
    func renameEditProject(id: String, title: String) async throws -> EditProject
    /// `DELETE /edits/<id>`: the project goes (soft); videos rendered from it stay in the library.
    func deleteEditProject(id: String) async throws
    /// `POST /edits/<id>/render`: renders `revision`. The same revision already running answers that render.
    func renderEdit(id: String, revision: Int, notify: Bool) async throws -> EditRender
    /// `GET /edits/renders?limit=`: this key's recent renders, newest first (1...50).
    func editRenders(limit: Int) async throws -> [EditRender]
    /// `GET /edits/renders/<rid>`.
    func editRender(id: String) async throws -> EditRender
    /// `DELETE /edits/renders/<rid>`: cancels (a running one stops within a few seconds); `.finished` once it ended.
    func cancelEditRender(id: String) async throws -> EditRender
    /// `PUT /live/edits/<rid>` (APP-API-CONTRACT 32, `features.edit_live_push`): the render's Live Activity update token, so the
    /// server keeps the activity current with the app closed. True when the server will push.
    func putEditLiveToken(renderID: String, token: String, environment: LiveEnvironment) async throws -> Bool
    /// `DELETE /live/edits/<rid>`: the activity ended on the device; the server forgets the token.
    func deleteEditLiveToken(renderID: String) async throws
}

public extension EditorClient {
    // Previews and fakes have no server to push from.
    func putEditLiveToken(renderID: String, token: String, environment: LiveEnvironment) async throws -> Bool { false }
    func deleteEditLiveToken(renderID: String) async throws {}
}
