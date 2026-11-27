import CobaltKit
import SwiftUI

// Twitch, swarms, names and queue pages in the pane. OWNED BY THE TWITCH/SWARMS/NAMES/QUEUE LANE.
//
// Each function receives the item's payload, the window's `AppModel` and the window's `Pane`, and returns the page
// (normally a `PanePage`; `PaneLoadingPage` while loading, `PaneGonePage` for a deleted item). It is drawn inside the
// pane's own `NavigationStack` with `\.paneShape` set; read anything else from the environment.
//
// - stream(login):  a Twitch channel login: the player in the hero, chat on the shelf (stacked on the details screen
//                   when split). `keepsRunning`: `pane.setRunning(true, for: .stream(login))` in every shape; in `.bar`
//                   the page keeps playing (one control: pause / play). `TwitchStreamPage`.
// - swarm(id):      a swarm id (and its board); spanned, results grid + messages. `keepsRunning` while it runs.
//                   `SwarmPage`.
// - name(id):       a search name id (`NamePane.newID` is a name not made yet). `NamePage`.
// - job(id):        a queue job id (`Job.id.uuidString`). `keepsRunning` while it runs. `QueueJobPage`.
extension PaneDestination {
    @MainActor @ViewBuilder
    static func stream(_ login: String, model: AppModel, pane: Pane) -> some View {
        TwitchStreamPage(login: login, model: model)
    }

    @MainActor @ViewBuilder
    static func dualStream(primary: String, secondary: String, model: AppModel, pane: Pane) -> some View {
        TwitchStreamPage(channels: [primary, secondary], model: model)
    }

    @MainActor @ViewBuilder
    static func multiStream(channels: [String], model: AppModel, pane: Pane) -> some View {
        TwitchStreamPage(channels: channels, model: model)
    }

    @MainActor @ViewBuilder
    static func swarm(_ id: String, model: AppModel, pane: Pane) -> some View {
        SwarmPage(id: id, model: model)
    }

    @MainActor @ViewBuilder
    static func name(_ id: String, model: AppModel, pane: Pane) -> some View {
        NamePage(id: id, model: model)
    }

    @MainActor @ViewBuilder
    static func job(_ id: String, model: AppModel, pane: Pane) -> some View {
        QueueJobPage(id: id, model: model)
    }
}

// MARK: - letting go

extension View {
    /// Runs `gone` once the pane no longer holds `item` (`Pane.holds`: not on screen, not in the bar, not under a peek, not
    /// in the background: it was replaced by a page that is not running, or hidden). A page is rebuilt whenever the pane changes shape (beside the tab, spanned, the bar), which removes one
    /// view and adds the next in the same moment, so this waits a beat and asks the pane what it holds now. Use it to
    /// close what the page opened (a chat connection, a polled swarm, an editor): the next page of the same kind may
    /// already have taken it over, so `gone` must check that what it closes is still its own.
    func paneKeeps(_ item: PaneItem, gone: @escaping @MainActor () -> Void) -> some View {
        modifier(PaneKeeps(item: item, gone: gone))
    }
}

private struct PaneKeeps: ViewModifier {
    let item: PaneItem
    let gone: @MainActor () -> Void
    @Environment(Pane.self) private var pane: Pane?

    func body(content: Content) -> some View {
        content.onDisappear {
            let pane = pane
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard let pane else { return }
                // held = on screen, in the bar, under a peek or in the background: a stream replaced by a peek or moved to the bar stays
                if !pane.holds(item) { gone() }
            }
        }
    }
}

#if DEBUG
/// The page alone in a shape, with a pane holding `item` (the previews of this lane's pages).
struct AreaPageHost<Content: View>: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    @ViewBuilder let content: Content
    @State private var pane: Pane

    init(item: PaneItem, shape: PaneShape, hinge: PaneHinge? = nil, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.hinge = hinge
        self.content = content()
        _pane = State(initialValue: Pane(route: PaneRoute(item: item, state: shape == .bar ? .bar : .screen)))
    }

    var body: some View {
        content
            .environment(\.paneShape, shape)
            .environment(\.paneHinge, hinge)
            .environment(\.paneHeaderHeight, shape == .bar ? 0 : PaneChrome.headerHeight)
            .background(CobaltColor.bg)
            .environment(pane)
    }
}
#endif
