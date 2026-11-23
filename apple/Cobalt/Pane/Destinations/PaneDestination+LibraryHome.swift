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
    @MainActor @ViewBuilder
    static func post(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .post(id))
    }

    @MainActor @ViewBuilder
    static func peek(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .peek(id))
    }

    @MainActor @ViewBuilder
    static func selection(model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .selection)
    }

    @MainActor @ViewBuilder
    static func save(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .save(id))
    }
}
