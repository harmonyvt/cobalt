import CobaltKit
import Observation
import SwiftUI

// The screen pane (apple/CONTRACT-PANE.md): one panel per window, on the leading side, beside whatever tab is open.
//
// `Pane` is the window's store: it wraps the pure `PaneMachine` (CobaltKit, every rule unit tested), knows the window's
// `PanePlacement`, and logs each state change. One per scene, made by `AppShell` and handed down with
// `.environment(pane)`; `PaneHost` draws it and saves its route with `@SceneStorage("pane")`.
//
// What area lanes use (read this, not the views):
//
//   @Environment(Pane.self) private var pane
//
//   pane.open(.post(id))            the OWNER opened an item: replaces the current one, keeps screen / span, from hidden
//                                   or bar opens at screen. A running current item is not lost: it moves to the
//                                   background slot, drawn as the bar (its page stays mounted there, a stream keeps
//                                   playing); tapping the bar brings it back. The page is picked by `PaneDestination`.
//   pane.openIfIdle(.save(id))      a page opening ITSELF because something happened (a paste focusing a save, select
//                                   mode, a planet lifting): never replaces a running item (on screen or in the bar) or
//                                   an item the owner opened that is on screen, never during a peek. Returns whether it
//                                   opened.
//   pane.close(ifShowing: item)     the counterpart: hides the pane only if it is showing `item` (an auto-opened page
//                                   whose reason went away), never someone else's item.
//   pane.peek(id) / pane.endPeek()  the library's hold-to-peek: opens `.peek(id)` over whatever is there; endPeek (the
//                                   finger lifted) puts that back exactly. A running item under the peek stays mounted in
//                                   the bar meanwhile.
//   pane.close()                    hide, from code (a page after a delete): a running item goes to the bar. Never
//                                   blocked. The header's xmark, Escape and VoiceOver's escape use `requestClose()`,
//                                   which a pushed editor can hold (`.paneHoldsClose`).
//   pane.span() / unspan() / toggleSpan()
//   pane.setRunning(_:for:)         RUNNING ITEMS: a page whose item `keepsRunning` (stream, save, swarm, job, studio
//                                   reward / pool video) must report, in every shape (bar included), whether it is still
//                                   at work:
//                                       .onChange(of: isLive, initial: true) { pane.setRunning(isLive, for: item) }
//                                   It counts wherever the pane holds the item (current, background, under a peek); any
//                                   other report is ignored. Closing while running leaves the bar; a bar whose item stops
//                                   running goes away. A route restored at launch in the bar counts as running for
//                                   `confirmWindow` seconds; a page that has not said `true` by then loses the bar.
//   pane.itemGone(item)             the item does not exist any more or is finished for good (a cancelled or removed
//                                   job, a deleted save, a missing swarm, a restored route for an item that is not
//                                   there): never running; the pane lets go of it wherever it holds it (current: the pane
//                                   hides with nothing to bring back). Call it instead of only drawing `PaneGonePage`.
//   pane.holds(item)                the pane still holds `item` (on screen, in the bar, under a peek, in the background):
//                                   what a page asks before letting go of something it opened (a chat connection).
//   pane.keepAlive(name, for: item) { make }
//                                   an object that survives the page being rebuilt (sheet <-> cover, column <-> sheet,
//                                   tall <-> wide <-> split <-> bar): a post's player and playhead, a connection. Kept
//                                   while `holds(item)`; dropped (and told, if it adopts `PaneKeptObject`) when not.
//   pane.provide(obj) / pane.provided(T.self)
//                                   state that lives in a tab but the pane page needs (the library's controller for
//                                   `.selection`): the tab provides it (held weakly), the page reads it.
//
// View modifiers:
//   .paneHoldsClose(hasChanges, ask: { showDiscardConfirm = true })
//                                   on a pushed editor with unsaved changes: Escape, the xmark and VoiceOver's escape run
//                                   `ask` (or do nothing without one), and the compact sheet / cover cannot be swiped
//                                   down. `pane.close(force: true)` (the "discard" answer) closes anyway.
//   .coversPane(pane)               on the CONTENT of any sheet or cover that is not the pane: on a narrow screen a pane
//                                   opened while it is up waits for it to go, then presents (no sleeps needed before
//                                   `pane.open`). Pass the pane when the sheet is presented outside its environment.
//
// The pane draws its own header (span, context label, more, xmark): a page never draws a close.
//
// The compact sheet's size is per item (`PaneItem.compactSheet`): every item is a `.large` sheet, except the library's
// select actions, which are a `.medium` / `.large` sheet that leaves the grid behind it tappable at medium.
@MainActor
@Observable
final class Pane {
    private(set) var machine = PaneMachine()
    /// Where the pane goes in this window (set by `PaneHost` from the window's size).
    private(set) var placement: PanePlacement = .compact
    /// The size `PaneHost` lays out in (the whole window on iPhone and iPad, the detail area on the Mac).
    private(set) var hostSize: CGSize = .zero
    /// The page's title (set by `PanePage`), for VoiceOver's "pane, <title>"; the context label until a page sets one.
    private(set) var title: String?
    /// How many shelf cards the current page has (set by `PanePage`), so ⌘] stops at the last.
    private(set) var shelfCount = 0
    /// Pushed editors holding the close (`.paneHoldsClose`), each with what to do when the owner tries to close.
    private var closeHolds: [UUID: CloseHold] = [:]
    /// Sheets that are not the pane, up right now (`.coversPane`): the compact pane sheet waits for them.
    private var covering: Set<UUID> = []
    /// The scene's saved route has been read (once per scene, however often the host is rebuilt).
    @ObservationIgnored private(set) var restored = false
    @ObservationIgnored private var provided: [ObjectIdentifier: WeakBox] = [:]
    @ObservationIgnored private let kept = PaneKeepAlive()
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Bumped by `provide` so pages reading `provided(_:)` update.
    private var providedVersion = 0

