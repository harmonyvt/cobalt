import CobaltKit
import SwiftUI

// One rule for every right-hand panel of a wide layout (owner, 8.34: "whenever you're using split screen there always has
// to be a back button ... it always needs to be able to hide"). The panels are:
//
//   - the spread pane (`SpreadPaneView`): sheets, pickers, booru posts and filters, a second tab, the select panel
//   - the list-and-detail splits (`DetailSplit`): chat, links, swarms
//   - the library's detail column (`LibraryInspector`)
//
// Each one closes the same three ways: its own close button at the top of the panel (`panelClose`), anything inside that
// calls `SheetOrPaneDismiss` (a "close" or "done" written for a sheet closes the panel instead of doing nothing), and, for
// spread-pane content that draws no close of its own, the round close on the hinge.

extension View {
    /// The panel's close for the root of a panel's navigation stack: an icon button at the top of the panel, and the
    /// `paneClose` action for anything inside that closes itself with `SheetOrPaneDismiss`.
    func panelClose(_ close: @escaping @MainActor () -> Void) -> some View {
        modifier(PanelCloseToolbar(close: close))
    }

    /// Spread-pane content that draws a close (or done) of its own and closes with `SheetOrPaneDismiss`: the pane then
    /// draws no second close on the hinge.
    func panelDrawsOwnClose() -> some View {
        preference(key: PanelOwnCloseKey.self, value: true)
    }
}

struct PanelOwnCloseKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct PanelCloseToolbar: ViewModifier {
    let close: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: Self.placement) {
                    Button(Copy.Duo.hidePanel, systemImage: Symbol.Duo.hidePanel) { close() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("panel.close")
                        #if os(macOS)
                        .help(Copy.Duo.hidePanel)
                        #endif
                }
            }
            .environment(\.paneClose, SheetCloseAction(run: close))
    }

    /// Top left on iPhone and iPad, beside the hinge where a pushed screen has its back button. The Mac's window toolbar
    /// starts at the far left, so there it sits with the panel's own actions on the right.
    private static var placement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .primaryAction
        #endif
    }
}

/// A list with what it opened beside it: the list keeps the whole width while nothing is open (#216), then gives the right
/// side to the detail behind a hinge. The detail always has the panel's close (`panelClose`).
struct DetailSplit<Value: Hashable, ListContent: View, Detail: View>: View {
    let queue: JobQueue
    var listWidth: CGFloat = Spread.listWidth
    /// What is open on the right; nil draws the list alone.
    let open: Value?
    let close: @MainActor () -> Void
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: (Value) -> Detail

    var body: some View {
        HStack(spacing: 0) {
            list.frame(maxWidth: open == nil ? .infinity : listWidth)
            if let open {
                HingeSeam(queue: queue)
                NavigationStack {
                    detail(open).panelClose(close)
                }
                .id(open)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
