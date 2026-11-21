import CobaltKit
import SwiftUI

// The other screen (Duo building blocks, /mnt/project-files/iphone-duo/building-blocks.html). On a spread the shell keeps
// one pane as the right half of the selected tab (`SpreadPaneColumn`; the screen on the left reflows into the other half): a sheet, a picker or a confirm opens there instead of
// covering the screen it came from, which stays live and touchable. Folded, on an iPhone and on the Mac the same calls
// are ordinary sheets.

/// The pane the shell draws as the right half of a spread.
@MainActor @Observable
final class SpreadPaneHost {
    struct Pane {
        let id: String
        let content: AnyView
        let onClose: @MainActor () -> Void
    }

    private(set) var pane: Pane?
    /// Bumped on every show, so the pane's view (and its state) is new for new content.
    private(set) var generation = 0

    /// Shows `content` in the pane, closing whatever was there. The pane always closes: content with no close of its own
    /// (no `panelDrawsOwnClose()`) gets the round close on the hinge (`SidePanel.swift`).
    func show(id: String, content: AnyView, onClose: @escaping @MainActor () -> Void) {
        if let old = pane, old.id != id {
            pane = nil
            old.onClose()
        }
        generation &+= 1
        pane = Pane(id: id, content: content, onClose: onClose)
    }

    /// Closes the pane (only when it shows `id`, when one is given) and tells its presenter.
    func close(id: String? = nil) {
        guard let p = pane, id == nil || p.id == id else { return }
        pane = nil
        p.onClose()
    }

    func isShowing(_ id: String) -> Bool { pane?.id == id }
}

private struct SpreadPaneKey: EnvironmentKey {
    static let defaultValue: SpreadPaneHost? = nil
}

private struct HingeEdgeKey: EnvironmentKey { static let defaultValue: HorizontalEdge? = nil }

private struct IsSpreadKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PaneCloseKey: EnvironmentKey {
    static let defaultValue: SheetCloseAction? = nil
}

extension EnvironmentValues {
    /// The shell's pane host (nil in previews and the extensions).
    var spreadPane: SpreadPaneHost? {
        get { self[SpreadPaneKey.self] }
        set { self[SpreadPaneKey.self] = newValue }
    }

    /// The side of this screen the hinge is on, while it is one column of a spread with a pane open; nil when it has the
    /// whole window.
    var hingeEdge: HorizontalEdge? {
        get { self[HingeEdgeKey.self] }
        set { self[HingeEdgeKey.self] = newValue }
    }

    /// The window is a spread: two screens' width (`Spread.minWidth` and up) on iPhone and iPad.
    var isSpread: Bool {
        get { self[IsSpreadKey.self] }
        set { self[IsSpreadKey.self] = newValue }
    }

    /// How the pane this view is in closes; nil outside the pane.
    var paneClose: SheetCloseAction? {
        get { self[PaneCloseKey.self] }
        set { self[PaneCloseKey.self] = newValue }
    }
}

/// `dismiss()` for content that is a sheet when folded and a right-hand panel on a wide layout (`SidePanel.swift`): closes
/// whichever it is in. A sheet or pushed screen opened from inside a panel inherits the panel's close, so a view that is
/// itself presented dismisses its own presentation first and never takes the whole panel with it.
@MainActor
struct SheetOrPaneDismiss: DynamicProperty {
    @Environment(\.dismiss) private var system
    @Environment(\.isPresented) private var presented
    @Environment(\.paneClose) private var pane

    func callAsFunction() {
        if let pane, !presented { pane.run() } else { system() }
    }
}

extension View {
    /// `.sheet(item:)`, except on a spread, where `content` opens in the pane on the other screen.
    func spreadSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(SpreadSheetItem(item: item, content: content))
    }

    /// `.sheet(isPresented:)`, except on a spread, where `content` opens in the pane on the other screen. `id` names the
    /// pane, so a second presenter replaces it rather than stacking.
    func spreadSheet<Content: View>(
        isPresented: Binding<Bool>, id: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(SpreadSheetFlag(shown: isPresented, id: id, content: content))
    }
}

private struct SpreadSheetItem<Item: Identifiable, Pane: View>: ViewModifier {
    @Binding var item: Item?
    let content: (Item) -> Pane

    @Environment(\.spreadPane) private var host
    @Environment(\.isSpread) private var spread
    @State private var paneID = "sheet-\(UUID().uuidString)"

    private var usesPane: Bool { spread && host != nil }

    private var sheetItem: Binding<Item?> {
        Binding(get: { usesPane ? nil : item }, set: { item = $0 })
    }

    func body(content view: Content) -> some View {
        view
            .sheet(item: sheetItem) { content($0).environment(\.paneClose, nil) }
            .onChange(of: item.map { AnyHashable($0.id) }, initial: true) { _, id in
                guard usesPane, let host else { return }
                if let shown = item, id != nil {
                    host.show(id: paneID, content: AnyView(content(shown))) { item = nil }
                } else {
                    host.close(id: paneID)
                }
            }
            .onDisappear { host?.close(id: paneID) }
    }
}

