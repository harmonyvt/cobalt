import CobaltKit
import SwiftUI

// The editor's tab bar and each tab's controls (APP-API-CONTRACT 71.4, mockup scenes "emote …"): crop · squash · format ·
// compress · frames (frames only for a video or an animated picture). Every control calls `editor.edit`, so the picture moves
// at once and the remake follows 0.4 s after the last touch.

struct EmoteTabBar: View {
    let editor: EmoteEditorModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(editor.tabs) { tab in
                EmoteTabButton(tab: tab, selected: editor.tab == tab) { editor.tab = tab }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.chip, value: editor.tab)
    }
}

private struct EmoteTabButton: View {
    let tab: EmoteEditorModel.Tab
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch tab {
        case .crop: return Symbol.EmoteEditor.crop
        case .squash: return Symbol.EmoteEditor.squash
        case .format: return Symbol.EmoteEditor.format
        case .compress: return Symbol.EmoteEditor.compress
        case .frames: return Symbol.EmoteEditor.frames
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17)).frame(height: 22)
                Text(Copy.EmoteEditor.tab(tab)).font(CobaltType.tab).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? CobaltColor.text : CobaltColor.caption)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(selected ? CobaltColor.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Copy.EmoteEditor.tab(tab)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The controls of the tab that is picked.
struct EmoteTabControls: View {
    let editor: EmoteEditorModel
    let crop: ImageCropModel?
    let loader: EmoteSourceLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch editor.tab {
            case .crop: EmoteCropControls(editor: editor, crop: crop)
            case .squash: EmoteSquashControls(editor: editor)
            case .format: EmoteFormatControls(editor: editor)
            case .compress: EmoteCompressControls(editor: editor)
            case .frames: EmoteFramesControls(editor: editor, loader: loader)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tab's title with its one-line note and an optional trailing button.
struct EmoteSectionHeader: View {
    let title: String
    let note: String
    var trailing: (title: String, symbol: String, action: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text).accessibilityAddTraits(.isHeader)
            Text(note).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).lineLimit(2)
            Spacer(minLength: 6)
            if let trailing {
                Button(trailing.title, systemImage: trailing.symbol, action: trailing.action)
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
    }
}

// MARK: - crop

private struct EmoteCropControls: View {
    let editor: EmoteEditorModel
    let crop: ImageCropModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmoteSectionHeader(
                title: Copy.EmoteEditor.cropTitle, note: Copy.EmoteEditor.cropNote,
                trailing: (Copy.EmoteEditor.cropReset, Symbol.EmoteEditor.remake, resetCrop))
            if let crop {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ImageCropModel.Aspect.sevenTv) { aspect in
                            SevenTvChip(title: aspect.label, selected: crop.aspect == aspect) { crop.choose(aspect) }
                        }
                    }
                }
            }
            if let px = editor.sourcePixels, let s = editor.stretchedPixels {
                Text(Copy.EmoteEditor.cropSize(Int((s.width / editor.settings.stretch.w).rounded()), Int((s.height / editor.settings.stretch.h).rounded())))
                    .font(CobaltType.captionSmall.monospacedDigit())
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHint(Text("\(px.width) × \(px.height)"))
            }
        }
    }

    private func resetCrop() {
        crop?.reset()
        editor.setCrop(nil)
    }
}

// MARK: - squash

private struct EmoteSquashControls: View {
    let editor: EmoteEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmoteSectionHeader(
                title: Copy.EmoteEditor.squash, note: Copy.EmoteEditor.squashNote,
                trailing: (Copy.EmoteEditor.reset, Symbol.EmoteEditor.remake, { editor.apply(.reset) }))
            EmoteStretchSlider(
                title: Copy.EmoteEditor.wide, symbol: Symbol.EmoteEditor.wide, value: editor.settings.stretch.w,
                set: { editor.setStretchW($0) })
            EmoteStretchSlider(
                title: Copy.EmoteEditor.tall, symbol: Symbol.EmoteEditor.tall, value: editor.settings.stretch.h,
                set: { editor.setStretchH($0) })
            presets
        }
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                LinkChip(linked: Binding(get: { editor.linked }, set: { editor.linked = $0 }))
                PresetChip(title: Copy.EmoteEditor.presetSquish, symbol: Symbol.EmoteEditor.squish) { editor.apply(.squish) }
                PresetChip(title: Copy.EmoteEditor.presetTall, symbol: Symbol.EmoteEditor.tallBoi) { editor.apply(.tall) }
                PresetChip(title: Copy.EmoteEditor.presetWide, symbol: Symbol.EmoteEditor.wideThree) { editor.apply(.wide) }
            }
        }
    }
}

/// A squash slider from 25 % to 400 % on a log scale, so 100 % sits in the middle and the thumb moves the same distance for
/// halving as for doubling.
private struct EmoteStretchSlider: View {
    let title: String
    let symbol: String
    let value: Double
    let set: (Double) -> Void