    /// How long a bar restored at launch counts as running before its page must have said so.
    static let confirmWindow: Duration = .seconds(6)

    init(route: PaneRoute = .hidden) {
        machine.restore(route)
    }

    // MARK: reading

    var route: PaneRoute { machine.route }
    var item: PaneItem? { machine.item }
    var state: PaneState { machine.state }
    var shelf: Int { machine.shelf }
    var isPeeking: Bool { machine.isPeeking }
    /// The current item is still at work (its page said so; see the header).
    var isRunning: Bool { machine.isRunning }
    /// On screen or in a sheet (`screen` / `span` with an item).
    var isVisible: Bool { machine.route.isVisible }
    /// The item the bar shows (the current one closed while running, a running item moved aside by another open, or one
    /// under a peek); nil: no bar.
    var barItem: PaneItem? { machine.barItem }
    /// The pane holds `item` (on screen, in the bar, under a peek, or in the background slot).
    func holds(_ item: PaneItem) -> Bool { machine.holds(item) }
    /// A pushed editor holds the close (`.paneHoldsClose`).
    var holdsClose: Bool { !closeHolds.isEmpty }
    /// A sheet that is not the pane is up (`.coversPane`): the compact pane sheet waits for it.
    var isCovered: Bool { !covering.isEmpty }

    /// Whether the pane docks beside the active tab (macOS column) instead of presenting as a single-focus
    /// full-canvas experience (iOS / iPhone Duo / iPad).
    var sitsBesideTab: Bool {
        #if os(macOS)
        return placement != .compact
        #else
        return false
        #endif
    }

    /// The room the tab keeps beside the pane, or nil when the pane takes none (hidden, bar, sheet, or iOS
    /// single-focus full-canvas). Measured on the pane's own host, so on the Mac it is the detail area less the
    /// column, never the window (the sidebar is not the tab's).
    var tabSize: CGSize? {
        guard sitsBesideTab, machine.route.isVisible, hostSize.width > 0 else { return nil }
        return placement.tabExtent(in: hostSize)
    }

    /// `tabSize`'s width. `AppShell` lays its tabs out for it.
    var tabWidth: CGFloat? { tabSize?.width }

    // MARK: actions

    func open(_ item: PaneItem) {
        let previous = machine.item
        change { $0.open(item) }
        if previous != item { replaced() }
    }

    /// Opens `item` only when nothing the owner has is in the way (`PaneMachine.canAutoOpen`). Returns whether it did.
    @discardableResult
    func openIfIdle(_ item: PaneItem) -> Bool {
        let previous = machine.item
        var opened = false
        change { opened = $0.open(item, userInitiated: false) }
        if opened, previous != item { replaced() }
        return opened
    }

    func peek(_ id: String) { open(.peek(id)) }

    func endPeek() {
        guard machine.isPeeking else { return }
        change { $0.endPeek() }
        title = nil
    }

