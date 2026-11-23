import CobaltKit
import SwiftUI

// Twitch, swarms, names and queue pages in the pane. OWNED BY THE TWITCH/SWARMS/NAMES/QUEUE LANE: replace the bodies
// below, keep the signatures (PaneDestination.swift calls them).
//
// Each function receives the item's payload, the window's `AppModel` and the window's `Pane`, and returns the page
// (normally a `PanePage`; `PaneLoadingPage` while loading, `PaneGonePage` for a deleted item). It is drawn inside the
// pane's own `NavigationStack` with `\.paneShape` set; read anything else from the environment.
//
// - stream(login):  a Twitch channel login: the player in the hero, chat on the shelf (stacked on the details screen
//                   when split). `keepsRunning`: report `pane.setRunning(isPlaying, for: .stream(login))` in every
//                   shape; in `.bar` the page keeps playing (one control: pause / play).
// - swarm(id):      a swarm id (and its board); spanned, results grid + messages. `keepsRunning` while it runs.
// - name(id):       a search name id.
// - job(id):        a queue job id. `keepsRunning` while it runs.
extension PaneDestination {
    @MainActor @ViewBuilder
    static func stream(_ login: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .stream(login))
    }

    @MainActor @ViewBuilder
    static func swarm(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .swarm(id))
    }

    @MainActor @ViewBuilder
    static func name(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .name(id))
    }

    @MainActor @ViewBuilder
    static func job(_ id: String, model: AppModel, pane: Pane) -> some View {
        PanePlaceholderPage(item: .job(id))
    }
}
