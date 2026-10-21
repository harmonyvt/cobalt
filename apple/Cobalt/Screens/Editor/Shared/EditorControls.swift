import CobaltKit
import SwiftUI

// Shared: the editor's inspector controls. The Mac and iPad inspector stacks them in a column; the iPhone clip sheet stacks the
// same rows in its own sections. Each row takes values and closures (nothing here knows the session), so a caller wires the
// closure to `EditSession` and calls `session.endGesture()` from `onEnd`, which ends a slider's or a field's run of edits as
// one undo step.

// MARK: - layout pieces

/// A small lowercase label over its controls: the board's `.lbl` (10.5 pt caption). `trailing` puts a value on the right
/// (the phone sheet's `1.5×`).
struct EditorSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityAddTraits(.isHeader)
                if let trailing {
                    Spacer(minLength: 8)
                    Text(trailing)
                        .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.text)
                        .monospacedDigit()
                }
            }
            content()
        }
    }
}

/// The board's field: a rounded row with the label on the left and a control on the right.
struct EditorFieldRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: Platform.isMac ? 30 : 38)
        .background(EditorColor.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - segmented

/// A row (or grid) of exclusive choices: the board's `.seg`. The selected one is the text-ink pill.
struct EditorSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: String { title }
    }

    let options: [Option]
    /// Which one is chosen; nil when none is (a speed of 1.2× matches no button).
    let selected: Value?
    var columns: Int
    var isEnabled = true
    let onSelect: (Value) -> Void

    init(options: [Option], selected: Value?, columns: Int? = nil, isEnabled: Bool = true, onSelect: @escaping (Value) -> Void) {
        self.options = options
        self.selected = selected
        self.columns = columns ?? options.count
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: max(1, columns)), spacing: 4) {
            ForEach(options) { option in
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 28 : 36)
                        .foregroundStyle(option.value == selected ? CobaltColor.onText : CobaltColor.text)
                        .background(
                            option.value == selected ? CobaltColor.text : EditorColor.field,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option.value == selected ? .isSelected : [])
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .haptic(.selection, trigger: selected)
    }
}

// MARK: - number fields

/// An editable value in a field: `m:ss.cc` for a time, a percent for a position. Return (or leaving the field) commits what
/// was typed; ↑ and ↓ step it (`step`, with ⇧ `bigStep`). `commit` gets the new value; the field shows the value it is
/// given, so a value the session clamps comes back clamped.
struct EditorNumberField: View {
    let label: String
    let value: Double
    let format: (Double) -> String
    let parse: (String) -> Double?
    var step: Double
    var bigStep: Double
    let commit: (Double) -> Void
    var onEnd: () -> Void = {}
    var isEnabled = true

    @State private var text = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        EditorFieldRow(label: label) {
            TextField("", text: typingBinding)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .monospacedDigit()
                .frame(minWidth: 64, maxWidth: 96)
                .focused($focused)
                .onSubmit(apply)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .disabled(!isEnabled)
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, new in if !typing { text = format(new) } }
        .onChange(of: focused) { _, isFocused in if !isFocused && typing { apply() } }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard focused else { return .ignored }
            nudge(press.key == .upArrow ? 1 : -1, big: press.modifiers.contains(.shift))
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1, big: false)
            case .decrement: nudge(-1, big: false)
            @unknown default: break
            }
        }
    }

    private var typingBinding: Binding<String> {
        Binding(get: { text }, set: { text = $0; typing = true })
    }

    private func nudge(_ direction: Double, big: Bool) {
        typing = false
        commit(value + direction * (big ? bigStep : step))
        onEnd()
    }

    private func apply() {
        typing = false
        if let parsed = parse(text) { commit(parsed); onEnd() }
        text = format(value)
    }
}

extension EditorNumberField {
    /// A time in seconds as `m:ss.cc`; one frame steps it, ⇧ a second.
    static func time(label: String, value: Double, fps: Int, isEnabled: Bool = true, commit: @escaping (Double) -> Void,
                     onEnd: @escaping () -> Void = {}) -> EditorNumberField {
        EditorNumberField(
            label: label, value: value, format: Copy.Editor.clockCentis, parse: Copy.Editor.parseClock,
            step: 1 / Double(max(1, fps)), bigStep: 1, commit: commit, onEnd: onEnd, isEnabled: isEnabled)
    }

