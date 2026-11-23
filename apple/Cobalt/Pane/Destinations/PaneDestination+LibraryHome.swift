import CobaltKit
import SwiftUI

// Library and home (save) pages in the pane. OWNED BY THE LIBRARY/HOME LANE: replace the bodies below, keep the
// signatures (PaneDestination.swift calls them).
//
// Each function receives the item's payload, the window's `AppModel` and the window's `Pane`, and returns the page
// (normally a `PanePage`; `PaneLoadingPage` while loading, `PaneGonePage` for a deleted item). It is drawn inside the
// pane's own `NavigationStack` with `\.paneShape` set; read anything else from the environment.
//
// - post(id):    a media item id. Opened from the library grid, home, a link's file or a chat result.
// - peek(id):    the library's hold-to-peek of a media item: the same page as `post`, transient (`pane.endPeek()` on
//                release puts back whatever was there).
// - selection:   the library's select actions. The picks live in the library's controller: the library tab calls
//                `pane.provide(controller)` and this page reads `pane.provided(LibraryController.self)`.
// - save(id):    a save run (job id) while it runs, then its result. `keepsRunning`: report with
//                `pane.setRunning(isLive, for: .save(id))` in every shape (the bar included).
extension PaneDestination {
    /// The post: `PanePostPage` (Screens/Detail), from just the media's id, so the library, home, a link's file and a chat
    /// result all open the same page. Narrow window: the same page in the sheet.
    @MainActor @ViewBuilder
    static func post(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePostPage(id: id, model: model, pane: pane)
    }

    /// The hold-to-peek: the media alone (`PanePeekPage`, Screens/Library). Takes no touches.
    @MainActor @ViewBuilder
    static func peek(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePeekPage(id: id, model: model)
    }

    /// The select actions (`PaneSelectionPage`, Screens/Library), over the library's own controller.
    @MainActor @ViewBuilder
    static func selection(model: AppModel, pane: Pane) -> some View {
        PaneSelectionPage(model: model, pane: pane)
    }

    /// A save run (`PaneSavePage`, Screens/Home): progress while it works, then the trim's settings and what was made.
    @MainActor @ViewBuilder
    static func save(_ id: String, model: AppModel, pane: Pane) -> some View {
        PaneSavePage(id: id, model: model, pane: pane)
    }
}
