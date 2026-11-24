import SwiftUI

// The focus screen's secondary actions with their words on the phone (apple 04-PHASE4 4.3 item 2).
//
// On every width but the phone they are `.cobaltIcon()` (a glass circle that names itself on a long press, or on hover on the Mac).
// On a compact width (an iPhone, a narrow split view) a long press to learn what an icon does is a guess, so the same buttons draw
// their name: `.stacked` is a cell of a grid (symbol over a caption), `.inline` a capsule (symbol beside the caption) for the
// small buttons that sit in a row beside text. At the accessibility text sizes `.cobaltIcon()` already gives the words back, so
// `FocusActionStyle.labelled(...)` answers false there and the old path stays in charge.
//
// The button's `Label` is still the VoiceOver name; `shortTitle` is only what is drawn when the full name would not fit a cell
// ("copy" for "copy share link").

enum FocusLabelLayout {
    /// A grid cell: the symbol over a caption of up to two lines.
    case stacked
    /// A capsule: the symbol beside a one-line caption.
    case inline
}

struct FocusActionStyle: PrimitiveButtonStyle {
    var layout: FocusLabelLayout = .stacked
    var size: CobaltIconButtonStyle.Size = .regular
    var state: IconButtonState = .idle
    /// What to draw in place of the label's own title (the label stays the accessible name).
    var shortTitle: String?
    /// Draw the words: `labelled(sizeClass:typeSize:)`.
    var labelled: Bool

    /// Words go on the buttons only on a compact width, and only below the accessibility sizes (which have them already).
    static func labelled(sizeClass: UserInterfaceSizeClass?, typeSize: DynamicTypeSize) -> Bool {
        #if os(iOS)
        return sizeClass == .compact && !typeSize.isAccessibilitySize
        #else
        return false
        #endif
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if labelled {
            WordedActionBody(configuration: configuration, layout: layout, size: size, state: state, shortTitle: shortTitle)
        } else {
            CobaltIconButtonStyle(size: size, state: state).makeBody(configuration: configuration)
        }
    }
}

extension PrimitiveButtonStyle where Self == FocusActionStyle {
    static func focusAction(
        _ layout: FocusLabelLayout = .stacked, size: CobaltIconButtonStyle.Size = .regular, state: IconButtonState = .idle,
        shortTitle: String? = nil, labelled: Bool
    ) -> FocusActionStyle {
        FocusActionStyle(layout: layout, size: size, state: state, shortTitle: shortTitle, labelled: labelled)
    }
}

private struct WordedActionBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let layout: FocusLabelLayout
    let size: CobaltIconButtonStyle.Size
    let state: IconButtonState
    let shortTitle: String?

    @Environment(\.isEnabled) private var isEnabled
    @State private var taps = 0

    private var ink: Color { state == .done ? .black : CobaltColor.text }
    private var captionSize: CGFloat { size == .regular ? 11 : 12 }
    private var symbolSize: CGFloat { size == .regular ? 18 : 13 }

    var body: some View {
        Button(role: configuration.role) {
            guard state != .working else { return }
            taps += 1
            configuration.trigger()
        } label: {
            content
                .foregroundStyle(ink)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background { if state == .done { shape.fill(CobaltColor.success) } }
        .glassEffect(isEnabled ? .regular.interactive() : .regular, in: shape)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(Motion.copy, value: state)
        .haptic(.impact(weight: .light, intensity: 0.7), trigger: taps)
    }

    private var shape: AnyShape {
        layout == .stacked ? AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous)) : AnyShape(.capsule)
    }

    private var symbol: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: symbolSize, weight: .medium))
            // one height for every symbol, so the captions of a row sit on one line
            .frame(height: layout == .stacked ? 24 : nil)
            .symbolEffect(.pulse, isActive: state == .working)
            .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var caption: some View {
        let font = Font.cobalt(captionSize, .medium, relativeTo: .caption)
        if let shortTitle {
            Text(shortTitle).font(font)
        } else {
            configuration.label.labelStyle(.titleOnly).font(font)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .stacked:
            VStack(spacing: 4) {
                symbol
                caption
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        case .inline:
            HStack(spacing: 5) {
                symbol
                caption
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, size == .regular ? 16 : 11)
            .frame(minHeight: size == .regular ? 50 : 34)
        }
    }
}
