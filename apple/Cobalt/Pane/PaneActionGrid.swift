import SwiftUI

/// The pane's primary buttons: paired tiles (2 or 4) with equal row heights, and compact full-width rows whenever an
/// action sits alone on its row (1 action, the 3rd of 3, or at accessibility text sizes) so a single action never
/// stretches into a giant empty rectangle. Up to four; pass the rest to `PanePage(more:)`.
///
/// Offline (`\.paneOffline`, the server can't be reached) the grid says so in words, never by dimming alone: a note under
/// the group, "needs network" on every paused tile, and a short toast with the reason when a paused tile is tapped. An
/// action the sync outbox holds (`PaneAction.queuesOffline`) stays enabled and says it queues; the receipt ("queued") is said by
/// the page once the change is in the outbox (after its confirm, if it asks), never by a tap that only opens a question.
struct PaneActionGrid: View {
    let actions: [PaneAction]

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paneOffline) private var offline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The reason a tap on a paused action gave, for a moment.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// The most the grid shows.
    static let limit = 4

    init(_ actions: [PaneAction]) {
        self.actions = Array(actions.prefix(Self.limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid
            if offline {
                ForEach(Self.notes(for: actions, offline: offline), id: \.self) { note in
                    Text(note)
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.captionOnElevated)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            if let toast {
                Text(toast)
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(CobaltColor.elevated.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
                    .accessibilityIdentifier("pane.actions.toast")
            }
        }
        .onChange(of: offline) { _, now in if !now { toastTask?.cancel(); toast = nil } }
    }

    /// The notes under the group while offline: what pauses, and what the outbox holds. Empty when nothing needs the server.
    static func notes(for actions: [PaneAction], offline: Bool) -> [String] {
        var out: [String] = []
        if actions.contains(where: { $0.pausedOffline(offline) }) { out.append(Copy.Pane.offlineNote) }
        if actions.contains(where: { $0.queuedOffline(offline) }) { out.append(Copy.Pane.queuesNote) }
        return out
    }

    /// What a tile says after its title while offline; nil when the action is as usual.
    static func caption(for action: PaneAction, offline: Bool) -> String? {
        if action.pausedOffline(offline) { return Copy.Pane.needsNetwork }
        if action.queuedOffline(offline) { return Copy.Pane.queuedCaption }
        return nil
    }

    private func say(_ text: String) {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { toast = text }
        AccessibilityNotification.Announcement(text).post()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) { toast = nil }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if typeSize.isAccessibilitySize || actions.count == 1 {
            VStack(spacing: 8) {
                ForEach(actions) { action in
                    button(action, cornerRadius: 14) { PaneActionRow(action: action, caption: Self.caption(for: action, offline: offline)) }
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(Self.rows(actions.count), id: \.self) { row in
                    if row.count == 1, let index = row.first {
                        button(actions[index], cornerRadius: 14) { PaneActionRow(action: actions[index], caption: Self.caption(for: actions[index], offline: offline)) }
                    } else {
                        HStack(spacing: 10) {
                            ForEach(row, id: \.self) { index in
                                button(actions[index], cornerRadius: 18) { PaneActionTile(action: actions[index], caption: Self.caption(for: actions[index], offline: offline)) }
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
        let paused = action.pausedOffline(offline) && !action.isDisabled
        let queued = action.queuedOffline(offline)
        Group {
            if paused {
                // not `.disabled`: a tap says why nothing happens (the toast), and VoiceOver reads the reason as the value
                Button { say(Copy.Pane.pausedReason(action.title)) } label: { label() }
                    .accessibilityValue(Copy.Pane.needsNetwork)
                    .accessibilityHint(Copy.Pane.needsServer)
            } else if action.choices.isEmpty {
                Button(role: action.role) {
                    action.perform()
                } label: { label() }
                    .accessibilityValue(queued ? Copy.Pane.queuedCaption : "")
            } else {
                // `share`: the tile opens its choices
                Menu { PaneChoiceItems(choices: action.choices) } label: { label() }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
            }
        }
        .buttonStyle(PaneBigButtonStyle(destructive: action.role == .destructive, cornerRadius: cornerRadius))
        .disabled(action.isDisabled)
        .opacity(action.isDisabled ? 0.45 : (paused ? 0.6 : 1))   // paused says why in words (caption, note, toast); the dim is not the message
    }
}

private struct PaneActionTile: View {
    let action: PaneAction
    /// Said after the title while offline ("needs network", "queues until online").
    var caption: String?

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
            if let caption {
                OfflineCaption(text: caption)
            }
        }
        .frame(maxWidth: .infinity, minHeight: tileMinHeight, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

private struct PaneActionRow: View {
    let action: PaneAction
    var caption: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .font(.system(size: Platform.isMac ? 15 : 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(Font.cobalt(Platform.isMac ? 13.5 : 14.5, .semibold, relativeTo: .body))
                    .multilineTextAlignment(.leading)
                if let caption {
                    OfflineCaption(text: caption)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 42 : 48, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The small line after an action's title while offline: the words that make "needs network" more than a dimmed tile.
private struct OfflineCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.text)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
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

// MARK: - previews (the offline table)

#if DEBUG
private enum GridSamples {
    /// make link (needs the server), hide (the outbox holds it), share (works offline), delete (needs the server).
    static var mixed: [PaneAction] {
        [
            PaneAction("make link", systemImage: "link", needsServer: true, id: "make-link") {},
            PaneAction("hide…", systemImage: "eye.slash", needsServer: true, queuesOffline: true, id: "hide") {},
            PaneAction("share", systemImage: "square.and.arrow.up", id: "share") {},
            PaneAction("delete", systemImage: "trash", role: .destructive, needsServer: true, id: "delete") {},
        ]
    }
    static var one: [PaneAction] { [PaneAction("make webp", systemImage: "photo.stack", needsServer: true, id: "make-webp") {}] }
    static var queuedOnly: [PaneAction] { [PaneAction("unhide", systemImage: "eye", needsServer: true, queuesOffline: true, id: "unhide") {}] }
}

#Preview("grid · online") {
    PaneActionGrid(GridSamples.mixed).padding().background(CobaltColor.bg)
}
#Preview("grid · offline: paused, queued, free") {
    PaneActionGrid(GridSamples.mixed).environment(\.paneOffline, true).padding().background(CobaltColor.bg)
}
#Preview("grid · offline: one paused row") {
    PaneActionGrid(GridSamples.one).environment(\.paneOffline, true).padding().background(CobaltColor.bg)
}
#Preview("grid · offline: queued only") {
    PaneActionGrid(GridSamples.queuedOnly).environment(\.paneOffline, true).padding().background(CobaltColor.bg)
}
#Preview("grid · offline, accessibility text") {
    PaneActionGrid(GridSamples.mixed).environment(\.paneOffline, true).environment(\.dynamicTypeSize, .accessibility3)
        .padding().background(CobaltColor.bg)
}
#endif
