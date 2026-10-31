import SwiftUI

// Icon-first controls (Harmony's icon direction, 2026-10-31; mockup icon-ui/mockup.html):
//
//   1. one word per screen   the screen's one main action keeps its word (`.cobaltPrimary()`); every other button is
//                            `.cobaltIcon()`, a glass circle with only its symbol.
//   2. hold to name it       holding an icon shows its name in a small tag above it (a light tick); letting go after
//                            that does not press it. On the Mac, resting the pointer on it shows the same tag.
//   3. state is shown        "copied", "saved", "making…" are the icon itself: pass `state: .done` (green circle) or
//                            `.working` (pulsing symbol) instead of swapping the words.
//   4. same icon, same idea  the symbols come from `Symbol`; `tint` carries the select panel's colours.
//
// The name is the button's `Label` title, so VoiceOver reads it as before. At accessibility text sizes the word comes
// back next to the icon (a capsule instead of a circle).

/// What an icon button is showing besides its action.
enum IconButtonState: Equatable {
    case idle
    /// Done its job (copied, saved): a green circle.
    case done
    /// Working on it: the symbol pulses and the button waits.
    case working
}

struct CobaltIconButtonStyle: PrimitiveButtonStyle {
    enum Size { case regular, small }

    var size: Size = .regular
    /// The symbol's colour (the select panel's link / collection / edit / share colours); nil is the text colour.
    var tint: Color?
    /// A filled circle in `tint` (or the text colour) with the background's ink: the one solid icon of a row.
    var prominent = false
    var state: IconButtonState = .idle

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, tint: tint, prominent: prominent, state: state)
    }
}

extension PrimitiveButtonStyle where Self == CobaltIconButtonStyle {
    /// An icon-only glass circle whose name shows on a long press (hover on the Mac). Give the button a `Label`.
    static func cobaltIcon(
        _ size: CobaltIconButtonStyle.Size = .regular, tint: Color? = nil, prominent: Bool = false,
        state: IconButtonState = .idle
    ) -> CobaltIconButtonStyle {
        CobaltIconButtonStyle(size: size, tint: tint, prominent: prominent, state: state)
    }
}

private struct IconButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let size: CobaltIconButtonStyle.Size
    let tint: Color?
    let prominent: Bool
    let state: IconButtonState

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var naming = false
    /// Set by the long press: the release that follows must not press the button.
    @State private var swallowNextTap = false
    @State private var hideTask: Task<Void, Never>?
    @State private var hoverTask: Task<Void, Never>?
    @State private var taps = 0
    @State private var named = 0

    private var diameter: CGFloat { size == .regular ? 50 : 34 }
    private var symbolSize: CGFloat { size == .regular ? 20 : 15 }
    private var wordsBack: Bool { typeSize.isAccessibilitySize }

    private var ink: Color {
        if state == .done { return .black }
        if prominent { return CobaltColor.onText }
        return tint ?? CobaltColor.text
    }

    private var fill: Color? {
        if state == .done { return CobaltColor.success }
        if prominent { return tint ?? CobaltColor.text }
        return nil
    }

    var body: some View {
        Button(role: configuration.role) {
            if swallowNextTap {
                swallowNextTap = false
                return
            }
            guard state != .working else { return }
            taps += 1
            configuration.trigger()
        } label: {
            styledLabel
                .font(wordsBack ? CobaltType.buttonSmall : .system(size: symbolSize, weight: .medium))
                .symbolEffect(.pulse, isActive: state == .working)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(ink)
                .lineLimit(1)
                .frame(minWidth: diameter, minHeight: diameter)
                .padding(.horizontal, wordsBack ? 12 : 0)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background { if let fill { Capsule().fill(fill) } }
        .glassEffect(isEnabled ? .regular.interactive() : .regular, in: .capsule)
        .opacity(isEnabled ? 1 : 0.45)
        .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
        .animation(Motion.copy, value: state)
        .overlay(alignment: .top) {
            if naming {
                configuration.label
                    .labelStyle(.titleOnly)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(10)
            }
        }
        .zIndex(naming ? 10 : 0)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                swallowNextTap = true
                named += 1
                show(for: 1.6)
            }
        )
        #if os(macOS)
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.press) { naming = true }
                }
            } else {
                withAnimation(Motion.fade) { naming = false }
            }
        }
        #endif
        .haptic(.impact(weight: .light, intensity: 0.7), trigger: taps)
        .haptic(.selection, trigger: named)
        .onDisappear {
            hideTask?.cancel()
            hoverTask?.cancel()
        }
    }

    @ViewBuilder
    private var styledLabel: some View {
        if wordsBack {
            configuration.label.labelStyle(.titleAndIcon)
        } else {
            configuration.label.labelStyle(.iconOnly)
        }
    }

    private func show(for seconds: Double) {
        hideTask?.cancel()
        withAnimation(Motion.press) { naming = true }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { naming = false }
            // a long press that never ended in a release (dragged away) must not eat the next real tap
            swallowNextTap = false
        }
    }
}

/// A row of icon buttons that reads as one glass family.
struct IconRow<Content: View>: View {
    var spacing: CGFloat = 10
    var alignment: HorizontalAlignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) { content() }
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
        }
    }
}

extension View {
    /// The name of an icon-only control that is not a `.cobaltIcon()` button (a menu, a toggle, a segmented picker):
    /// VoiceOver reads it, the Mac shows it on hover.
    func iconName(_ name: String) -> some View {
        self.accessibilityLabel(name).help(name)
    }
}
