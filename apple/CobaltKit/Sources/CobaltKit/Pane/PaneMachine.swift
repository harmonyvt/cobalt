import Foundation

/// The pane's state machine (apple/CONTRACT-PANE.md section 1). Every rule about what opening, closing, spanning and
/// the bar do lives here, never in views:
///
/// - Opening an item replaces the current one and keeps `screen` or `span`; from `hidden` or `bar` it opens at `screen`.
///   Opening the item already shown keeps its shelf card; any other item starts at the first card.
/// - Closing never stops anything: a running item goes to `bar`, anything else to `hidden`. The item is kept while
///   hidden, so a drag held on the leading edge can bring it back (`reveal`).
/// - `span` only from `screen`, `unspan` only from `span`. Tapping the bar opens it at `screen`.
/// - A bar whose item stops running goes away (`stoppedRunning`).
/// - A peek (`PaneItem.peek`) is transient: it opens over whatever was there, and `endPeek` (the finger lifted) or a
///   close puts that back exactly. The route saved for the scene is never the peek (`saved`).
public struct PaneMachine: Equatable, Sendable {
    public private(set) var route: PaneRoute
    /// What the pane was before a peek opened over it.
    public private(set) var beforePeek: PaneRoute?

    public init(route: PaneRoute = .hidden) {
        self.route = route.restorable
        self.beforePeek = nil
    }

    public var item: PaneItem? { route.item }
    public var state: PaneState { route.state }
    public var shelf: Int { route.shelf }
    public var isPeeking: Bool { beforePeek != nil }

    /// What to save for the scene: the route under a peek, never the peek itself.
    public var saved: PaneRoute { (beforePeek ?? route).restorable }

    /// Shows `item`: replaces the current item, keeps `screen` / `span`, opens at `screen` from `hidden` or `bar`.
    public mutating func open(_ item: PaneItem) {
        let state: PaneState = (route.item != nil && (route.state == .screen || route.state == .span)) ? route.state : .screen
        if item.isPeek {
            if beforePeek == nil { beforePeek = route }
        } else {
            beforePeek = nil
        }
        let shelf = item == route.item ? route.shelf : 0
        route = PaneRoute(item: item, state: state, shelf: shelf)
    }

    /// Hides the pane. `running`: the item is still at work (its page said so), so it becomes the bar. A peek closes
    /// back to what it opened over.
    public mutating func close(running: Bool) {
        if isPeeking { endPeek(); return }
        guard route.item != nil else { route = .hidden; return }
        route.state = running ? .bar : .hidden
    }

    /// The whole window (media on one screen, details on the other). Only from `screen`.
    public mutating func span() {
        guard route.item != nil, route.state == .screen else { return }
        route.state = .span
    }

    /// Back beside the tab. Only from `span`.
    public mutating func unspan() {
        guard route.item != nil, route.state == .span else { return }
        route.state = .screen
    }

    /// ⌘⇧F: span from `screen`, unspan from `span`.
    public mutating func toggleSpan() {
        if route.state == .span { unspan() } else { span() }
    }

    /// The bar was tapped: the item opens at `screen`.
    public mutating func tapBar() {
        guard route.item != nil, route.state == .bar else { return }
        route.state = .screen
    }

    /// Brings a hidden pane's last item (or the bar's) back at `screen`: a drag held on the leading edge.
    public mutating func reveal() {
        guard route.item != nil, route.state == .hidden || route.state == .bar else { return }
        route.state = .screen
    }

    /// The running item stopped: a bar goes away; a pane on screen stays as it is.
    public mutating func stoppedRunning() {
        guard route.state == .bar else { return }
        route.state = .hidden
    }

    /// The finger lifted from a peek: whatever was there before comes back as it was.
    public mutating func endPeek() {
        guard let before = beforePeek else { return }
        beforePeek = nil
        route = before
    }

    /// Shows shelf card `index` (clamped to `0..<count` when the count is known).
    public mutating func setShelf(_ index: Int, count: Int? = nil) {
        var i = max(0, index)
        if let count { i = count > 0 ? min(i, count - 1) : 0 }
        route.shelf = i
    }

    /// Restores a saved route (relaunch): the peek and an empty item never come back.
    public mutating func restore(_ saved: PaneRoute) {
        beforePeek = nil
        route = saved.restorable
    }
}
