import Foundation

/// The pane's state machine (apple/CONTRACT-PANE.md section 1). Every rule about what opening, closing, spanning and
/// the bar do lives here, never in views:
///
/// - Opening an item replaces the current one and keeps `screen` or `span`; from `hidden` or `bar` it opens at `screen`.
///   Opening the item already shown keeps its shelf card; any other item starts at the first card.
/// - Closing never stops anything: a running item goes to `bar`, anything else to `hidden`. The item is kept while
///   hidden, so a drag held on the leading edge can bring it back (`reveal`).
/// - `span` only from `screen`, `unspan` only from `span`. Tapping the bar opens it at `screen`.
/// - A bar whose item stops running goes away (`setRunning(false, for:)`); an item a page reports gone is never running
///   and leaves the pane altogether (`itemGone`).
/// - A running item is never lost to `open`: it moves to the `background` slot, which is drawn as the bar, and its page
///   stays mounted there (a stream keeps playing). Tapping the bar brings it back at `screen`; what was showing is
///   replaced (or, if it is running too, takes the background slot). One bar per window: when two running items want
///   it, a stream outranks the rest (only a stream stops without its page), otherwise the newer one has it; the other
///   is let go of (its bar only: a job, a save or a swarm keeps running where it runs).
/// - A peek (`PaneItem.peek`) is transient: it opens over whatever was there, and `endPeek` (the finger lifted) or a
///   close puts that back exactly. A running item under a peek is drawn in the bar while the peek lasts, so it is never
///   let go of. The route saved for the scene is never the peek (`saved`).
/// - An open that is not the owner's (`open(_:userInitiated: false)`: a page opening itself because something
///   happened) never replaces a running item or one the owner opened while it is on screen (`canAutoOpen`).
/// - A bar restored at launch counts as running until its page says otherwise, but only for a while: a page that has
///   not confirmed it by then (`expireUnconfirmed`) loses the bar.
public struct PaneMachine: Equatable, Sendable {
    public private(set) var route: PaneRoute
    /// What the pane was before a peek opened over it.
    public private(set) var beforePeek: PaneRoute?
    /// The current item is still at work (its page said so, `setRunning`).
    public private(set) var isRunning: Bool
    /// Whether the item under a peek was running when the peek opened (and since, as its page reports).
    public private(set) var beforePeekRunning: Bool
    /// A running item another `open` moved aside: drawn as the bar, its page mounted there.
    public private(set) var background: PaneItem?
    /// The current item was opened by the owner (not by `open(_:userInitiated: false)`).
    public private(set) var userOpened: Bool
    /// A bar restored at launch whose page has not yet said it is running.
    public private(set) var unconfirmed: PaneItem?

    public init(route: PaneRoute = .hidden) {
        self.route = route.restorable
        self.beforePeek = nil
        self.isRunning = false
        self.beforePeekRunning = false
        self.background = nil
        self.userOpened = route.restorable.item != nil
        self.unconfirmed = nil
    }

    public var item: PaneItem? { route.item }
    public var state: PaneState { route.state }
    public var shelf: Int { route.shelf }
    public var isPeeking: Bool { beforePeek != nil }

    /// What to save for the scene: the route under a peek, never the peek itself. The background slot is not saved.
    public var saved: PaneRoute { (beforePeek ?? route).restorable }

    /// The item the bar shows (and whose page is mounted there): the background item, a running item under a peek, or
    /// the current item closed to the bar. Nil: no bar.
    public var barItem: PaneItem? {
        if let background { return background }
        if let before = beforePeek, let item = before.item, beforePeekRunning, before.state != .hidden { return item }
        if route.state == .bar { return route.item }
        return nil
    }

    /// Every item the pane holds on to right now: the current one unless hidden, the one under a peek unless hidden,
    /// and the background one. A page's kept objects (`PaneKeepAlive`) live exactly as long as their item is in here.
    public var heldItems: Set<PaneItem> {
        var out = Set<PaneItem>()
        if let item = route.item, route.state != .hidden { out.insert(item) }
        if let before = beforePeek, let item = before.item, before.state != .hidden { out.insert(item) }
        if let background { out.insert(background) }
        return out
    }

    /// True while the pane holds `item` (on screen, in the bar, under a peek or in the background).
    public func holds(_ item: PaneItem) -> Bool { heldItems.contains(item) }

    /// Whether an open that is not the owner's may show `item` now: never during a peek, never over a running item
    /// (on screen or in the bar), never over an item the owner opened that is on screen.
    public func canAutoOpen(_ item: PaneItem) -> Bool {
        if isPeeking { return false }
        if item == route.item { return true }
        guard route.item != nil, route.state != .hidden else { return true }
        if isRunning { return false }
        if route.isVisible, userOpened { return false }
        return true
    }

    /// The owner opened `item`: replaces the current item, keeps `screen` / `span`, opens at `screen` from `hidden` or
    /// `bar`. A running current item moves to the background slot.
    public mutating func open(_ item: PaneItem) {
        open(item, userInitiated: true)
    }