    /// A fraction of the canvas shown as a whole percent (`60%`); a point steps it, ⇧ ten.
    static func percent(label: String, value: Double, isEnabled: Bool = true, commit: @escaping (Double) -> Void,
                        onEnd: @escaping () -> Void = {}) -> EditorNumberField {
        EditorNumberField(
            label: label, value: value,
            format: { "\(Int(($0 * 100).rounded()))%" },
            parse: { text in
                let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "% ").union(.whitespaces))
                return Double(digits).map { $0 / 100 }
            },
            step: 0.01, bigStep: 0.1, commit: commit, onEnd: onEnd, isEnabled: isEnabled)
    }
}

// MARK: - sliders

/// A plain slider for a 0...1 level or a percent range, calling `onEnd` when the gesture lets go (one undo step).
struct EditorSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    var label: String
    var onEnd: () -> Void = {}

    var body: some View {
        Slider(value: $value, in: range, step: step) { editing in
            if !editing { onEnd() }
        }
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// The speed slider: 0.25× to 4× on a log scale (so 1× is the middle), steps of 0.05, a detent at 1×. `marks` draws
/// `0.25× 0.5× 1× 2× 4×` under it (the phone sheet).
struct EditorLogSlider: View {
    let speed: Double
    var marks = false
    let set: (Double) -> Void
    var onEnd: () -> Void = {}

    static let low = 0.25, high = 4.0
    private static let span = log(high / low)

    static func position(of speed: Double) -> Double {
        min(1, max(0, log(max(low, speed) / low) / span))
    }

    static func speed(at position: Double) -> Double {
        var s = low * exp(min(1, max(0, position)) * span)
        s = (s * 20).rounded() / 20
        if abs(s - 1) < 0.04 { s = 1 }             // the detent
        return min(high, max(low, s))
    }

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { Self.position(of: speed) }, set: { set(Self.speed(at: $0)) }), in: 0...1
            ) { editing in
                if !editing { onEnd() }
            }
            .accessibilityLabel(Copy.Editor.speed)
            .accessibilityValue(Copy.Editor.speedValue(speed))
            if marks { markRow }
        }
    }

    private var markRow: some View {
        GeometryReader { geo in
            ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { mark in
                Text(Copy.Editor.speedValue(mark))
                    .font(Font.cobalt(9.5, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize()
                    .position(x: 12 + (geo.size.width - 24) * Self.position(of: mark), y: 7)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - rows of the inspector and the phone sheet

/// Speed: `0.5× 1× 1.5× 2×`, the log slider, and `clip becomes 4.5s · pitch kept`.
struct EditorSpeedRow: View {
    let speed: Double
    /// The seconds of source the clip plays (`out - in`).
    let sourceSeconds: Double
    var marks = false
    let set: (Double) -> Void
    var onEnd: () -> Void = {}

    private static let presets: [Double] = [0.5, 1, 1.5, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorSegmented(
                options: Self.presets.map { .init(value: $0, title: Copy.Editor.speedValue($0)) },
                selected: Self.presets.first { abs($0 - speed) < 0.001 },
                onSelect: { set($0); onEnd() })
            EditorLogSlider(speed: speed, marks: marks, set: set, onEnd: onEnd)
            Text("\(Copy.Editor.becomes(sourceSeconds / max(0.25, speed))) · \(Copy.Editor.pitchKept)")
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
        }
    }
}

/// Pitch: a -12...12 semitone slider in steps of a half (so 0 is a natural stop), `changes the voice, not the speed`, and a
/// `reset` button when it is not 0. The value itself is the section's trailing text.
struct EditorPitchRow: View {
    let pitch: Double
    let set: (Double) -> Void
    var onEnd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Slider(
                value: Binding(get: { pitch }, set: { set(Self.snapped($0)) }), in: -12...12, step: 0.5
            ) { editing in
                if !editing { onEnd() }
            }
            .accessibilityLabel(Copy.Editor.pitch)
            .accessibilityValue(Copy.Editor.pitchValue(pitch))
            HStack {
                Text(Copy.Editor.pitchHint)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                Spacer(minLength: 8)
                if abs(pitch) > 0.001 {
                    Button(Copy.Editor.pitchReset) {
                        set(0)
                        onEnd()
                    }
                    .buttonStyle(.plain)
                    .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.text)
                    .frame(minHeight: Platform.isMac ? 24 : Metrics.hit)
                    .accessibilityLabel(Copy.Editor.pitchReset)
                }
            }
        }
    }

    /// A multiple of 0.5 inside -12...12.
    static func snapped(_ p: Double) -> Double {
        guard p.isFinite else { return 0 }
        return min(12, max(-12, (p * 2).rounded() / 2))
    }
}

/// Crop and fit: `full free 9:16 1:1 4:5 16:9` (three by two), `edit crop` when a crop is set, then `fill` / `fit`. Presets
/// need the file's display size; without it the crop row is disabled (the server still has it as it was).
struct EditorCropRows: View {
    let crop: EditCrop?
    let fit: EditFit
    let display: CGSize?
    let onCrop: (EditCrop?) -> Void
    let onFit: (EditFit) -> Void
    /// Switches to the crop tool (Mac) or scrolls to the frame (phone); nil hides the button.
    var onEditCrop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorSegmented<EditCrop.Aspect?>(
                options: [
                    .init(value: nil, title: Copy.Editor.cropFull),
                    .init(value: .free, title: Copy.Editor.cropFree),
                    .init(value: .story, title: EditCrop.Aspect.story.rawValue),
                    .init(value: .square, title: EditCrop.Aspect.square.rawValue),
                    .init(value: .portrait, title: EditCrop.Aspect.portrait.rawValue),
                    .init(value: .wide, title: EditCrop.Aspect.wide.rawValue),
                ],
                selected: .some(crop?.aspect),
                columns: 3,
                isEnabled: display != nil,
                onSelect: choose)
            if crop != nil, let onEditCrop {
                Button(action: onEditCrop) {
                    Label(Copy.Editor.editCrop, systemImage: Symbol.Editor.toolCrop)
                        .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                        .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 28 : 36)
                        .background(EditorColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CobaltColor.linkBlue)
            }
            EditorSection(Copy.Editor.fit) {
                EditorSegmented(
                    options: [.init(value: EditFit.fill, title: Copy.Editor.fitFill), .init(value: .fit, title: Copy.Editor.fitFit)],
                    selected: fit, onSelect: onFit)
            }
        }
    }

    private func choose(_ aspect: EditCrop.Aspect?) {
        guard let aspect else {
            onCrop(nil)
            return
        }
        guard let display, crop?.aspect != aspect else { return }
        onCrop(EditCrop.centred(aspect, display: display))
    }
}

