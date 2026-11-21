import CobaltKit
import SwiftUI

// The editor's pictures (APP-API-CONTRACT 71.4): what the owner sees of the emote while editing. Every one draws through
// `EmoteFaceSource`: the made draft's frames once a draft of the settings on screen is here, else the source picture cropped
// and stretched on the device at once, so a drag or a slider moves the picture without waiting for the server. All of them
// show media, so each wears `.mediaMask()` (PostHog replay).

/// What an editor picture draws and the shape it draws it in.
@MainActor
struct EmoteFaceSource {
    let editor: EmoteEditorModel
    let loader: EmoteSourceLoader
    let playback: EmotePlayback

    /// A draft of the settings on screen is here and its frames are playing.
    var showsDraft: Bool {
        editor.isCurrent && editor.draftData != nil && playback.revision == editor.draftRevision && playback.frame != nil
    }

    /// The device's own crop and squash (the "source" side of the compare line).
    var liveImage: CGImage? {
        guard let image = loader.image else { return nil }
        return Self.cropped(image, editor.settings.crop)
    }

    var draftImage: CGImage? { showsDraft ? playback.frame : nil }

    /// Width over height of the picture as drawn, kept to a range a screen can lay out.
    var aspect: CGFloat {
        if showsDraft, let draft = editor.draft { return Self.clamp(CGFloat(draft.width) / CGFloat(max(1, draft.height))) }
        if let s = editor.stretchedPixels, s.height > 0 { return Self.clamp(CGFloat(s.width / s.height)) }
        if let image = loader.image { return Self.clamp(CGFloat(image.width) / CGFloat(max(1, image.height))) }
        return 1
    }

    var image: CGImage? { draftImage ?? liveImage }

    static func clamp(_ ratio: CGFloat) -> CGFloat { min(max(ratio, 1.0 / 6), 6) }

    /// The box of `image` (fractions) cut out; the whole picture when there is none.
    static func cropped(_ image: CGImage, _ box: ImageCropRect?) -> CGImage {
        guard let b = box?.clamped, !b.isWhole else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: CGFloat(b.x) * w, y: CGFloat(b.y) * h, width: CGFloat(b.w) * w, height: CGFloat(b.h) * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 1, rect.height >= 1 else { return image }
        return image.cropping(to: rect) ?? image
    }
}

/// One picture of the emote at a fixed height; the width follows its shape (a squash is a non-uniform scale of the crop).
struct EmoteFace: View {
    let face: EmoteFaceSource
    let height: CGFloat

    var body: some View {
        picture.mediaMask()
    }

    @ViewBuilder
    private var picture: some View {
        Group {
            if let image = face.image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: height * face.aspect, height: height)
    }
}

/// A picture on the checkerboard, as a chat sees it at `height` pt.
struct EmoteTile: View {
    let face: EmoteFaceSource
    let height: CGFloat

