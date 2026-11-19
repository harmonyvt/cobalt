import CobaltKit
import SwiftUI

// Shared: the blocks of the timeline. They draw and describe; gestures and layout are the caller's, so the Mac's lanes and the
// iPhone's scrolling track compose the same views. Heights are the caller's too (the Mac board's lane is 52 pt, a block 40).

/// What VoiceOver can do with a clip or an overlay (apple/CONTRACT-EDITOR.md 8). A nil closure leaves the action out.
struct TimelineClipActions {
    var select: () -> Void = {}
    var moveEarlier: (() -> Void)?
    var moveLater: (() -> Void)?
    var split: (() -> Void)?
    var delete: (() -> Void)?
    var trim: (() -> Void)?
    /// An overlay: up or down a layer (39.1); nil when it cannot go that way.
    var layerUp: (() -> Void)?
    var layerDown: (() -> Void)?
    /// Equal lanes. Nil leaves the action out. `hideTitle` is "hide this clip" or "show this clip".
    var effect: (() -> Void)?
    var cutout: (() -> Void)?
    var duplicateClip: (() -> Void)?
    var hide: (() -> Void)?
    var hideTitle = Copy.Editor.hideThisClip
    var newLane: (() -> Void)?
    /// VoiceOver "move to lane …", and any dimmed row whose name includes the reason.
    var extra: [(name: String, run: () -> Void)] = []
}

private struct TimelineClipAccessibility: ViewModifier {
    let label: String
    let selected: Bool
    let actions: TimelineClipActions

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { actions.select() }
            .accessibilityAction(named: Copy.Editor.selectAction) { actions.select() }
            .modifier(OptionalAction(name: Copy.Editor.a11yMoveEarlier, run: actions.moveEarlier))
            .modifier(OptionalAction(name: Copy.Editor.a11yMoveLater, run: actions.moveLater))
            .modifier(OptionalAction(name: Copy.Editor.splitAtPlayhead, run: actions.split))
            .modifier(OptionalAction(name: Copy.Editor.deleteClip, run: actions.delete))
            .modifier(OptionalAction(name: Copy.Editor.trimAction, run: actions.trim))
            .modifier(OptionalAction(name: Copy.Editor.layerUp, run: actions.layerUp))
            .modifier(OptionalAction(name: Copy.Editor.layerDown, run: actions.layerDown))
            .modifier(OptionalAction(name: Copy.Editor.applyEffect, run: actions.effect))
            .modifier(OptionalAction(name: Copy.Editor.cutOutOrKey, run: actions.cutout))
            .modifier(OptionalAction(name: Copy.Editor.duplicateClip, run: actions.duplicateClip))
            .modifier(OptionalAction(name: actions.hideTitle, run: actions.hide))
            .modifier(OptionalAction(name: Copy.Editor.moveToNewLane, run: actions.newLane))
            .modifier(LaneAccessibilityExtras(actions: actions.extra))
    }
}

/// A variable list of VoiceOver actions (one per other lane, plus a dimmed row and its reason).
private struct LaneAccessibilityExtras: ViewModifier {
    let actions: [(name: String, run: () -> Void)]

    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: action.name) { action.run() })
        }
    }
}

private struct OptionalAction: ViewModifier {
    let name: String
    let run: (() -> Void)?

    func body(content: Content) -> some View {
        if let run {
            content.accessibilityAction(named: name) { run() }
        } else {
            content
        }
    }
}

// MARK: - the main track

/// One clip of the main track: poster filmstrip over its file's colour, name, badges (`1.5×`, `crop`, `fit`, a muted
/// speaker), a thin download bar, and `sourceFailed` / `missingClip` states.
///
/// Trim handles are not part of it: `TimelineTrimHandle` goes over its edges when the clip is selected.
struct TimelineMainClipView: View {
    let clip: EditClip
    /// 1-based place in the track.
    let number: Int
    let source: EditSource?
    /// The clip's length on the timeline (frames / fps).
    let seconds: Double
    let width: CGFloat
    let height: CGFloat
    var isSelected = false
    /// 0...1 while its file downloads.
    var loading: Double?
    var failed = false
    var missing = false
    var actions = TimelineClipActions()

