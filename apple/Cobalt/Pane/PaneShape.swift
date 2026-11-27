import CobaltKit
import SwiftUI

/// The shape of the room a pane page is drawn in (`@Environment(\.paneShape)`). A page arranges the same slots per shape
/// (`PanePage` does it for you).
enum PaneShape: Equatable, Sendable {
    /// Taller than wide: a Duo's left screen, the iPad / Mac column, the sheet on one narrow screen.
    case tall
    /// Wider than tall: the Duo's top screen (tall posture), the spanned pane on an iPad or a Mac.
    case wide
    /// Spanned across two screens: `PanePage` draws its media on one and its details on the other, and tells each side
    /// which it is.
    case split(Side)
    /// The running item as a bar over the tab: title, subtitle, a thumb, one control, a hairline of progress.
    case bar

    enum Side: Equatable, Sendable { case media, details }

    var isSplit: Bool { if case .split = self { true } else { false } }
}

/// Where the hinge is while the pane is spanned across two screens, in the pane's own coordinates.
struct PaneHinge: Equatable, Sendable {
    var axis: PanePlacement.Axis
    /// x (vertical hinge) or y (horizontal hinge) of the line.
    var position: CGFloat
}

extension EnvironmentValues {
    /// The shape of the pane room this view is in. Outside the pane: `.tall`.
    @Entry var paneShape: PaneShape = .tall
    /// The hinge of a spanned pane on two screens (nil otherwise).
    @Entry var paneHinge: PaneHinge? = nil
    /// The server can't be reached: pane actions that need it (`PaneAction.needsServer`) are paused and say so (a caption on the
    /// group, "needs network" on the tile), except the ones the sync outbox holds (`PaneAction.queuesOffline`).
    @Entry var paneOffline = false
    /// The height of the header when a page opts into a floating overlay header (0 when the pane draws its dedicated top bar).
    @Entry var paneHeaderHeight: CGFloat = 0
    /// Live hardware reserved regions (`ReservedRegion(.division)` and `.occlusion`) measured by `PaneHost`.
    @Entry var paneReservedRegions: DuoReservedRegions = .empty
    /// Full keyboard-ignoring size of `PaneHost`, allowing single-focus pages (e.g. Twitch Watch) to detect software
    /// keyboard height reliably in pure SwiftUI.
    @Entry var paneHostSize: CGSize = .zero
    /// Live window container safe-area insets measured by `PaneHost` (outside any child `.ignoresSafeArea(.top)`).
    @Entry var paneSafeAreaInsets: EdgeInsets = EdgeInsets()
}

/// One thing a pane page can do: a header icon button (`PanePage(actions:)`, up to 2), a big button in `PaneActionGrid`
/// (up to 4), or a row of the header's `more` menu (`PanePage(more:)`, the rest).
struct PaneAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    /// Paused while the server can't be reached (`\.paneOffline`): the tile says "needs network" and a tap says why.
    var needsServer: Bool
    /// The sync outbox holds this change while the server is away, so the action stays enabled offline and says "queued".
    /// Only for a call that lands in `LibrarySync`'s outbox when `sync.engine` is on (`AppModel.libraryQueuesEdits` is the
    /// engine check): hide, unhide and the status choices through `LibraryModel.setStatus`. A call site passes it with
    /// `needsServer: true`; with the engine off it is false and the action is paused like any other.
    var queuesOffline: Bool
    var isDisabled: Bool
    /// Work is in flight for this action: the tile swaps its icon for a progress spinner and ignores taps.
    var isWorking: Bool
    /// Not empty: the action opens these as a menu instead of running `perform` (`share`: file, share link, direct link).
    var choices: [PaneAction]
    /// Not empty: a short tap runs `perform`, while pressing and holding reveals these choices above the tile and
    /// releasing on one runs it (`copy share link` → `share` / `direct`).
    var holdChoices: [PaneAction]
    let perform: @MainActor () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, needsServer: Bool = false, queuesOffline: Bool = false,
         disabled: Bool = false, working: Bool = false, id: String? = nil, choices: [PaneAction] = [],
         holdChoices: [PaneAction] = [], perform: @escaping @MainActor () -> Void) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.needsServer = needsServer
        self.queuesOffline = queuesOffline
        self.isDisabled = disabled
        self.isWorking = working
        self.choices = choices
        self.holdChoices = holdChoices
        self.perform = perform
    }

    /// Off: disabled, or needs the server while it is away (and the outbox cannot hold it).
    func off(offline: Bool) -> Bool { isDisabled || pausedOffline(offline) }

    /// Needs the server and it is away, and nothing holds the change meanwhile: the tile says "needs network".
    func pausedOffline(_ offline: Bool) -> Bool { needsServer && offline && !queuesOffline }

    /// The server is away and the outbox holds this change: the tile stays enabled and says it is queued.
    func queuedOffline(_ offline: Bool) -> Bool { needsServer && offline && queuesOffline && !isDisabled }
}

extension AppModel {
    /// The library's sync engine is on and serving edits (`syncStatus` is nil while `sync.engine` is off and `.disabled` after
    /// `GET /sync` answered 404), so a status change made offline lands in the outbox (`LibraryModel.setStatus`) instead of
    /// failing. The `queuesOffline:` of the actions whose call goes through it.
    var libraryQueuesEdits: Bool {
        guard let status = library.syncStatus else { return false }
        return status.state != .disabled
    }

    /// The sync engine says the server is away (`.offline`): a change just made is in its outbox, not yet on the server. Read
    /// after the change, so the receipt says "queued" instead of "done".
    var libraryHoldsEditsForServer: Bool {
        if case .offline? = library.syncStatus?.state { return true }
        return false
    }
}

/// The more-menu actions a page hands the header (`PanePage(more:)`).
struct PaneMoreKey: PreferenceKey {
    static let defaultValue: [PaneAction] = []
    static func reduce(value: inout [PaneAction], nextValue: () -> [PaneAction]) { value += nextValue() }
}

/// Whether the current page opts into floating the pane's header over full-bleed media (e.g. a stream filling the Duo's
/// top screen). Default is `false`: `PaneChrome` reserves a dedicated top header bar above the page content.
struct PaneFloatingHeaderKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Whether the current page renders its own Clear Liquid Glass single-focus top HUD (back/close, identity pill, actions)
/// so `PaneChrome` suppresses its standard header slab and lets media run edge-to-edge.
struct PaneHidesChromeHeaderKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Whether the current page supplies its own system `.toolbar` items (e.g. iPhone Duo Vertical Controls rail + Tabletop
/// top bar) so `PaneChrome` keeps the navigation bar toolbar visible instead of hiding it.
struct PaneShowsSystemToolbarKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