    var body: some View {
        EmoteFace(face: face, height: height)
            .background(Checkerboard(size: max(4, height / 8)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
    }
}

// MARK: - the stage

/// The big picture on the screen that has the room: the crop stage on the crop tab, the compare line on format and compress,
/// the made emote large on squash and frames.
struct EmoteEditorStage: View {
    let editor: EmoteEditorModel
    let loader: EmoteSourceLoader
    let playback: EmotePlayback
    let crop: ImageCropModel?

    private var face: EmoteFaceSource { EmoteFaceSource(editor: editor, loader: loader, playback: playback) }

    var body: some View {
        ZStack {
            switch editor.tab {
            case .crop:
                cropStage
            case .format, .compress:
                EmoteCompare(editor: editor, face: face)
            case .squash, .frames:
                EmoteResultStage(face: face)
            }
            if editor.remaking {
                RemakingChip().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.card, value: editor.tab)
    }

    @ViewBuilder
    private var cropStage: some View {
        if let crop, let image = loader.image {
            ImageCropStage(model: crop, image: image)
                .overlay(alignment: .bottom) { cropBadge.padding(.bottom, 6) }
                .accessibilityLabel(Text(Copy.EmoteEditor.stageA11y))
        } else {
            SourceStatus(loader: loader)
        }
    }

    @ViewBuilder
    private var cropBadge: some View {
        if let out = editor.outputPixels, let ratio = editor.shapeLabel {
            Text(Copy.EmoteEditor.cropBadge(ratio, out.width, out.height))
                .font(CobaltType.captionSmall.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.72), in: Capsule())
        }
    }
}

/// "opening the picture…", or that it would not open.
struct SourceStatus: View {
    let loader: EmoteSourceLoader

    var body: some View {
        VStack(spacing: 8) {
            if loader.state == .failed {
                Image(systemName: Symbol.Gallery.missing).font(.system(size: 24)).foregroundStyle(CobaltColor.caption)
                Text(Copy.EmoteEditor.cantOpen).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            } else {
                ProgressView(Copy.EmoteEditor.loadingSource).font(CobaltType.captionSmall)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemakingChip: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(Copy.EmoteEditor.remaking).font(CobaltType.badge).foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.7), in: Capsule())
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

/// The made emote as large as the stage allows, on the checkerboard.
struct EmoteResultStage: View {
    let face: EmoteFaceSource

    var body: some View {
        GeometryReader { geo in
            let box = EmoteFit.size(aspect: face.aspect, in: geo.size)
            ZStack {
                Checkerboard(size: 12).frame(width: box.width, height: box.height)
                EmoteFace(face: face, height: box.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Copy.EmoteEditor.resultA11y))
        }
    }
}

enum EmoteFit {
    /// The largest box of `aspect` (width over height) inside `bounds`.
    static func size(aspect: CGFloat, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return .zero }
        let w = min(bounds.width, bounds.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }
}

/// The source cropped and squashed on the device against the made file, with a line to drag between them: the compression
/// before 7TV does it. Until a current draft is here only the source shows.
struct EmoteCompare: View {
    let editor: EmoteEditorModel
    let face: EmoteFaceSource

    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let box = EmoteFit.size(aspect: face.aspect, in: geo.size)
            ZStack {
                layers(box)
                tags(box)
                divider(box)
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(drag(box))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Copy.EmoteEditor.compareHint))
    }

    private func layers(_ box: CGSize) -> some View {
        ZStack {
            Checkerboard(size: 12)
            if let live = face.liveImage {
                Image(decorative: live, scale: 1).resizable().interpolation(.high)
            }
            if let made = face.draftImage {
                Image(decorative: made, scale: 1).resizable().interpolation(.high)
                    .mask(alignment: .trailing) { Rectangle().frame(width: box.width * (1 - split)) }
            }
        }
        .frame(width: box.width, height: box.height)
        .mediaMask()
    }

    @ViewBuilder
    private func tags(_ box: CGSize) -> some View {
        if face.showsDraft, let draft = editor.draft {
            VStack {
                HStack {
                    Tag(text: Copy.EmoteEditor.source)
                    Spacer(minLength: 4)
                    Tag(text: Copy.EmoteEditor.compareTag(draft.format, quality: draft.quality))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: box.width, height: box.height)
        }
    }

    @ViewBuilder
    private func divider(_ box: CGSize) -> some View {
        if face.showsDraft {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: box.height)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .position(x: box.width * split, y: box.height / 2)
                .accessibilityHidden(true)
        }
    }

    private func drag(_ box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard box.width > 0 else { return }
            split = min(max(0.02, value.location.x / box.width), 0.98)
        }
    }

    private struct Tag: View {
        let text: String

        var body: some View {
            Text(text)
                .font(CobaltType.badge)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.7), in: Capsule())
        }
    }
}

// MARK: - sizes and chat

/// The emote at 1x, 2x and 4x (28, 56 and 112 pt tall), as chat draws it.
struct EmoteSizes: View {
    let face: EmoteFaceSource
    var scales: [Int] = [1, 2, 4]

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(scales, id: \.self) { k in
                VStack(spacing: 4) {
                    EmoteTile(face: face, height: CGFloat(28 * k))
                    Text(Copy.EmoteEditor.sizeLabel(k))
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Copy.EmoteEditor.atRealSize))
    }
}

/// A fake chat line, dark or light, with the emote twice at 1x.
struct EmoteChatLine: View {
    let face: EmoteFaceSource
    let light: Bool

    private var ink: Color { light ? .black : .white }