    /// Hides the pane (from code): the bar when the item is still running, else hidden. Never stops anything, and never
    /// held by an editor. `force` reads better at a "discard changes" answer.
    func close(force: Bool = false) {
        change { $0.close() }
    }

    /// Hides the pane if it is showing `item` (and only then).
    func close(ifShowing item: PaneItem) {
        guard machine.item == item, machine.route.isVisible else { return }
        close()
    }

    /// The owner asked to close (the xmark, Escape, VoiceOver's escape, swiping the sheet down): a pushed editor with
    /// unsaved changes holds it and is asked instead.
    func requestClose() {
        if let hold = closeHolds.values.first {
            hold.ask?()
            return
        }
        close()
    }

    func span() { change { $0.span() } }
    func unspan() { change { $0.unspan() } }
    func toggleSpan() { change { $0.toggleSpan() } }
    func tapBar() {
        let previous = machine.item
        change { $0.tapBar() }
        if previous != machine.item { replaced() }
    }
    /// A drag held on the leading edge of a hidden pane: its last item comes back at `screen`.
    func reveal() { change { $0.reveal() } }

    /// A page reports whether `item` is still at work (wherever the pane holds it).
    func setRunning(_ running: Bool, for item: PaneItem) {
        change { $0.setRunning(running, for: item) }
    }

    /// `item` is gone or finished for good: never running, and the pane lets go of it.
    func itemGone(_ item: PaneItem) {
        let previous = machine.item
        change { $0.itemGone(item) }
        if previous != machine.item { replaced() }
    }

    /// An object kept for `item`'s page across its rebuilds (`PaneKeepAlive`), while the pane holds `item`. Asked for an
    /// item the pane does not hold (a preview), it is made and handed back without being kept.
    func keepAlive<T: AnyObject>(_ name: String, for item: PaneItem, make: () -> T) -> T {
        guard machine.holds(item) else { return make() }
        return kept.object(name, for: item, make: make)
    }

    /// A new current item: what the last page reported is not this one's.
    private func replaced() {
        title = nil
        shelfCount = 0
        closeHolds = [:]
    }

    // MARK: shelf

    func setShelf(_ index: Int) { change { $0.setShelf(index, count: shelfCount > 0 ? shelfCount : nil) } }
    func shelfNext() { setShelf(machine.shelf + 1) }
    func shelfBack() { setShelf(machine.shelf - 1) }

    /// `PanePage` reports its card count (and the shelf is clamped to it). `item`: the page's own (`\.paneItem`); a
    /// report from another page (the bar's) is ignored.
    func reportShelf(count: Int, for item: PaneItem? = nil) {
        guard item == nil || item == machine.item, count != shelfCount else { return }
        shelfCount = count
        if count > 0, machine.shelf >= count { change { $0.setShelf(count - 1) } }
    }

    /// `PanePage` reports its title (ignored from another page than the current one's, like the bar's).
    func reportTitle(_ title: String, for item: PaneItem? = nil) {
        guard item == nil || item == machine.item else { return }
        if self.title != title { self.title = title }
    }

    // MARK: holding the close (pushed editors)

    func holdClose(_ id: UUID, ask: (@MainActor () -> Void)?) {
        closeHolds[id] = CloseHold(ask: ask)
    }

    func releaseClose(_ id: UUID) {
        if closeHolds[id] != nil { closeHolds[id] = nil }
    }

    // MARK: other sheets

    func sheetCovers(_ id: UUID, _ up: Bool) {
        if up { covering.insert(id) } else { covering.remove(id) }
    }

    // MARK: placement and restoration (PaneHost)

    func place(_ placement: PanePlacement) {
        guard placement != self.placement else { return }
        let was = self.placement
        self.placement = placement
        if machine.item != nil, machine.state != .hidden {
            Breadcrumbs.add("pane.placement", ["from": .string(was.name), "to": .string(placement.name)])
        }
    }

    /// `PaneHost` measured the room it lays out in.
    func measure(_ size: CGSize) {
        if size != hostSize { hostSize = size }
    }