    private var position: Binding<Double> {
        Binding(
            get: { (log2(max(0.25, min(4, value))) + 2) / 4 },
            set: { t in
                var v = pow(2, t * 4 - 2)
                if abs(v - 1) < 0.03 { v = 1 }        // a soft stop on 100 %
                set(v)
            })
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .frame(width: 64, alignment: .leading)
            Slider(value: position, in: 0...1)
                .tint(CobaltColor.text)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(Copy.EmoteEditor.percent(value)))
            Text(Copy.EmoteEditor.percent(value))
                .font(CobaltType.bodySemibold.monospacedDigit())
                .foregroundStyle(CobaltColor.text)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }
}

private struct LinkChip: View {
    @Binding var linked: Bool

    var body: some View {
        Button { linked.toggle() } label: {
            Label(
                linked ? Copy.EmoteEditor.linked : Copy.EmoteEditor.unlinked,
                systemImage: linked ? Symbol.EmoteEditor.linked : Symbol.EmoteEditor.unlinked)
                .font(Font.cobalt(11.5, linked ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(linked ? CobaltColor.onText : CobaltColor.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(linked ? CobaltColor.text : CobaltColor.elevated))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(linked ? .isSelected : [])
    }
}

private struct PresetChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(CobaltColor.elevated))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - format

private struct EmoteFormatControls: View {
    let editor: EmoteEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmoteSectionHeader(title: Copy.EmoteEditor.formatTitle, note: "")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(EmoteFormat.allCases, id: \.self) { format in
                    FormatCard(format: format, selected: editor.settings.format == format) {
                        editor.edit { $0.format = format }
                    }
                }
            }
            if editor.settings.format == .png, editor.source.isVideo {
                stillAt
            }
        }
    }

    /// A png of a video is one frame: the moment's start unless another second is picked.
    private var stillAt: some View {
        let seconds = editor.settings.frame ?? editor.settings.start
        let top = max(editor.settings.start + 0.1, editor.videoDuration ?? editor.settings.end)
        return HStack(spacing: 10) {
            Text(Copy.EmoteEditor.pngStillAt).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            Slider(
                value: Binding(get: { seconds }, set: { v in editor.edit { $0.frame = v } }),
                in: 0...max(0.2, top)
            )
            .tint(CobaltColor.text)
            Text(String(format: "%.1f s", seconds)).font(CobaltType.captionSmall.monospacedDigit()).foregroundStyle(CobaltColor.text)
        }
    }
}

private struct FormatCard: View {
    let format: EmoteFormat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.EmoteEditor.formatName(format)).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text)
                Text(Copy.EmoteEditor.formatNote(format))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? CobaltColor.focus : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - compress

private struct EmoteCompressControls: View {
    let editor: EmoteEditorModel

    private var animated: Bool { editor.settings.format != .png }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmoteSectionHeader(
                title: Copy.EmoteEditor.compressTitle,
                note: editor.settings.autoQuality ? Copy.EmoteEditor.autoNote : Copy.EmoteEditor.fixedNote,
                trailing: nil)
            HStack(spacing: 8) {
                AutoChip(on: Binding(get: { editor.settings.autoQuality }, set: { v in editor.edit { $0.autoQuality = v } }))
                Spacer(minLength: 0)
                Button(Copy.EmoteEditor.remake, systemImage: Symbol.EmoteEditor.remake) { editor.remakeNow() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            VStack(spacing: 4) {
                if animated {
                    EmoteValueSlider(
                        title: Copy.EmoteEditor.quality, value: Double(editor.settings.quality), range: 1...100,
                        text: "\(editor.settings.quality)", disabled: editor.settings.autoQuality
                    ) { v in editor.edit { $0.quality = Int(v.rounded()) } }
                }
                EmoteValueSlider(
                    title: Copy.EmoteEditor.longestSide, value: Double(editor.settings.size), range: 32...1000,
                    text: Copy.EmoteEditor.pixels(editor.settings.size), disabled: false
                ) { v in editor.edit { $0.size = Int(v.rounded()) } }
                if animated, editor.hasFrames {
                    EmoteValueSlider(
                        title: Copy.EmoteEditor.frameRate, value: Double(editor.settings.fps),
                        range: Double(EmoteLimits.fpsRange.lowerBound)...Double(EmoteLimits.fpsRange.upperBound),
                        text: Copy.EmoteEditor.fps(editor.settings.fps), disabled: false
                    ) { v in editor.edit { $0.fps = Int(v.rounded()) } }
                }
            }
            .padding(12)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EmoteLimits.sizeChoices, id: \.self) { choice in
                        SevenTvChip(title: Copy.EmoteEditor.pixels(choice), selected: editor.settings.size == choice) {
                            editor.edit { $0.size = choice }
                        }
                    }
                }
            }
        }
    }
}