    /// Shows `item`. `userInitiated: false` (a page opening itself: a paste focusing a save, select mode) does nothing
    /// unless `canAutoOpen(item)`. Returns whether it opened.
    @discardableResult
    public mutating func open(_ item: PaneItem, userInitiated: Bool) -> Bool {
        if !userInitiated, !canAutoOpen(item) { return false }
        if item.isPeek {
            let state: PaneState = route.isVisible ? route.state : .screen
            if beforePeek == nil {
                beforePeek = route
                beforePeekRunning = isRunning
            }
            route = PaneRoute(item: item, state: state, shelf: item == route.item ? route.shelf : 0)
            isRunning = false
            userOpened = userInitiated
            return true
        }
        // a real item opened from a peek: the peek goes, and what was under it is what this open replaces
        if let before = beforePeek {
            route = before
            isRunning = beforePeekRunning
            beforePeek = nil
            beforePeekRunning = false
        }
        let state: PaneState = route.isVisible ? route.state : .screen
        if item == route.item {
            route.state = state
            userOpened = userOpened || userInitiated
            return true
        }
        let wasBackground = item == background
        if wasBackground { background = nil }
        let replacingStream = item.isStream && route.item?.isStream == true
        if item.isStream, background?.isStream == true {
            background = nil
        }
        if !replacingStream {
            moveAside()
        }
        route = PaneRoute(item: item, state: state, shelf: 0)
        isRunning = wasBackground || (replacingStream && isRunning)
        userOpened = userInitiated
        return true
    }

    /// Hides the pane: a running item goes to the bar, anything else to hidden. A peek closes back to what it opened
    /// over.
    public mutating func close() {
        if isPeeking { endPeek(); return }
        guard let item = route.item else { route = .hidden; return }
        guard isRunning else { route.state = .hidden; return }
        if let other = background, other != item {
            if Self.outranks(other, item) {
                // the background keeps the bar; this one's bar is let go of
                route.state = .hidden
                isRunning = false
                return
            }
            background = nil
        }
        route.state = .bar
    }

    /// Hides the pane, first taking `running` as the current item's state (its page's word).
    public mutating func close(running: Bool) {
        if !isPeeking, route.item != nil { isRunning = running }
        close()
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

    /// The bar was tapped: its item opens at `screen`. The background item swaps in: what was showing is replaced, or,
    /// running, takes the background slot.
    public mutating func tapBar() {
        if isPeeking { endPeek() }
        if route.state == .bar, route.item != nil {
            route.state = .screen
            return
        }
        guard let item = background else { return }
        background = nil
        moveAside()
        route = PaneRoute(item: item, state: .screen, shelf: 0)
        isRunning = true
        userOpened = true
    }

    /// Brings a hidden pane's last item (or the bar's) back at `screen`: a drag held on the leading edge.
    public mutating func reveal() {
        guard route.item != nil, route.state == .hidden || route.state == .bar else { return }
        route.state = .screen
    }

    /// A page reports whether `item` is still at work. It counts wherever the pane holds the item (current, under a
    /// peek, background); a report for anything else is ignored. Stopped: its bar goes away (on screen it stays).
    public mutating func setRunning(_ running: Bool, for item: PaneItem) {
        if item == unconfirmed { unconfirmed = nil }
        if item == route.item {
            isRunning = running
            if !running, route.state == .bar { route.state = .hidden }
        } else if item == background {
            if !running { background = nil }
        } else if let before = beforePeek, item == before.item {
            beforePeekRunning = running
            if !running, before.state == .bar { beforePeek?.state = .hidden }
        }
    }

    /// The current item stopped running: a bar goes away; a pane on screen stays as it is.
    public mutating func stoppedRunning() {
        guard let item = route.item else { return }
        setRunning(false, for: item)
    }

    /// A page says `item` is gone or finished for good (a cancelled or removed job, a deleted save, a swarm that no
    /// longer exists, a restored route for an item that is not there): it is never running, and the pane lets go of it
    /// wherever it holds it. Current: the pane hides with nothing to bring back (during a peek, the peek ends).
    public mutating func itemGone(_ item: PaneItem) {
        if item == unconfirmed { unconfirmed = nil }
        if item == background { background = nil }
        if let before = beforePeek, before.item == item {
            beforePeek = .hidden
            beforePeekRunning = false
        }
        guard item == route.item else { return }
        if isPeeking {
            endPeek()
        } else {
            route = .hidden
            isRunning = false
            userOpened = false
        }
    }

    /// The finger lifted from a peek: whatever was there before comes back as it was.
    public mutating func endPeek() {
        guard let before = beforePeek else { return }
        beforePeek = nil
        route = before
        isRunning = beforePeekRunning
        beforePeekRunning = false
        userOpened = route.item != nil
    }

    /// Shows shelf card `index` (clamped to `0..<count` when the count is known).
    public mutating func setShelf(_ index: Int, count: Int? = nil) {
        var i = max(0, index)
        if let count { i = count > 0 ? min(i, count - 1) : 0 }
        route.shelf = i
    }

    /// Restores a saved route (relaunch): the peek and an empty item never come back. A bar counts as running until its
    /// page says otherwise, or until `expireUnconfirmed` (the pane calls it a few seconds after restoring).
    public mutating func restore(_ saved: PaneRoute) {
        beforePeek = nil
        beforePeekRunning = false
        background = nil
        route = saved.restorable
        isRunning = route.state == .bar
        unconfirmed = isRunning ? route.item : nil
        userOpened = route.item != nil
    }

    /// The restored bar's page never said it was running: the bar goes (the item is kept, hidden).
    public mutating func expireUnconfirmed() {
        guard let item = unconfirmed else { return }
        setRunning(false, for: item)
    }

    // MARK: the background slot

    /// The current item, if it is running and not hidden, moves to the background slot (see `outranks`).
    private mutating func moveAside() {
        guard isRunning, let item = route.item, route.state != .hidden else { return }
        if let other = background, other != item, Self.outranks(other, item) { return }
        background = item
    }

    /// Two running items want the one bar: `a`, already there, keeps it only when it outranks `b`.
    static func outranks(_ a: PaneItem, _ b: PaneItem) -> Bool { a.barRank > b.barRank }
}
