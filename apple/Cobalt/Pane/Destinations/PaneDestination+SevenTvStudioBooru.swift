import CobaltKit
import SwiftUI

// 7TV, studio and booru pages in the pane. OWNED BY THE 7TV/STUDIO/BOORU LANE: replace the bodies below, keep the
// signatures (PaneDestination.swift calls them).
//
// Each function receives the item's payload, the window's `AppModel` and the window's `Pane`, and returns the page
// (normally a `PanePage`; `PaneLoadingPage` while loading, `PaneGonePage` for a deleted item). It is drawn inside the
// pane's own `NavigationStack` with `\.paneShape` set (a page may push sub-pages there); read anything else from the
// environment.
//
// - emote(id):          a 7TV emote id; spanned, the emote and its variants.
// - emoteAddToSet(id):  the add-to-set flow for an emote id (7TV login stays a system sheet).
// - reward(id):         a studio channel-point reward id. `keepsRunning` (on air): report with
//                       `pane.setRunning(onAir, for: .reward(id))` in every shape (the bar included).
// - poolVideo(id):      a studio pool video id. `keepsRunning` (on air), same report.
// - booruPost(id):      a booru post id; spanned, the picture.
// - booruFilters:       the booru filters page.
extension PaneDestination {
    @MainActor @ViewBuilder
    static func emote(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .emote(id))
    }

    @MainActor @ViewBuilder
    static func emoteAddToSet(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .emoteAddToSet(id))
    }

    @MainActor @ViewBuilder
    static func reward(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .reward(id))
    }

    @MainActor @ViewBuilder
    static func poolVideo(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .poolVideo(id))
    }

    @MainActor @ViewBuilder
    static func booruPost(_ id: Int, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .booruPost(id))
    }

    @MainActor @ViewBuilder
    static func booruFilters(model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .booruFilters)
    }
}
