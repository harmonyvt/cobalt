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
    /// The server can't be reached: pane actions that need it (`PaneAction.needsServer`) are dimmed.
    @Entry var paneOffline = false
    /// The height of the header the pane draws over the top of its page (its buttons float over the hero).
    @Entry var paneHeaderHeight: CGFloat = 0
}

/// One thing a pane page can do: a header icon button (`PanePage(actions:)`, up to 2), a big button in `PaneActionGrid`
/// (up to 4), or a row of the header's `more` menu (`PanePage(more:)`, the rest).
struct PaneAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    /// Dimmed and disabled while the server can't be reached (`\.paneOffline`).
    var needsServer: Bool
    var isDisabled: Bool
    let perform: @MainActor () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, needsServer: Bool = false, disabled: Bool = false,
         id: String? = nil, perform: @escaping @MainActor () -> Void) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.needsServer = needsServer
        self.isDisabled = disabled
        self.perform = perform
    }

    /// Off: disabled, or needs the server while it is away.
    func off(offline: Bool) -> Bool { isDisabled || (needsServer && offline) }
}

/// The more-menu actions a page hands the header (`PanePage(more:)`).
struct PaneMoreKey: PreferenceKey {
    static let defaultValue: [PaneAction] = []
    static func reduce(value: inout [PaneAction], nextValue: () -> [PaneAction]) { value += nextValue() }
}
