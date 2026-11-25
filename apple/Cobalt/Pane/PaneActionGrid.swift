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
    /// Which tile currently has its hold-press picker open, so that tile and its row float above siblings.
    @State private var activeHoldID: String?

    /// The most the grid shows.
    static let limit = 4

    init(_ actions: [PaneAction]) {
        self.actions = Array(actions.prefix(Self.limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid
                .zIndex(activeHoldID == nil ? 0 : 10)
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
                    button(action, cornerRadius: 14, holdAlignment: .center) {
                        PaneActionRow(action: action, caption: Self.caption(for: action, offline: offline))
                    }
                    .zIndex(activeHoldID == action.id ? 10 : 0)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(Self.rows(actions.count), id: \.self) { row in
                    let rowActive = row.contains { actions[$0].id == activeHoldID }
                    Group {
                        if row.count == 1, let index = row.first {
                            button(actions[index], cornerRadius: 14, holdAlignment: .center) {
                                PaneActionRow(action: actions[index], caption: Self.caption(for: actions[index], offline: offline))
                            }
                        } else {
                            HStack(spacing: 10) {
                                ForEach(Array(row.enumerated()), id: \.element) { col, index in
                                    let action = actions[index]
                                    let align: HorizontalAlignment = col == 0 ? .leading : .trailing
                                    button(action, cornerRadius: 18, holdAlignment: align) {
                                        PaneActionTile(action: action, caption: Self.caption(for: action, offline: offline))
                                    }
                                    .zIndex(activeHoldID == action.id ? 10 : 0)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .zIndex(rowActive ? 10 : 0)
                }
            }
        }
    }

    /// The grid's rows as indices: pairs, with an odd last one alone on its row.
    static func rows(_ count: Int) -> [[Int]] {
        stride(from: 0, to: count, by: 2).map { start in Array(start..<min(start + 2, count)) }
    }

    @ViewBuilder
    private func button(
        _ action: PaneAction, cornerRadius: CGFloat, holdAlignment: HorizontalAlignment,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let paused = action.pausedOffline(offline) && !action.isDisabled && !action.isWorking
        let queued = action.queuedOffline(offline)
        let locked = action.isDisabled || action.isWorking
        Group {
            if paused {
                // not `.disabled`: a tap says why nothing happens (the toast), and VoiceOver reads the reason as the value
                Button { say(Copy.Pane.pausedReason(action.title)) } label: { label() }
                    .accessibilityValue(Copy.Pane.needsNetwork)
                    .accessibilityHint(Copy.Pane.needsServer)
            } else if !action.holdChoices.isEmpty {
                PaneHoldButton(
                    action: action, cornerRadius: cornerRadius, alignment: holdAlignment,
                    queued: queued, enabled: !locked, activeHoldID: $activeHoldID, label: label())
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
        .disabled(locked)
        .opacity(action.isWorking ? 0.82 : (action.isDisabled ? 0.45 : (paused ? 0.6 : 1)))   // paused says why in words (caption, note, toast); the dim is not the message
    }
}

/// A tile that executes `action.perform()` on a short tap, and reveals `action.holdChoices` (e.g. `share` / `direct`)
/// right above itself when pressed and held — sliding onto a choice highlights it and releasing executes it.
private struct PaneHoldButton<LabelContent: View>: View {
    let action: PaneAction
    let cornerRadius: CGFloat
    let alignment: HorizontalAlignment
    let queued: Bool
    let enabled: Bool
    @Binding var activeHoldID: String?
    let label: LabelContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hapticsEnabled) private var haptics
    @State private var holding = false
    @State private var highlightedID: String?
    @State private var choiceFrames: [String: CGRect] = [:]
    @State private var gate = HoldTapGate()

    private var spaceName: String { "pane.hold.\(action.id)" }

    private var overlayAlignment: Alignment {
        switch alignment {
        case .leading: return .topLeading
        case .trailing: return .topTrailing
        default: return .top
        }
    }

    private var scaleAnchor: UnitPoint {
        switch alignment {
        case .leading: return .bottomLeading
        case .trailing: return .bottomTrailing
        default: return .bottom
        }
    }

    var body: some View {
        let base = Button(role: action.role) {
            guard !gate.consumeSwallow() else { return }
            action.perform()
        } label: {
            label
        }
        .accessibilityValue(queued ? Copy.Pane.queuedCaption : "")
        .accessibilityHint("hold for \(action.holdChoices.map(\.title).joined(separator: " or "))")
        .accessibilityActions {
            ForEach(action.holdChoices) { choice in
                Button(choice.title) { choice.perform() }
            }
        }

        interactive(base)
            .coordinateSpace(.named(spaceName))
            .overlay(alignment: overlayAlignment) {
                if holding {
                    picker
                        .alignmentGuide(.top) { d in d[.bottom] + 10 }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: scaleAnchor).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .haptic(.impact(weight: .medium), trigger: holding, enabled: haptics) { $0 }
            .haptic(.selection, trigger: highlightedID, enabled: haptics) { $0 != nil }
    }

    private var picker: some View {
        let space = spaceName
        return HStack(spacing: 4) {
            ForEach(action.holdChoices) { choice in
                let active = highlightedID == choice.id
                Label(choice.title, systemImage: choice.systemImage)
                    .font(Font.cobalt(13.5, .semibold, relativeTo: .subheadline))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(active ? CobaltColor.onText : CobaltColor.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(active ? CobaltColor.text : Color.clear, in: Capsule())
                    .scaleEffect(active ? 1.04 : 1)
                    .animation(reduceMotion ? nil : Motion.press, value: active)
                    .onGeometryChange(for: CGRect.self) { [space] proxy in
                        proxy.frame(in: .named(space))
                    } action: { choiceFrames[choice.id] = $0 }
            }
        }
        .padding(4)
        .glassEffect(.regular.tint(CobaltColor.elevated.opacity(0.95)), in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }

    private func beginHold() {
        gate.swallowNextTap = true
        highlightedID = nil
        activeHoldID = action.id
        withAnimation(reduceMotion ? nil : Motion.press) { holding = true }
    }

    private func updateHold(at point: CGPoint) {
        guard holding else { return }
        let picked = PaneHoldHitTest.pick(at: point, frames: choiceFrames, order: action.holdChoices.map(\.id))
        if picked != highlightedID { highlightedID = picked }
    }

    private func endHold(commit: Bool) {
        let pickedID = commit ? highlightedID : nil
        highlightedID = nil
        if activeHoldID == action.id { activeHoldID = nil }
        withAnimation(reduceMotion ? nil : Motion.press) { holding = false }
        gate.clearSoon()
        if let pickedID, let choice = action.holdChoices.first(where: { $0.id == pickedID }) {
            choice.perform()
        }
    }

    #if os(iOS)
    private func interactive<V: View>(_ view: V) -> some View {
        view.gesture(
            HoldChoiceRecognizer(
                enabled: enabled,
                onBegan: { beginHold() },
                onChanged: { updateHold(at: $0) },
                onEnded: { endHold(commit: true) },
                onCancelled: { endHold(commit: false) }
            )
        )
    }
    #else
    private func interactive<V: View>(_ view: V) -> some View {
        view
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName)))
                    .onChanged { value in
                        switch value {
                        case .second(true, let drag):
                            if !holding { beginHold() }
                            if let location = drag?.location { updateHold(at: location) }
                        default: break
                        }
                    }
                    .onEnded { value in
                        guard holding else { return }
                        if case .second(true, let drag) = value, let location = drag?.location {
                            updateHold(at: location)
                        }
                        endHold(commit: true)
                    },
                including: enabled ? .all : .subviews
            )
            .contextMenu { PaneChoiceItems(choices: action.holdChoices) }
    }
    #endif
}

/// Synchronous tap-swallow gate shared between the UIKit long-press recognizer and the SwiftUI `Button` action.
@MainActor
private final class HoldTapGate {
    var swallowNextTap = false

    func consumeSwallow() -> Bool {
        guard swallowNextTap else { return false }
        swallowNextTap = false
        return true
    }

    func clearSoon() {
        Task { @MainActor [weak self] in
            self?.swallowNextTap = false
        }
    }
}

/// Hit-testing for floating hold-press choice pills: generous vertical reach above the tile without selecting while
/// resting in the middle of the tile itself.
enum PaneHoldHitTest {
    static func pick(at point: CGPoint, frames: [String: CGRect], order: [String]) -> String? {
        var best: (id: String, distance: CGFloat)?
        for id in order {
            guard let rect = frames[id], !rect.isEmpty else { continue }
            let hit = CGRect(
                x: rect.minX - 8,
                y: rect.minY - 28,
                width: rect.width + 16,
                height: rect.height + 42
            )
            guard hit.contains(point) else { continue }
            let dist = abs(point.x - rect.midX)
            if best == nil || dist < best!.distance { best = (id, dist) }
        }
        return best?.id
    }
}

#if os(iOS)
/// Scroll-safe UIKit long press for `PaneHoldButton`: fails on immediate drag so `ScrollView` scrolls normally, and
/// once `.began` takes over tracking finger movement across the floating pills without scrolling.
private struct HoldChoiceRecognizer: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onBegan: @MainActor () -> Void
    let onChanged: @MainActor (CGPoint) -> Void
    let onEnded: @MainActor () -> Void
    let onCancelled: @MainActor () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = false
        hold.delegate = context.coordinator
        hold.isEnabled = enabled
        return hold
    }

    func updateUIGestureRecognizer(_ hold: UILongPressGestureRecognizer, context: Context) {
        if hold.isEnabled != enabled { hold.isEnabled = enabled }
    }

    func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch hold.state {
        case .began:
            coordinator.holding = true
            onBegan()
        case .changed:
            guard coordinator.holding else { return }
            onChanged(context.converter.localLocation)
        case .ended:
            guard coordinator.holding else { return }
            coordinator.holding = false
            onChanged(context.converter.localLocation)
            onEnded()
        case .cancelled, .failed:
            guard coordinator.holding else { return }
            coordinator.holding = false
            onCancelled()
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var holding = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}
#endif

private struct PaneActionTile: View {
    let action: PaneAction
    /// Said after the title while offline ("needs network", "queues until online").
    var caption: String?

    private var tileMinHeight: CGFloat { Platform.isMac ? 62 : 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if action.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: action.systemImage)
                        .font(.system(size: Platform.isMac ? 20 : 22, weight: .semibold))
                }
            }
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
            if action.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Platform.isMac ? 16 : 18)
            } else {
                Image(systemName: action.systemImage)
                    .font(.system(size: Platform.isMac ? 15 : 17, weight: .semibold))
            }
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