    /// Restores the scene's saved route, once per scene. A restored bar must be confirmed by its page within
    /// `confirmWindow`. An item opened before the restore (a deep link at launch) wins over the saved route.
    func restoreOnce(_ data: Data?) {
        guard !restored else { return }
        restored = true
        guard machine.item == nil, let route = PaneRoute.decoded(data), route != machine.route else { return }
        change { $0.restore(route) }
        guard machine.unconfirmed != nil else { return }
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmWindow)
            guard !Task.isCancelled, let self else { return }
            self.change { $0.expireUnconfirmed() }
        }
    }

    // MARK: things a tab hands the pane

    /// Makes `object` available to pane pages (held weakly; the tab keeps it alive).
    func provide<T: AnyObject>(_ object: T) {
        provided[ObjectIdentifier(T.self)] = WeakBox(object)
        providedVersion += 1
    }

    /// Withdraws what `provide` gave for `T`.
    func withdraw<T: AnyObject>(_ type: T.Type) {
        provided[ObjectIdentifier(T.self)] = nil
        providedVersion += 1
    }

    /// What a tab provided for `T`, while it is alive.
    func provided<T: AnyObject>(_ type: T.Type) -> T? {
        _ = providedVersion
        return provided[ObjectIdentifier(T.self)]?.object as? T
    }

    // MARK: logging

    private func change(_ body: (inout PaneMachine) -> Void) {
        let before = machine
        body(&machine)
        guard machine != before else { return }
        kept.retain(only: machine.heldItems)
        guard machine.state != before.state || machine.item != before.item || machine.barItem != before.barItem else { return }
        let state = machine.state.rawValue
        let kind = machine.item?.kind ?? "none"
        let values: [String: TelemetryValue] = [
            "state": .string(state), "kind": .string(kind), "placement": .string(placement.name),
            "from": .string(before.state.rawValue), "bar": .string(machine.barItem?.kind ?? "none"),
        ]
        Analytics.event("pane.state", values: values)
        // time the animation this change starts (a `frames` stretch tagged pane_*), finger down or not
        FrameMonitor.paneChanged(values)
        if machine.state != before.state {
            Breadcrumbs.add("pane.\(state)", ["kind": .string(kind)])
        }
    }
}

/// How an item is drawn in the pane's compact sheet (one narrow screen). A small, documented per-item option: only the
/// selection asks for the resizable one (apple/CONTRACT-PANE.md section 3, addendum 2026-11-23).
enum PaneSheetStyle: Equatable {
    /// A `.large` sheet that covers the tab (every item but `.selection`).
    case full
    /// `.medium` and `.large`, opening at `.medium`, with the tab behind it still interactive up through `.medium`: the
    /// library's select actions over a grid whose ticks the owner keeps changing.
    case resizable
}

extension PaneItem {
    /// The compact sheet's style for this item.
    var compactSheet: PaneSheetStyle { self == .selection ? .resizable : .full }
}

private struct CloseHold {
    let ask: (@MainActor () -> Void)?
}

private final class WeakBox {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

// MARK: - view modifiers

extension EnvironmentValues {
    /// The item whose page this view is in (set by the pane around each page: `PaneChrome`, `PaneBar`). Nil outside.
    @Entry var paneItem: PaneItem? = nil
}

extension View {
    /// A pushed editor in a pane page with unsaved changes (`holding`): Escape, the xmark and VoiceOver's escape run
    /// `ask` instead of closing (nothing without it), and the compact sheet and cover cannot be swiped down. Released
    /// when `holding` turns false or the view goes. Answer a "discard" with `pane.close(force: true)`.
    func paneHoldsClose(_ holding: Bool, ask: (@MainActor () -> Void)? = nil) -> some View {
        modifier(PaneCloseHold(holding: holding, ask: ask))
    }

    /// On the content of a sheet or cover that is not the pane: a pane opened on a narrow screen while this is up waits
    /// for it to go, then presents. `pane`: pass it where the sheet is presented outside the pane's environment.
    func coversPane(_ pane: Pane? = nil) -> some View {
        modifier(PaneCoverWatch(explicit: pane))
    }
}

private struct PaneCloseHold: ViewModifier {
    let holding: Bool
    let ask: (@MainActor () -> Void)?
    @Environment(Pane.self) private var pane: Pane?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: holding, initial: true) { _, now in
                if now { pane?.holdClose(id, ask: ask) } else { pane?.releaseClose(id) }
            }
            .onDisappear { pane?.releaseClose(id) }
    }
}

private struct PaneCoverWatch: ViewModifier {
    let explicit: Pane?
    @Environment(Pane.self) private var environment: Pane?
    @State private var id = UUID()

    private var pane: Pane? { explicit ?? environment }

    func body(content: Content) -> some View {
        // a sheet's content disappears when its dismissal has finished, so the pane presents only once it can
        content
            .onAppear { pane?.sheetCovers(id, true) }
            .onDisappear { pane?.sheetCovers(id, false) }
    }
}