private struct AutoChip: View {
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            Label(Copy.EmoteEditor.auto, systemImage: Symbol.EmoteEditor.auto)
                .font(Font.cobalt(12, on ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(on ? CobaltColor.text : CobaltColor.elevated))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A named slider with its value at the end.
struct EmoteValueSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let text: String
    let disabled: Bool
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .tint(CobaltColor.text)
                .disabled(disabled)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(text))
            Text(text)
                .font(CobaltType.bodySemibold.monospacedDigit())
                .foregroundStyle(disabled ? CobaltColor.caption : CobaltColor.text)
                .frame(width: 60, alignment: .trailing)
        }
        .frame(minHeight: 34)
    }
}

// MARK: - frames

private struct EmoteFramesControls: View {
    let editor: EmoteEditorModel
    let loader: EmoteSourceLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.source.isVideo {
                EmoteSectionHeader(
                    title: Copy.EmoteEditor.framesTitle,
                    note: Copy.EmoteEditor.momentRange(editor.settings.start, editor.settings.end, of: editor.videoDuration),
                    trailing: nil)
                EmoteMomentStrip(editor: editor, loader: loader)
            } else {
                EmoteSectionHeader(title: Copy.EmoteEditor.frames, note: "", trailing: nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EmoteLimits.fpsChoices, id: \.self) { n in
                        SevenTvChip(title: Copy.EmoteEditor.fps(n), selected: editor.settings.fps == n) { editor.edit { $0.fps = n } }
                    }
                }
            }
            Text(Copy.EmoteEditor.fpsNote).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
            HStack(spacing: 6) {
                SevenTvChip(title: Copy.EmoteEditor.loop, selected: !editor.settings.bounce) { editor.edit { $0.bounce = false } }
                SevenTvChip(title: Copy.EmoteEditor.bounce, selected: editor.settings.bounce) { editor.edit { $0.bounce = true } }
                if editor.source.isVideo {
                    Label(Copy.EmoteEditor.noSound, systemImage: Symbol.EmoteEditor.muted)
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.caption)
                        .padding(.leading, 6)
                }
            }
        }
    }
}

/// The clip's frames with an amber window over the moment: drag it to slide the moment (its length stays), drag a side to
/// change the length (0.2 to 10 s). The stage shows the frame at the window's start.
private struct EmoteMomentStrip: View {
    let editor: EmoteEditorModel
    let loader: EmoteSourceLoader

    private struct Grab {
        let start: Double
        let end: Double
    }

    @State private var grab: Grab?

    private let height: CGFloat = 54

    var body: some View {
        GeometryReader { geo in
            let total = max(0.1, editor.videoDuration ?? editor.settings.end)
            let width = geo.size.width
            let x0 = width * editor.settings.start / total
            let x1 = width * editor.settings.end / total
            ZStack(alignment: .leading) {
                frames.frame(width: width, height: height)
                window(x0: x0, x1: x1)
            }
            .contentShape(Rectangle())
            .gesture(drag(width: width, total: total, x0: x0, x1: x1))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Copy.EmoteEditor.momentNote))
        .accessibilityValue(Text(Copy.EmoteEditor.momentRange(editor.settings.start, editor.settings.end, of: editor.videoDuration)))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            editor.slideMoment(to: editor.settings.start + step)
            loader.showFrame(at: editor.settings.start)
        }
    }

    private var frames: some View {
        HStack(spacing: 0) {
            if loader.strip.isEmpty {
                Rectangle().fill(CobaltColor.elevated)
            } else {
                ForEach(Array(loader.strip.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1).resizable().scaledToFill().frame(maxWidth: .infinity).clipped()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .mediaMask()
    }

    private func window(x0: CGFloat, x1: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.orange, lineWidth: 3)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: max(14, x1 - x0), height: height)
            .offset(x: x0)
    }

    /// A drag that begins near a side of the window moves that side; anywhere else it slides the window.
    private func drag(width: CGFloat, total: Double, x0: CGFloat, x1: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            if grab == nil { grab = Grab(start: editor.settings.start, end: editor.settings.end) }
            guard let grab, width > 0 else { return }
            let delta = Double((value.location.x - value.startLocation.x) / width) * total
            let edge: CGFloat = 16
            let begin = value.startLocation.x
            if abs(begin - x0) < edge, abs(begin - x0) <= abs(begin - x1) {
                editor.setMoment(start: grab.start + delta, end: grab.end)
            } else if abs(begin - x1) < edge {
                editor.setMoment(start: grab.start, end: grab.end + delta)
            } else {
                let length = grab.end - grab.start
                editor.setMoment(start: grab.start + delta, end: grab.start + delta + length)
            }
            loader.showFrame(at: editor.settings.start)
        }
        .onEnded { _ in grab = nil }
    }
}
