import SwiftUI

/// The pane's big buttons (Harmony, 2026-11-23): a 2×2 grid (one action fills the row; three are two on top and one
/// full width below), each about 96 pt tall, a large icon top-leading and a bold
/// label bottom-leading on filled glass. Up to four; pass the rest to `PanePage(more:)`. At accessibility text sizes the
/// grid becomes a list of full-width rows, so the labels never clip.
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
        if typeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                ForEach(actions) { action in
                    button(action) { PaneActionRow(action: action) }
                }
            }
        } else {
            // rows of two; an odd one out takes the whole row (1: full width; 3: two on top, one below), so no hole
            VStack(spacing: 10) {
                ForEach(Self.rows(actions.count), id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { index in
                            button(actions[index]) { PaneActionTile(action: actions[index]) }
                        }
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
    private func button(_ action: PaneAction, @ViewBuilder label: () -> some View) -> some View {
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
        .buttonStyle(PaneBigButtonStyle(destructive: action.role == .destructive))
        .disabled(off)
        .opacity(off ? 0.45 : 1)
        .accessibilityHint(action.needsServer && offline ? Copy.Pane.needsServer : "")
    }
}

private struct PaneActionTile: View {
    let action: PaneAction

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: action.systemImage)
                .font(.system(size: 26, weight: .semibold))
                .frame(height: 30, alignment: .topLeading)
            Spacer(minLength: 8)
            Text(action.title)
                .font(Font.cobalt(15, .semibold, relativeTo: .body))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(14)
    }
}

private struct PaneActionRow: View {
    let action: PaneAction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: action.systemImage)
                .font(.system(size: 22, weight: .semibold))
            Text(action.title)
                .font(Font.cobalt(15, .semibold, relativeTo: .body))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Filled glass in the house colours, pressed with the app's haptic.
private struct PaneBigButtonStyle: ButtonStyle {
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? CobaltColor.errorText : CobaltColor.text)
            .contentShape(.rect(cornerRadius: 22))
            .glassEffect(.regular.tint(CobaltColor.elevated.opacity(0.85)).interactive(), in: .rect(cornerRadius: 22))
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
