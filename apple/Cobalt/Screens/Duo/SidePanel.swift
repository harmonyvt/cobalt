import CobaltKit
import SwiftUI

// One rule for every right-hand panel of a wide layout (owner, 8.34: "whenever you're using split screen there always has
// to be a back button ... it always needs to be able to hide"). The panels are:
//
//   - the spread pane (`SpreadPaneView`): sheets, pickers, booru posts and filters, the select panel
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

/// A list with what it opened: beside it on a spread, pushed on the list's own stack otherwise. The list keeps the whole
/// width while nothing is open (#216), then gives the right side to the detail behind a hinge. The detail always has the
/// panel's close (`panelClose`).
///
/// One view for both layouts, so a fold or unfold never swaps the list for a new one (it keeps its scroll) and never
/// drops what is open: the push is always declared and only ever reads the open value while folded. Before (8.35) each
/// screen switched between a split and a list with its own `navigationDestination`; on a two-screen phone that left a
/// push declared while the split showed, which popped straight away and wrote nil back, so "new chat" or a row on the
/// unfolded phone flashed and closed again (owner, 8.35: "the button did nothing until I closed the iPhone Duo").
struct DetailSplit<Value: Hashable, ListContent: View, Detail: View>: View {
    let queue: JobQueue
    var listWidth: CGFloat = Spread.listWidth
    /// Two columns (the screen has `Spread.minWidth` of its own); otherwise the detail is pushed.
    let spread: Bool
    /// What is open; nil draws the list alone.
    @Binding var open: Value?
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: (Value) -> Detail

    /// The layout as of the last update, read when the stack writes the push back (it can do that after a fold or
    /// unfold, from a binding made before it).
    @State private var layout = DetailSplitLayout()

    var body: some View {
        let _ = (layout.spread = spread)
        let shown = spread ? open : nil
        HStack(spacing: 0) {
            list.frame(maxWidth: shown == nil ? .infinity : listWidth)
            if let shown {
                HingeSeam(queue: queue)
                NavigationStack {
                    detail(shown).panelClose { open = nil }
                }
                .id(shown)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationDestination(item: pushed) { value in
            detail(value)
        }
    }

    /// The push: the open value while folded, nothing on a spread. A pop the stack does because the phone unfolded (the
    /// push stops being asked for) is not the owner closing it: the value stays open, now on the right.
    private var pushed: Binding<Value?> {
        let layout = layout
        let open = $open
        return Binding(
            get: { layout.spread ? nil : open.wrappedValue },
            set: { value in
                if value == nil, layout.spread { return }
                open.wrappedValue = value
            })
    }
}

/// `DetailSplit`'s layout, kept by reference so a binding made in an earlier update reads the current one.
@MainActor
final class DetailSplitLayout {
    var spread = false
}