    var body: some View {
        HStack(spacing: 6) {
            Text(Copy.EmoteEditor.chatName)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(Color(hex: 0xb4308b))
            Text(light ? Copy.EmoteEditor.chatLight : Copy.EmoteEditor.chatLine)
                .font(CobaltType.body)
                .foregroundStyle(ink)
                .lineLimit(1)
            EmoteFace(face: face, height: 28)
            if !light { EmoteFace(face: face, height: 28) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(light ? Color.white : Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Copy.EmoteEditor.chatName): \(light ? Copy.EmoteEditor.chatLight : Copy.EmoteEditor.chatLine)"))
    }
}

/// The result's weight against 7TV's cap: a bar that fills, amber near it, red over it.
struct EmoteMeter: View {
    let editor: EmoteEditorModel

    private var tint: Color {
        guard let draft = editor.draft else { return CobaltColor.caption }
        if draft.bytes > EmoteLimits.capBytes { return CobaltColor.error }
        return draft.overCap || editor.meterFraction > 0.85 ? Color.orange : CobaltColor.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let out = editor.outputPixels {
                    Text("\(out.width) × \(out.height)").font(CobaltType.bodySemibold.monospacedDigit()).foregroundStyle(CobaltColor.text)
                }
                Spacer(minLength: 6)
                if let draft = editor.draft, editor.isCurrent, draft.isAnimated {
                    Text(Copy.EmoteEditor.playing(frames: draft.frames, seconds: draft.seconds))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CobaltColor.elevated)
                    Capsule().fill(tint).frame(width: max(4, geo.size.width * editor.meterFraction))
                }
            }
            .frame(height: 6)
            HStack {
                Text(editor.draft.map { EmoteEditorModel.megabytes($0.bytes) } ?? "-")
                    .font(CobaltType.captionSmall.monospacedDigit())
                    .foregroundStyle(tint == CobaltColor.caption ? CobaltColor.caption : CobaltColor.text)
                Spacer(minLength: 6)
                Text(Copy.EmoteEditor.cap("7 MB")).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            }
            if editor.draft?.overCap == true {
                Text(Copy.EmoteEditor.overCap).font(CobaltType.captionSmall).foregroundStyle(Color.orange)
            }
        }
        .padding(12)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The two-by-two ticks: shape, pixels, frames, bytes. A tick turns amber or red before the upload, not after 7TV drops the file.
struct EmoteChecks: View {
    let editor: EmoteEditorModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(editor.checks) { check in
                EmoteCheckPill(check: check)
            }
        }
    }
}

private struct EmoteCheckPill: View {
    let check: EmoteCheck

    private var symbol: String {
        switch check.tone {
        case .ok: return Symbol.EmoteEditor.tickOK
        case .warn: return Symbol.EmoteEditor.tickWarn
        case .bad: return Symbol.EmoteEditor.tickBad
        case .unknown: return Symbol.EmoteEditor.tickUnknown
        }
    }

    private var tint: Color {
        switch check.tone {
        case .ok: return CobaltColor.success
        case .warn: return Color.orange
        case .bad: return CobaltColor.error
        case .unknown: return CobaltColor.caption
        }
    }

    private var name: String {
        switch check.kind {
        case .shape: return Copy.EmoteEditor.shape
        case .pixels: return check.value ?? "-"
        case .frames: return check.value.map { Copy.EmoteEditor.framesValue(Int($0) ?? 0) } ?? Copy.EmoteEditor.frameCount
        case .bytes: return check.value ?? "-"
        }
    }

    private var text: String {
        switch check.kind {
        case .shape: return "\(Copy.EmoteEditor.shape) \(check.value ?? "-")"
        default: return name
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 13)).accessibilityHidden(true)
            Text(text).font(CobaltType.captionSmall.monospacedDigit()).foregroundStyle(CobaltColor.text).lineLimit(1)
            Spacer(minLength: 2)
            Text(check.limit).font(CobaltType.badge.monospacedDigit()).foregroundStyle(CobaltColor.caption).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Copy.EmoteEditor.tickA11y(text, value: check.limit, ok: check.tone == .ok)))
    }
}

// MARK: - the seam

/// The line between the two panes (the hinge of a two-screen phone, `HingeSeam`): it glows while the server remakes the file.
struct EmoteSeam: View {
    let active: Bool

    @State private var lit = false

    var body: some View {
        ZStack {
            Rectangle().fill(CobaltColor.hairline).frame(width: 1)
            if active {
                Capsule()
                    .fill(LinearGradient(colors: [CobaltColor.success.opacity(0.25), CobaltColor.success], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3)
                    .shadow(color: CobaltColor.success.opacity(0.8), radius: 5)
                    .padding(.vertical, 24)
                    .opacity(lit ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: lit)
                    .onAppear { lit = true }
                    .onDisappear { lit = false }
                    .transition(.opacity)
            }
        }
        .frame(width: 5)
        .animation(Motion.fade, value: active)
        .accessibilityHidden(true)
    }
}
