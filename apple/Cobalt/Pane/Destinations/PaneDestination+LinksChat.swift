import CobaltKit
import SwiftUI

// Links and chat pages in the pane. OWNED BY THE LINKS/CHAT LANE: replace the bodies below, keep the signatures
// (PaneDestination.swift calls them).
//
// Each function receives the item's payload, the window's `AppModel` and the window's `Pane`, and returns the page
// (normally a `PanePage`; `PaneLoadingPage` while loading, `PaneGonePage` for a deleted item). It is drawn inside the
// pane's own `NavigationStack` with `\.paneShape` set; read anything else from the environment.
//
// - link(id):        a share link (`ShareSet`) id; spanned, its files go across both screens.
// - collection(id):  a collection id.
// - chat: anything the AI made opens as `.post(id)` (PaneDestination+LibraryHome.swift); the conversation itself is
//   never the pane. A chat result whose job still runs may report `pane.setRunning(true, for: .post(id))` to keep a bar.
extension PaneDestination {
    @MainActor @ViewBuilder
    static func link(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .link(id))
    }

    @MainActor @ViewBuilder
    static func collection(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .collection(id))
    }
}
