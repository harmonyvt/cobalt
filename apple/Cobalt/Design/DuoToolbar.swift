import SwiftUI

// Vertical Controls side rail & iOS 27 toolbar primitives (apple/ARCHITECTURE.md, iPhone Duo rules).
//
// On iPhone Duo Outer display and Inner landscape, iOS 27.1 moves toolbar items and tabs onto a
// trailing vertical rail:
//   - Every toolbar button provides `Label(title, systemImage:)` (icons on vertical rail, text/icons
//     on horizontal bars + tooltips/overflow).
//   - Overflow collapses bottom-to-top; mark Back/Close/Primary with `.duoVisibilityPriority(.high)`
//     and secondary actions with `.duoVisibilityPriority(.low)` or place them inside `DuoOverflowMenu`.
//   - Balance vertical rail space between toolbar items and tabs with `.duoToolbarCompression(...)`.

/// Cross-SDK wrapper for `ToolbarItemVisibilityPriority`.
enum DuoToolbarPriority: Sendable {
    case high
    case automatic
    case low
}

/// Cross-SDK wrapper for `ToolbarVerticalCompressionBehavior`.
enum DuoToolbarCompression: Sendable {
    case automatic
    case prefersToolbarItems
    case prefersTabBar
}

extension ToolbarContent {
    /// Sets toolbar item survival priority on the iPhone Duo vertical rail (iOS 27.0+ / macOS 26.1+).
    @ToolbarContentBuilder
    func duoVisibilityPriority(_ priority: DuoToolbarPriority) -> some ToolbarContent {
        if #available(iOS 27.0, macOS 26.1, *) {
            switch priority {
            case .high:
                self.visibilityPriority(.high)
            case .automatic:
                self.visibilityPriority(.automatic)
            case .low:
                self.visibilityPriority(.low)
            }
        } else {
            self
        }
    }
}

extension View {
    /// Configures how the iOS 27.1+ vertical side rail balances space between toolbar items and the tab bar.
    @ViewBuilder
    func duoToolbarCompression(_ behavior: DuoToolbarCompression) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            switch behavior {
            case .automatic:
                self.toolbarVerticalCompressionBehavior(.automatic)
            case .prefersToolbarItems:
                self.toolbarVerticalCompressionBehavior(.prefersToolbarItems)
            case .prefersTabBar:
                self.toolbarVerticalCompressionBehavior(.prefersTabBar)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// A system overflow menu for secondary toolbar actions.
///
/// Uses `ToolbarOverflowMenu` on iOS 27.0+ (integrating natively with the vertical side rail's
/// bottom-to-top overflow), and falls back to a standard trailing `Menu` on iOS 26 and macOS.
struct DuoOverflowToolbarMenu<Content: View>: ToolbarContent {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String = "More", @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu {
                content()
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    content()
                } label: {
                    Label(title, systemImage: "ellipsis.circle")
                }
            }
        }
        #else
        ToolbarItem(placement: .automatic) {
            Menu {
                content()
            } label: {
                Label(title, systemImage: "ellipsis.circle")
            }
        }
        #endif
    }
}

/// A vertical-rail-safe toolbar button that always pairs a title with an SF Symbol (`Label(title, systemImage:)`).
struct DuoToolbarButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Spotify-style unified circular Liquid Glass `<` back button for toolbars, sheets, and single-focus panes.
///
/// Uses `ToolbarItem(placement: .cancellationAction)` with `.duoVisibilityPriority(.high)` so iOS 27.1+
/// places the circular chevron directly below the top-right status indicator on iPhone Duo's Vertical Controls
/// side rail, and at top-leading on compact iPhone horizontal navigation bars.
struct CobaltBackToolbarItem: ToolbarContent {
    let title: String
    var accessibilityIdentifier: String? = nil
    var cancels: Bool = false
    let action: () -> Void

    init(
        title: String = Copy.close,
        accessibilityIdentifier: String? = nil,
        cancels: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.cancels = cancels
        self.action = action
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            DuoToolbarButton(title: title, systemImage: "chevron.backward", action: action)
                .modifier(OptionalToolbarIdentifier(id: accessibilityIdentifier))
                .modifier(OptionalCancelShortcut(enabled: cancels))
        }
        .duoVisibilityPriority(.high)
    }
}

private struct OptionalToolbarIdentifier: ViewModifier {
    let id: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

private struct OptionalCancelShortcut: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.cancelAction)
        } else {
            content
        }
    }
}

