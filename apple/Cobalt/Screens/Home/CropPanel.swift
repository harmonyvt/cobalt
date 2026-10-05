import CobaltKit
import SwiftUI

/// The card under the planet while the crop editor is open: the shape presets, the size the webp will
/// be, and done / reset. It replaces the trim panel (or the choices) for as long as the editor is up.
struct CropPanel: View {
    let model: CropEditorModel
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.dynamicTypeSize) private var typeSize

    private var shape: Binding<CropRect.Aspect> {
        Binding(
            get: { model.aspect },
            set: { new in withAnimation(reduceMotion ? nil : Motion.rows) { model.choose(new) } })
    }

    var body: some View {
        let valid = model.isValid
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(CropCopy.crop, systemImage: CropCopy.symbol)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
                Text(CropCopy.readout(model.output))
                    .font(Font.cobalt(20, .medium, relativeTo: .title3).monospacedDigit())
                    .foregroundStyle(valid ? CobaltColor.text : CobaltColor.errorText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .accessibilityLabel(CropCopy.readoutA11y(model.output))
            }
            presets
            Group {
                if valid {
                    Text(CropCopy.note).foregroundStyle(CobaltColor.caption)
                } else {
                    Label(CropCopy.tooSmall, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CobaltColor.errorText)
                        .accessibilityLabel(CropCopy.tooSmallA11y)
                }
            }
            .font(CobaltType.caption)
            .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .haptic(.selection, trigger: model.snaps, enabled: haptics) { $0 > 0 }
        .accessibilityElement(children: .contain)
    }

    /// Segmented on a phone; a menu where the six labels cannot sit side by side (the largest text sizes).
    @ViewBuilder
    private var presets: some View {
        let picker = Picker(CropCopy.shape, selection: shape) {
            ForEach(CropRect.Aspect.allCases, id: \.self) { Text(CropCopy.label($0)).tag($0) }
        }
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            picker.pickerStyle(.segmented).labelsHidden()
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { doneButton; resetButton }
            VStack(spacing: 10) { doneButton; resetButton }
        }
    }

    private var doneButton: some View {
        Button(CropCopy.done, systemImage: Symbol.keep, action: onDone)
            .buttonStyle(.cobaltPrimary())
            .keyboardShortcut(.defaultAction)
            .disabled(!model.isValid)
    }

    private var resetButton: some View {
        Button(CropCopy.reset, systemImage: Symbol.reset) {
            withAnimation(reduceMotion ? nil : Motion.rows) { model.reset() }
        }
        .buttonStyle(.cobaltSecondary(fullWidth: false))
    }
}

/// The small "crop 1:1" badge next to the trim readout: a glass capsule like the planet's file-type badge.
struct CropBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: CropCopy.symbol)
            .font(Font.cobalt(11, .medium, relativeTo: .caption))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(CobaltColor.badgeInk)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 24)
            .glassEffect(.regular.tint(CobaltColor.badgeBack), in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CropCopy.badgeA11y(text))
    }
}
