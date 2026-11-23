import Foundation
import Observation

/// What the open editor's screen remembers that is not the project (apple/CONTRACT-EDITOR.md 15.2): the open tool and
/// inspector page, the drawer's detent, the timeline's zoom and scroll, the picture's zoom. One per open session, owned by
/// the app's `EditorHost` rather than a view's `@State`, so nothing here resets when the window folds, unfolds or turns.
///
/// The selection stays on `EditSession`; playback position and play state are the player's.
@MainActor @Observable
public final class EditorUI {
    /// A tool of the tool row or rail (15.1). Not every tool has a page: `split` and `delete` act at once, `addClip` and
    /// `addLayer` bring up the add sheet on iOS.
    public enum Tool: String, Sendable, CaseIterable {
        case addClip, addLayer, canvas, effects, post
        case trim, split, speed, crop, sound, removeGreen, delete
    }

    /// The inspector's pages (15.1). `library` is the Mac's bin, shown in the inspector's place while adding.
    public enum Page: String, Sendable, CaseIterable {
        case project, library, clip, layer, sound, speed, crop, trim, effects
    }

    /// The tool whose page (or sheet) is up; nil = none.
    public var openTool: Tool?
    public var page: Page = .project
    /// Compact and tall: where the inspector drawer sits. Kept while wide, so the drawer comes back as it was.
    public var drawer: EditorLayout.DrawerDetent = .closed
    /// Timeline zoom, points per second of output.
    public var timelinePointsPerSecond: Double = 36
    /// The timeline's left edge, in seconds of output (a scrolling timeline writes it; a playhead-centred one leaves it).
    public var timelineScrollSeconds: Double = 0
    /// Wide: the height the owner dragged the timeline's top edge to (nil = the layout's own).
    public var timelineHeight: Double?
    /// 1 = the picture fits its slot.
    public var pictureZoom: Double = 1
    /// The render card is up.
    public var renderShown = false
    /// The regime last laid out (nil before the first layout).
    public private(set) var regime: EditorLayout.Regime?

    public init() {}

    /// Opens `tool`. With a page, the inspector shows it (and the drawer comes up at its low detent if it was closed);
    /// without one (the add sheet, post) only `openTool` changes.
    public func open(_ tool: Tool, page: Page?) {
        openTool = tool
        guard let page else { return }
        self.page = page
        if drawer == .closed { drawer = .low }
    }

    /// Shows a page without a tool (the effects menu opened from the picture, a selection taking the place of the library).
    public func show(_ page: Page) {
        self.page = page
        if drawer == .closed { drawer = .low }
    }

    /// Lets go of the open tool: the drawer goes down and the inspector goes back to what is selected.
    public func closeTool(selectionPage: Page = .project) {
        openTool = nil
        page = selectionPage
        drawer = .closed
    }

    /// Called as the regime changes. A gesture in flight is committed first (`commitGesture`, the session's `endGesture`),
    /// so the edit it made is one undo step and the player rebuild it held back is scheduled. Narrowing with a page open
    /// brings that page up in the drawer.
    public func regimeChanged(to new: EditorLayout.Regime, commitGesture: () -> Void) {
        guard new != regime else { return }
        let old = regime
        regime = new
        guard old != nil else { return }
        commitGesture()
        if new != .wide, openTool != nil, drawer == .closed { drawer = .low }
    }

    /// The next detent up (`closed` → `low` → `high`) or down.
    public func stepDrawer(up: Bool) {
        let order: [EditorLayout.DrawerDetent] = [.closed, .low, .high]
        guard let index = order.firstIndex(of: drawer) else { return }
        let next = min(order.count - 1, max(0, index + (up ? 1 : -1)))
        drawer = order[next]
        if drawer == .closed { openTool = nil }
    }
}