    var body: some View {
        ZStack(alignment: .topLeading) {
            filmstrip
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
            label
            if let loading { downloadBar(loading) }
            if failed || missing { problem }
        }
        .frame(width: max(2, width), height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? EditorColor.selection : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .modifier(TimelineClipAccessibility(
            label: Copy.Editor.a11yClip(
                n: number, name: source?.shortName ?? "", seconds: seconds, speed: clip.speed,
                cropped: clip.crop.map { !$0.isFull } ?? false, muted: clip.muted, selected: isSelected),
            selected: isSelected, actions: actions))
    }

    private var filmstrip: some View {
        TimelineFilmstrip(url: source?.posterURL, color: EditorColor.clip(for: clip.item), width: width, height: height)
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(source?.shortName ?? "")
                .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                .lineLimit(1)
            if abs(clip.speed - 1) > 0.001 { badge(Copy.Editor.speedValue(clip.speed)) }
            if abs(clip.pitch) > 0.001 { badge(Copy.Editor.pitchChip(clip.pitch)) }
            if clip.crop.map({ !$0.isFull }) ?? false { badge(Copy.Editor.crop) }
            if clip.fit == .fit { badge(Copy.Editor.fitFit) }
            if clip.muted {
                Image(systemName: Symbol.Editor.muted)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 3)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .foregroundStyle(EditorColor.clipInk)
        .padding(.horizontal, 9)
        .padding(.top, 5)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(9.5, .regular, relativeTo: .caption2))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func downloadBar(_ fraction: Double) -> some View {
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.4))
                Rectangle().fill(EditorColor.clipInk.opacity(0.9)).frame(width: width * min(1, max(0, fraction)))
            }
            .frame(height: 3)
        }
        .frame(width: width, height: height)
    }

    private var problem: some View {
        ZStack {
            Color.black.opacity(0.55)
            HStack(spacing: 4) {
                Image(systemName: Symbol.Editor.missing)
                    .font(.system(size: 10, weight: .semibold))
                if width > 90 {
                    Text(missing ? Copy.Editor.missingClip : Copy.Editor.sourceFailed)
                        .font(Font.cobalt(9.5, .regular, relativeTo: .caption2))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(EditorColor.clipInk)
            .padding(.horizontal, 6)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - the overlay lane

/// One overlay: amber outline over its file's poster (a video, GIF or photo), name, and a `gif` / `photo` tag.
struct TimelineOverlayClipView: View {
    let overlay: EditOverlay
    let source: EditSource?
    let seconds: Double
    let width: CGFloat
    let height: CGFloat
    var isSelected = false
    var missing = false
    var showsEffect = false
    var actions = TimelineClipActions()

    var body: some View {
        ZStack(alignment: .topLeading) {
            EditorPoster(url: source?.posterURL, fallback: EditorColor.clip(for: overlay.item), maxPixel: 160)
                .frame(width: max(2, width), height: height)
                .opacity(0.6)
            HStack(spacing: 5) {
                Text(source?.shortName ?? "")
                    .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                    .lineLimit(1)
                if let tag = tag { Text(tag).font(Font.cobalt(9.5, .regular, relativeTo: .caption2)).opacity(0.85).fixedSize() }
                if showsEffect {
                    Text(Copy.Editor.effectMark)
                        .font(Font.cobalt(9, .semibold, relativeTo: .caption2))
                        .padding(.horizontal, 3)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .accessibilityLabel(Copy.Editor.effects)
                }
                if missing { Image(systemName: Symbol.Editor.missing).font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(EditorColor.clipInk)
            .padding(.horizontal, 9)
            .padding(.top, 5)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .frame(width: max(2, width), alignment: .leading)
            .clipped()
        }
        .frame(width: max(2, width), height: height, alignment: .topLeading)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(EditorColor.overlay, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .modifier(TimelineClipAccessibility(
            label: Copy.Editor.a11yOverlay(
                name: source?.shortName ?? "", start: overlay.at, seconds: seconds, selected: isSelected),
            selected: isSelected, actions: actions))
    }

    private var tag: String? {
        switch source?.kind {
        case .gif?: return Copy.Editor.badgeGif
        case .photo?: return Copy.Editor.badgePhoto
        default: return nil
        }
    }
}

// MARK: - one clip, any lane

/// A clip on an equal lane. Lane 0 and the rows above it draw the same block: poster, name, speed, a gif or photo tag,
/// an fx mark. A hidden clip stays put and fades. The selection ring is the same blue on every lane.
struct TimelineLaneClipView: View {
    let clip: EditLaneClip
    let source: EditSource?
    let seconds: Double
    let width: CGFloat
    let height: CGFloat
    var isSelected = false
    var loading: Double?
    var failed = false
    var missing = false
    var showsEffect = false
    var actions = TimelineClipActions()

    var body: some View {
        ZStack(alignment: .topLeading) {
            filmstrip
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
            label
            if let loading { download(loading) }
            if failed || missing { problem }
        }
        .frame(width: max(2, width), height: height, alignment: .topLeading)
        .opacity(clip.hidden ? 0.4 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? EditorColor.selection : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .modifier(TimelineClipAccessibility(
            label: Copy.Editor.a11yLaneClip(
                lane: clip.lane, name: source?.shortName ?? "", seconds: seconds, speed: clip.speed,
                hidden: clip.hidden, selected: isSelected),
            selected: isSelected, actions: actions))
    }

    private var filmstrip: some View {
        TimelineFilmstrip(url: source?.posterURL, color: EditorColor.clip(for: clip.item), width: width, height: height)
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(source?.shortName ?? "")
                .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                .lineLimit(1)
            if let tag { Text(tag).font(Font.cobalt(9.5, .regular, relativeTo: .caption2)).opacity(0.85).fixedSize() }
            if abs(clip.speed - 1) > 0.001 { badge(Copy.Editor.speedValue(clip.speed)) }
            if abs(clip.pitch) > 0.001 { badge(Copy.Editor.pitchChip(clip.pitch)) }
            if clip.crop.map({ !$0.isFull }) ?? false { badge(Copy.Editor.crop) }
            if showsEffect { badge(Copy.Editor.effectMark) }
            if clip.muted {
                Image(systemName: Symbol.Editor.muted)
                    .font(.system(size: 9, weight: .semibold))
            }
            if clip.hidden {
                Image(systemName: Symbol.Editor.layerHide)
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(EditorColor.clipInk)
        .padding(.horizontal, 9)
        .padding(.top, 5)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    private var tag: String? {
        switch source?.kind {
        case .gif?: return Copy.Editor.badgeGif
        case .photo?: return Copy.Editor.badgePhoto
        default: return nil
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(9.5, .regular, relativeTo: .caption2))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func download(_ fraction: Double) -> some View {
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.4))
                Rectangle().fill(EditorColor.clipInk.opacity(0.9)).frame(width: width * min(1, max(0, fraction)))
            }
            .frame(height: 3)
        }
        .frame(width: width, height: height)
    }

    private var problem: some View {
        ZStack {
            Color.black.opacity(0.55)
            Image(systemName: Symbol.Editor.missing)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EditorColor.clipInk)
        }
        .frame(width: width, height: height)
    }
}

/// The small bar over a selected clip: effect, split, duplicate, hide, delete.
struct LaneClipToolbar: View {
    let hidden: Bool
    let run: (LaneMenuAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            tool(Symbol.Editor.effects, Copy.Editor.applyEffect, .effect, false)
            tool(Symbol.Editor.split, Copy.Editor.splitAtPlayhead, .split, false)
            tool(Symbol.Editor.overlay, Copy.Editor.duplicateClip, .duplicate, false)
            tool(hidden ? Symbol.Editor.layerShow : Symbol.Editor.layerHide, hidden ? Copy.Editor.showThisClip : Copy.Editor.hideThisClip, .hide, false)
            tool(Symbol.Editor.delete, Copy.Editor.deleteClipShort, .delete, true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay { Capsule().strokeBorder(EditorColor.line, lineWidth: 1) }
    }

    private func tool(_ symbol: String, _ title: String, _ action: LaneMenuAction, _ destructive: Bool) -> some View {
        Button { run(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive ? CobaltColor.errorText : EditorColor.clipInk)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - the audio lane

/// A main clip's level in the audio lane: a bar as tall as its volume; a muted clip is hatched with a speaker-slash.
struct TimelineAudioBar: View {
    let volume: Double
    let muted: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(CobaltColor.surface)
                .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CobaltColor.border.opacity(0.5), lineWidth: 1) }
            if muted {
                Hatching()
                    .stroke(CobaltColor.caption.opacity(0.45), lineWidth: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: Symbol.Editor.muted)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(CobaltColor.caption.opacity(0.55))
                    .frame(height: max(3, (height - 4) * min(1, max(0, volume))))
                    .padding(2)
            }
        }
        .frame(width: max(2, width), height: height)
        .accessibilityHidden(true)
    }
}

private struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += 7
        }
        return path
    }
}

// MARK: - trim handles

/// A blue trim handle at a selected clip's edge. Drag reports the distance moved since the drag began, in points of the
/// window (`.global`), so it stays steady while the clip it trims changes size under the finger. The hit area is wider than
/// the 7 pt bar (12 pt with a pointer, 24 pt for a finger).
///
/// VoiceOver sees an adjustable element named `start` / `end` with the time as its value; increment and decrement call
/// `step` with +1 and -1 (one frame).
struct TimelineTrimHandle: View {
    enum Edge { case leading, trailing }

    let edge: Edge
    let height: CGFloat
    /// The time shown to VoiceOver, e.g. "0:02.0".
    let valueText: String
    var color: Color = EditorColor.selection
    /// Distance in points since the drag began (positive = right).
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let step: (Int) -> Void

    static let barWidth: CGFloat = 7
    static var hitWidth: CGFloat { Platform.isMac ? 12 : 24 }

    @State private var dragging = false

    var body: some View {
        let bar = UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 6 : 0, bottomLeadingRadius: edge == .leading ? 6 : 0,
            bottomTrailingRadius: edge == .trailing ? 6 : 0, topTrailingRadius: edge == .trailing ? 6 : 0)
        return bar
            .fill(color)
            .frame(width: Self.barWidth, height: height)
            .overlay {
                Capsule().fill(.white.opacity(0.85)).frame(width: 2, height: min(14, height * 0.4))
            }
            .frame(width: Self.hitWidth, height: height, alignment: edge == .leading ? .leading : .trailing)
            .contentShape(Rectangle())
            .columnResizePointer()
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        dragging = true
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(edge == .leading ? Copy.Editor.a11yTrimStart : Copy.Editor.a11yTrimEnd)
            .accessibilityValue(valueText)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
    }
}

extension View {
    /// The column-resize pointer on the Mac (`pointerStyle` does not exist on iOS).
    @ViewBuilder func columnResizePointer() -> some View {
        #if os(macOS)
        pointerStyle(.columnResize)
        #else
        self
        #endif
    }

    /// The row-resize pointer on the Mac.
    @ViewBuilder func rowResizePointer() -> some View {
        #if os(macOS)
        pointerStyle(.rowResize)
        #else
        self
        #endif
    }
}

/// A main clip's filmstrip: the poster loaded once (as `EditorPoster` does) and drawn as plain tiles, so a long clip or a zoom
/// does not start one loader per tile.
private struct TimelineFilmstrip: View {
    let url: URL?
    let color: Color
    let width: CGFloat
    let height: CGFloat
    @State private var image: ImageBox?

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View { mediaBody.mediaMask() }

    @ViewBuilder private var mediaBody: some View {
        let tile = max(24, height * 0.8)
        let count = min(32, max(1, Int((width / tile).rounded(.up))))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                color
                    .overlay {
                        if let image {
                            Image(decorative: image.image, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        }
                    }
                    .clipped()
                    .frame(width: tile, height: height)
                    .opacity(0.55)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(color)
        .clipped()
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let source: LibraryPictureSource = url.isFileURL ? .file(url) : .image(url)
            image = await LibraryPictureLoader.shared.picture(source, maxPixel: 160)
        }
    }
}