extension EditorSection {
    init(_ title: String, trailing: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: trailing, content: content)
    }
}

/// Volume: a mute button, a 0-100 % slider and the number.
struct EditorVolumeRow: View {
    let volume: Double
    let muted: Bool
    let setVolume: (Double) -> Void
    let setMuted: (Bool) -> Void
    var onEnd: () -> Void = {}
    /// A file with no audio track: the row says `no sound` and does nothing.
    var silent = false

    var body: some View {
        HStack(spacing: 10) {
            Button { setMuted(!muted) } label: {
                Image(systemName: muted ? Symbol.Editor.muted : Symbol.Editor.volume)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(EditorColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted ? CobaltColor.errorText : CobaltColor.text)
            .accessibilityLabel(muted ? Copy.Editor.unmute : Copy.Editor.mute)
            .accessibilityAddTraits(muted ? .isSelected : [])
            .frame(minWidth: Metrics.hit, minHeight: Platform.isMac ? 30 : Metrics.hit)
            if silent {
                Text(Copy.Editor.noSound)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.caption)
                Spacer(minLength: 0)
            } else {
                EditorSlider(
                    value: Binding(get: { volume }, set: setVolume), range: 0...1, step: 0.01, label: Copy.Editor.volume, onEnd: onEnd)
                    .opacity(muted ? 0.45 : 1)
                Text("\(Int((volume * 100).rounded()))%")
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// A destructive text button in the inspector (`delete clip`, `delete overlay`).
struct EditorInspectorButton: View {
    let title: String
    let symbol: String
    var destructive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: symbol)
                .font(Font.cobalt(12, .medium, relativeTo: .caption))
                .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 30 : 40)
                .background(EditorColor.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? CobaltColor.errorText : CobaltColor.text)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
