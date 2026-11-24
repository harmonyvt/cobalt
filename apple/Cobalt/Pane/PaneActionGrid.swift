import SwiftUI

/// The pane's primary buttons: paired tiles (2 or 4) with equal row heights, and compact full-width rows whenever an
/// action sits alone on its row (1 action, the 3rd of 3, or at accessibility text sizes) so a single action never
/// stretches into a giant empty rectangle. Up to four; pass the rest to `PanePage(more:)`.
struct PaneActionGrid: View {
    let actions: [PaneAction]

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paneOffline) private var offline

    /// The most the grid shows.
    static let limit = 4

    init(_ actions: [PaneAction]) {
        self.actions = Array(actions.prefix(Self.limit))
    }

    var body: some View {
        if typeSize.isAccessibilitySize || actions.count == 1 {
            VStack(spacing: 8) {
                ForEach(actions) { action in
                    button(action, cornerRadius: 14) { PaneActionRow(action: action) }
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(Self.rows(actions.count), id: \.self) { row in
                    if row.count == 1, let index = row.first {
                        button(actions[index], cornerRadius: 14) { PaneActionRow(action: actions[index]) }
                    } else {
                        HStack(spacing: 10) {
                            ForEach(row, id: \.self) { index in
                                button(actions[index], cornerRadius: 18) { PaneActionTile(action: actions[index]) }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The grid's rows as indices: pairs, with an odd last one alone on its row.
    static func rows(_ count: Int) -> [[Int]] {
        stride(from: 0, to: count, by: 2).map { start in Array(start..<min(start + 2, count)) }
    }

    @ViewBuilder
    private func button(_ action: PaneAction, cornerRadius: CGFloat, @ViewBuilder label: () -> some View) -> some View {
        let off = action.off(offline: offline)
        Group {
            if action.choices.isEmpty {
                Button(role: action.role) { action.perform() } label: { label() }
            } else {
                // `share`: the tile opens its choices
                Menu { PaneChoiceItems(choices: action.choices) } label: { label() }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
            }
        }
        .buttonStyle(PaneBigButtonStyle(destructive: action.role == .destructive, cornerRadius: cornerRadius))
        .disabled(off)
        .opacity(off ? 0.45 : 1)
        .accessibilityHint(action.needsServer && offline ? Copy.Pane.needsServer : "")
    }
}

private struct PaneActionTile: View {
    let action: PaneAction

    private var tileMinHeight: CGFloat { Platform.isMac ? 62 : 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: action.systemImage)
                .font(.system(size: Platform.isMac ? 20 : 22, weight: .semibold))
                .frame(height: 26, alignment: .topLeading)
            Spacer(minLength: 10)
            Text(action.title)
                .font(Font.cobalt(Platform.isMac ? 13.5 : 14.5, .semibold, relativeTo: .body))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: tileMinHeight, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

private struct PaneActionRow: View {
    let action: PaneAction

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .font(.system(size: Platform.isMac ? 15 : 17, weight: .semibold))
            Text(action.title)
                .font(Font.cobalt(Platform.isMac ? 13.5 : 14.5, .semibold, relativeTo: .body))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 42 : 48, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Filled glass in the house colours, pressed with the app's haptic.
private struct PaneBigButtonStyle: ButtonStyle {
    let destructive: Bool
    let cornerRadius: CGFloat

    private var tint: Color {
        destructive ? CobaltColor.error.opacity(0.14) : CobaltColor.elevated.opacity(0.85)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? CobaltColor.errorText : CobaltColor.text)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .haptic(.impact(weight: .light), trigger: configuration.isPressed) { $0 }
    }
}

/// An action's choices as menu buttons (a tile's, a header icon's, or a submenu of the more menu).
struct PaneChoiceItems: View {
    let choices: [PaneAction]
    @Environment(\.paneOffline) private var offline

    var body: some View {
        ForEach(choices) { choice in
            Button(role: choice.role) { choice.perform() } label: {
                Label(choice.title, systemImage: choice.systemImage)
            }
            .disabled(choice.off(offline: offline))
        }
    }
}
