import CobaltKit
import SwiftUI

/// The editor's way in and out of the screen, one for the app (`EditorLauncher.shared`). `EditorStore.open` shows nothing
/// until the project has been read, so this holds the "opening" and "couldn't open" states (apple/CONTRACT-EDITOR.md 4.7)
/// that the editor window or cover shows before the session exists, and the two lines other parts leave for each other:
/// the editor's first toast (what `edit` left out) and the line the shell shows once the editor is gone.
@MainActor @Observable
final class EditorLauncher {
    static let shared = EditorLauncher()

    private(set) var load = EditorOpenAttempt()
    /// A line for the editor's first toast (`leftOut`, `notOnServer`), taken by the editor when it appears.
    var firstToast: String?
    /// A line the shell shows once the editor has closed (`closeRendering`, `editorOff`, `projectGone`).
    var afterClose: String?

    /// The open still running, so the next one waits until the store's `opening` flag is free.
    @ObservationIgnored private var chain: Task<Void, Never>?

    private init() {}

    /// What the opening screen switches on.
    var state: EditorOpenPhase { load.phase }

    /// The project is being opened, or could not be: the editor shows its opening screen.
    var isBusy: Bool {
        if case .idle = load.phase { return false }
        return true
    }

    /// Changes when a load starts, so the screen's timeout task restarts. Empty while nothing is opening.
    var timeoutKey: String {
        guard case .opening(let id, let since) = load.phase else { return "" }
        return "\(id)|\(since.timeIntervalSinceReferenceDate)"
    }

    /// Opens a project (the shelf's tap, a context menu's `open`). Success hands over to the session; a failure is shown in
    /// the opening screen with `try again` and `close`. A project that is gone says so on the screen underneath.
    func open(_ projectID: String, model: AppModel) async {
        let id = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, model.editor.session?.project.id == id {
            // Already on screen. A leftover failure for this same id would keep the window marked busy.
            switch load.phase {
            case .opening(let openingID, _), .failed(let openingID, _):
                if openingID == id { _ = load.finish(load.attempt, projectID: id, result: .opened) }
            case .idle:
                break
            }
            return
        }
        if case .opening(let openingID, _) = load.phase, openingID == id { return }
        switch load.begin(id, now: Date()) {
        case .rejected:
            return
        case .started(let mine, let openedID):
            let previous = chain
            let task = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, self.load.attempt == mine else { return }
                await self.complete(mine, projectID: openedID, model: model)
            }
            chain = task
            await task.value
        }
    }

    func retry(model: AppModel) async {
        guard case .failed(let id, _) = load.phase else { return }
        await open(id, model: model)
    }

    /// `close` on the opening screen. The in-flight load no longer owns the window, and `EditorStore.open` will not
    /// publish a session for it.
    func dismiss() { load.dismiss() }

    /// The opening screen's clock: once `opening` has run out of time, show the failure instead of spinning.
    func waitForTimeout() async {
        guard case .opening(_, let since) = load.phase else { return }
        let remaining = EditorWindowLoad.timeout - Date().timeIntervalSince(since)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        guard !Task.isCancelled else { return }
        load.timeout(now: Date())
    }

    private func complete(_ mine: Int, projectID: String, model: AppModel) async {
        let result: EditorOpenResult
        do {
            try await model.editor.open(projectID) { [weak self] in
                self?.load.attempt == mine
            }
            result = .opened
        } catch {
            result = EditorWindowLoad.result(of: EditError.from(error))
        }
        if case .notFound = result, mine == load.attempt {
            afterClose = Copy.Editor.projectGone
        }
        let owns = load.finish(mine, projectID: projectID, result: result)
        if EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: owns, phase: load.phase, openedProjectID: projectID, sessionProjectID: model.editor.session?.project.id
        ) {
            _ = await model.editor.close()
        }
        guard owns, case .notFound = result else { return }
        await model.editor.refresh()
    }
}
