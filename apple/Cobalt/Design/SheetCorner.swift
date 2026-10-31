import SwiftUI

// Close and "more" sit in a sheet's top-right corner on every platform (Harmony, 2026-10-31). A Mac sheet draws
// toolbar items in a bottom bar, so there the corner is a row over the sheet's top edge instead of toolbar items.
//
//   presenter:  Content().sheetClose { shown = nil }        the close action, for whatever the sheet draws
//   content:    .sheetCorner { DetailMenu(…) }               extras beside the close, top right
//
// A presenter whose content draws no corner of its own adds `.sheetCorner()` itself: `Content().sheetCorner().sheetClose { … }`.

/// How the sheet this view is in closes; nil outside a sheet that set one.
struct SheetCloseAction {
    let run: @MainActor () -> Void
}

private struct SheetCloseKey: EnvironmentKey {
    static let defaultValue: SheetCloseAction? = nil
}

extension EnvironmentValues {
    var sheetClose: SheetCloseAction? {
        get { self[SheetCloseKey.self] }
        set { self[SheetCloseKey.self] = newValue }
    }
}

extension View {
    /// The close action of the sheet this content is shown in (drawn by `sheetCorner`).
    func sheetClose(_ action: @escaping @MainActor () -> Void) -> some View {
        environment(\.sheetClose, SheetCloseAction(run: action))
    }

    /// The sheet's top-right corner: `extras` (a "more" menu) and then the close button.
    func sheetCorner<Extras: View>(@ViewBuilder _ extras: @escaping () -> Extras) -> some View {
        modifier(SheetCorner(extras: extras))
    }

    /// The sheet's top-right corner with only the close button.
    func sheetCorner() -> some View {
        modifier(SheetCorner(extras: { EmptyView() }))
    }
}

private struct SheetCorner<Extras: View>: ViewModifier {
    let extras: () -> Extras
    @Environment(\.sheetClose) private var close

    /// Outside a sheet with a close action this draws nothing: a window's own toolbar is where its items belong.
    @ViewBuilder
    func body(content: Content) -> some View {
        if let close {
            #if os(macOS)
            content.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    extras()
                    CloseButton(cancels: true) { close.run() }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            #else
            content.toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    extras()
                    CloseButton(cancels: true) { close.run() }
                }
            }
            #endif
        } else {
            content
        }
    }
}