private struct SpreadSheetFlag<Pane: View>: ViewModifier {
    @Binding var shown: Bool
    let id: String
    let content: () -> Pane

    @Environment(\.spreadPane) private var host
    @Environment(\.isSpread) private var spread

    private var usesPane: Bool { spread && host != nil }

    private var sheetShown: Binding<Bool> {
        Binding(get: { usesPane ? false : shown }, set: { shown = $0 })
    }

    func body(content view: Content) -> some View {
        view
            .sheet(isPresented: sheetShown) { content().environment(\.paneClose, nil) }
            .onChange(of: shown, initial: true) { _, on in
                guard usesPane, let host else { return }
                if on {
                    host.show(id: id, content: AnyView(content())) { shown = false }
                } else {
                    host.close(id: id)
                }
            }
            .onDisappear { host?.close(id: id) }
    }
}

/// Two equal columns: the tab's screen and, while the other screen shows something, the pane. Both are laid out at their
/// real width, so the screen on the left reflows into its half instead of running on under the pane (owner, 8.26: "it just
/// overlays"). With one child the screen takes the whole width.
struct SpreadColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count > 1 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let left = (bounds.width / 2).rounded()
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: left, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + left, y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width - left, height: bounds.height))
    }
}

/// A tab's screen with the other screen beside it on a spread. Only the selected tab draws the pane (a tab view keeps the
/// others alive, and one pane's content must exist once). It sits inside the tab, so the tab bar or rail stays the
/// window's and is never covered.
struct SpreadPaneColumn<Content: View>: View {
    let active: Bool
    let queue: JobQueue
    @ViewBuilder let content: Content

    @Environment(\.spreadPane) private var host
    @Environment(\.isSpread) private var spread

    private var shows: Bool { active && spread && host?.pane != nil }

    var body: some View {
        SpreadColumns {
            // both columns start below the iPad's floating tab bar while the pane shows, so each column's own bar (title,
            // search, toolbar) draws in its column instead of under the bar
            content
                .padding(.top, shows ? SpreadTopRow.height : 0)
                .environment(\.hingeEdge, shows ? .trailing : nil)
            if shows, let host {
                SpreadPaneView(host: host, queue: queue)
            }
        }
        .background(CobaltColor.bg.ignoresSafeArea())
        .animation(Motion.card, value: shows ? host?.pane?.id : nil)
    }
}

/// The top row of an iPad window, where the floating tab bar sits over the content. It is no safe-area inset, and a
/// column's navigation bar that starts at the window's top shares that row with it: on a spread, the right column's
/// title and buttons drew under the bar as ghost glyphs (8.26 shots). A column that starts below it gets a bar of its own.
enum SpreadTopRow {
    static var height: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 58 : 0
        #else
        return 0
        #endif
    }
}

/// The pane itself: the right column of a spread, with the hinge on its left edge.
struct SpreadPaneView: View {
    let host: SpreadPaneHost
    let queue: JobQueue

    var body: some View {
        if let pane = host.pane {
            HStack(spacing: 0) {
                HingeSeam(queue: queue)
                    .ignoresSafeArea()
                SpreadPaneContent(host: host, pane: pane)
                    .id(host.generation)
                // a little room from the hinge, so a large title or a row never touches the line
                .padding(.leading, 8)
                .padding(.top, SpreadTopRow.height)
            }
            .background(CobaltColor.bg.ignoresSafeArea())
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

/// One pane's content, new with each `show` (so what it said about its close is not carried to the next one). Every pane
/// closes (owner, 8.34): content that draws no close of its own (`panelDrawsOwnClose`) gets a round one on the hinge at
/// the bottom, so neither column gives up a row for it and their tops line up.
private struct SpreadPaneContent: View {
    let host: SpreadPaneHost
    let pane: SpreadPaneHost.Pane

    @State private var ownClose = false

    var body: some View {
        pane.content
            .environment(\.hingeEdge, .leading)
            .environment(\.paneClose, SheetCloseAction { host.close(id: pane.id) })
            .sheetClose { host.close(id: pane.id) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CobaltColor.bg)
            .onPreferenceChange(PanelOwnCloseKey.self) { ownClose = $0 }
            .overlay(alignment: .bottomLeading) {
                if !ownClose {
                    CloseButton(cancels: true) { host.close(id: pane.id) }
                        // centred on the hinge: the pane's leading edge, 8 pt left of the content
                        .alignmentGuide(.leading) { $0[HorizontalAlignment.center] + 8 }
                        .padding(.bottom, 14)
                        .transition(.opacity)
                        .accessibilityIdentifier("panel.close.hinge")
                }
            }
    }
}
