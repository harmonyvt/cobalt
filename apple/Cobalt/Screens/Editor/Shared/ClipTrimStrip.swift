import AVFoundation
import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The editor's clip trim, shared by the iPhone clip sheet and the Mac bar under the preview.
// Real frames of the source file, in/out handles, a white playhead and a live scrub of `ClipTrimPreview`.
// In and out are source seconds. A drag is one undo step: `trim` coalesces, `endGesture` closes it.

/// The source picture: the file's player, a play button and the source timecode.
struct ClipTrimPicture: View {
    let session: EditSession
    let clip: EditClip
    let preview: ClipTrimPreview
    var showsTransport = true

    private var source: EditSource? { session.source(for: clip.item) }

    var body: some View {
        ZStack {
            EditorPoster(url: source?.posterURL, fallback: EditorColor.clip(for: clip.item), maxPixel: 640)
            if let player = preview.player {
                EditorPlayerView(player: player)
                    .opacity(preview.isReady ? 1 : 0)
                    .mediaMask()
            }
        }
        .overlay(alignment: .bottom) {
            if showsTransport {
                ClipTrimTransport(session: session, preview: preview, fallback: clip.in)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.trim)
    }
}

/// Play / pause and the source timecode, drawn on the picture.
struct ClipTrimTransport: View {
    let session: EditSession
    let preview: ClipTrimPreview
    var fallback: Double = 0

    var body: some View {
        let _ = preview.change
        HStack(spacing: 8) {
            Button {
                session.pause()
                preview.togglePlay()
            } label: {
                Label(
                    preview.isPlaying ? Copy.Editor.pause : Copy.Editor.play,
                    systemImage: preview.isPlaying ? Symbol.Editor.pause : Symbol.Editor.play)
            }
            .buttonStyle(.cobaltIcon(.small, prominent: true))
            .disabled(preview.player == nil)
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !preview.isPlaying && !preview.isScrubbing)) { _ in
                Text(Copy.Editor.clockTenths(shown))
                    .font(Font.cobalt(12, .regular, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .accessibilityLabel(Copy.Editor.transportTime)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 8)
    }

    private var shown: Double { preview.player == nil ? fallback : preview.playheadSeconds() }
}

/// The filmstrip for one main clip: frames across the visible window, handles, a playhead, and the controls
/// under it (frame step, loop, zoom). Dragging the strip scrubs. Dragging a handle trims and scrubs to that frame.
struct ClipTrimStrip: View {
    let session: EditSession
    let clip: EditClip
    let preview: ClipTrimPreview

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom = ClipTrimMath.minimumZoom
    @State private var anchor = 0.0
    @State private var pinchZoom: Double?
    @State private var stripWidth: CGFloat = 1
    @State private var hovering = false
    @State private var handleDrag: HandleDrag?
    @State private var scrubFrom: Double?
    @State private var hapticTick = 0
    @State private var frames = ClipTrimFrames()

    private var source: EditSource? { session.source(for: clip.item) }
    private var duration: Double { max(clip.out, source?.duration ?? clip.out, 0.001) }
    private var window: ClipTrimMath.Window { ClipTrimMath.window(duration: duration, zoom: zoom, anchor: anchor) }
    private var minSpan: Double { ClipTrimMath.minimumSourceSpan(speed: clip.speed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filmstrip
            Text(Copy.Editor.trimReadout(clip.in, clip.out))
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
                .accessibilityLabel(Copy.Editor.trim)
            controls
        }
        .onChange(of: clip.id) { _, _ in
            zoom = ClipTrimMath.minimumZoom
            anchor = (clip.in + clip.out) / 2
        }
        .onChange(of: zoom) { old, new in
            guard old != new else { return }
            anchor = preview.playheadSeconds()
        }
        .task(id: followKey) { await followPlayhead() }
        #if os(iOS)
        .haptic(.selection, trigger: hapticTick)
        #endif
    }

    // MARK: filmstrip

    private var filmstrip: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            strip(width: width)
                .onChange(of: width, initial: true) { _, new in stripWidth = new }
        }
        .frame(height: Metrics.strip)
        .simultaneousGesture(pinch)
        #if os(macOS)
        .onContinuousHover { phase in hovering = phase == .active }
        .modifier(ClipTrimScrollZoom(enabled: hovering) { delta in
            zoom = ClipTrimMath.clampedZoom(zoom * delta)
        })
        #endif
    }

    private func strip(width: CGFloat) -> some View {
        let left = ClipTrimMath.x(forSeconds: clip.in, width: Double(width), window: window)
        let right = ClipTrimMath.x(forSeconds: clip.out, width: Double(width), window: window)
        return ZStack(alignment: .topLeading) {
            framesView(width: width)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: width))
            dim(width: width, left: left, right: right)
            selection(width: max(2, right - left))
                .offset(x: left)
                .allowsHitTesting(false)
            playhead(width: width)
            handles(width: width, left: left, right: right)
        }
        .frame(width: width, height: Metrics.strip, alignment: .topLeading)
        .task(id: frameKey(width: width)) {
            guard let url = session.localVideoURL(for: clip.item) else { return }
            let count = Self.cellCount(width)
            await frames.load(url: url, start: window.start, end: window.end, count: count)
        }
    }

    private func framesView(width: CGFloat) -> some View {
        let count = Self.cellCount(width)
        let images = frames.images
        return HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { cell in
                let index: Int? = images.isEmpty ? nil : min(images.count - 1, cell * images.count / max(1, count))
                ZStack {
                    EditorColor.clip(for: clip.item)
                    if let index {
                        Image(decorative: images[index], scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .frame(width: width, height: Metrics.strip)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .mediaMask()
        .accessibilityHidden(true)
    }

    private func dim(width: CGFloat, left: CGFloat, right: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, left), height: Metrics.strip)
            Rectangle().fill(.black.opacity(0.62))
                .frame(width: max(0, width - right), height: Metrics.strip)
                .offset(x: right)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    private func selection(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(EditorColor.selection, lineWidth: 2)
            .frame(width: width, height: Metrics.strip)
    }

    private func playhead(width: CGFloat) -> some View {
        let _ = preview.change
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pausedPlayhead)) { _ in
            let seconds = preview.playheadSeconds()
            let x = ClipTrimMath.x(forSeconds: seconds, width: Double(width), window: window)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Rectangle().fill(.white).frame(width: 2, height: Metrics.strip - 8)
                }
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: x - 4, y: 0)
                if preview.isScrubbing {
                    Text(Copy.Editor.clockTenths(seconds))
                        .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.78), in: Capsule())
                        .fixedSize()
                        .offset(x: min(max(0, x - 28), max(0, width - 64)), y: -26)
                        .accessibilityHidden(true)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Editor.a11yPlayhead)
        .accessibilityValue(Copy.Editor.clockTenths(preview.playheadSeconds()))
        .accessibilityAdjustableAction { direction in
            preview.step(frames: direction == .increment ? 1 : -1)
        }
    }

    private var pausedPlayhead: Bool {
        reduceMotion && !preview.isScrubbing && !preview.isPlaying
    }

    // MARK: controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                frameButtons
                loopButton
                Spacer(minLength: 8)
                zoomChips.frame(maxWidth: 220)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    frameButtons
                    loopButton
                }
                zoomChips
            }
        }
    }

    private var frameButtons: some View {
        HStack(spacing: 4) {
            stepButton(Symbol.Editor.back, Copy.Editor.backOneFrame, frames: -1)
            stepButton(Symbol.Editor.forward, Copy.Editor.forwardOneFrame, frames: 1)
        }
    }

    private func stepButton(_ symbol: String, _ label: String, frames: Int) -> some View {
        Button {
            preview.step(frames: frames)
        } label: {
            Label(label, systemImage: symbol)
        }
        .buttonStyle(.cobaltIcon(.small))
        .disabled(preview.player == nil)
    }

    private var loopButton: some View {
        Button(Copy.Editor.loop) { preview.toggleLoop() }
            .buttonStyle(preview.loop
                ? .cobaltPrimary(fullWidth: false, compact: true)
                : .cobaltSecondary(fullWidth: false, compact: true))
            .accessibilityAddTraits(preview.loop ? .isSelected : [])
    }

    private var zoomChips: some View {
        EditorSegmented(
            options: ClipTrimMath.zoomStops.map { EditorSegmented<Double>.Option(value: $0, title: Copy.Editor.zoomChip($0)) },
            selected: ClipTrimMath.zoomStops.first { abs($0 - zoom) < 0.05 },
            onSelect: { zoom = $0 })
        .accessibilityLabel(Copy.Editor.zoom)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchZoom ?? zoom
                pinchZoom = base
                zoom = ClipTrimMath.clampedZoom(base * Double(value.magnification))
            }
            .onEnded { _ in pinchZoom = nil }
    }

    // MARK: gestures

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in scrubChanged(value.location.x, width: width) }
            .onEnded { _ in scrubEnded() }
    }

    private func scrubChanged(_ x: CGFloat, width: CGFloat) {
        // A handle drag owns the finger. Its gesture sits on top; this ignores a second one if both fire.
        guard handleDrag == nil else { return }
        let t = ClipTrimMath.seconds(atX: Double(x), width: Double(width), window: window)
        if scrubFrom == nil {
            preview.beginScrub()
            scrubFrom = t
        }
        preview.scrub(to: t)
        if let previous = scrubFrom { tick(from: previous, to: t, low: 0, high: duration) }
        scrubFrom = t
    }

    private func scrubEnded() {
        guard handleDrag == nil else { return }
        let t = preview.playheadSeconds()
        scrubFrom = nil
        preview.endScrub(at: t)
    }

    private func handles(width: CGFloat, left: CGFloat, right: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TimelineTrimHandle(
                edge: .leading, height: Metrics.strip, valueText: Copy.Editor.clockCentis(clip.in),
                onDrag: { drag(.leading, $0) }, onEnd: finishHandle, step: { stepEdge(.leading, $0) })
                .offset(x: left)
            TimelineTrimHandle(
                edge: .trailing, height: Metrics.strip, valueText: Copy.Editor.clockCentis(clip.out),
                onDrag: { drag(.trailing, $0) }, onEnd: finishHandle, step: { stepEdge(.trailing, $0) })
                .offset(x: right - TimelineTrimHandle.hitWidth)
        }
    }

    private func drag(_ edge: TimelineTrimHandle.Edge, _ dx: CGFloat) {
        let drag = handleDrag ?? HandleDrag(edge: edge, origin: edgeTime(edge), span: window.span, last: edgeTime(edge))
        if handleDrag == nil { handleDrag = drag }
        let requested = drag.origin + ClipTrimMath.seconds(moved: Double(dx), width: Double(max(1, stripWidth)), span: drag.span)
        if edge == .leading {
            session.trim(clip: clip.id, in: requested, out: nil)
        } else {
            session.trim(clip: clip.id, in: nil, out: requested)
        }
        let actual = edgeTime(edge)
        preview.beginScrub()
        preview.scrub(to: actual)
        tick(from: drag.last, to: actual, low: bound(edge).low, high: bound(edge).high)
        handleDrag?.last = actual
    }

    private func finishHandle() {
        let actual = handleDrag.map { edgeTime($0.edge) } ?? preview.playheadSeconds()
        handleDrag = nil
        preview.endScrub(at: actual)
        session.endGesture()
    }

    private func stepEdge(_ edge: TimelineTrimHandle.Edge, _ frames: Int) {
        let step = Double(frames) / Double(max(1, session.timing.fps))
        if edge == .leading {
            session.trim(clip: clip.id, in: clip.in + step, out: nil)
        } else {
            session.trim(clip: clip.id, in: nil, out: clip.out + step)
        }
        session.endGesture()
        preview.show(edgeTime(edge))
    }

    private func edgeTime(_ edge: TimelineTrimHandle.Edge) -> Double {
        guard let now = session.timeline.main.first(where: { $0.id == clip.id }) else {
            return edge == .leading ? clip.in : clip.out
        }
        return edge == .leading ? now.in : now.out
    }

    /// The seconds the handle cannot pass: the file's ends, and the other handle kept `minSpan` away.
    private func bound(_ edge: TimelineTrimHandle.Edge) -> (low: Double, high: Double) {
        if edge == .leading { return (0, max(0, clip.out - minSpan)) }
        return (min(duration, clip.in + minSpan), duration)
    }

    private func tick(from previous: Double, to next: Double, low: Double, high: Double) {
        #if os(iOS)
        let crossed = ClipTrimMath.crossedWholeSecond(from: previous, to: next)
        let hit = ClipTrimMath.arrivedAtBound(from: previous, to: next, low: low, high: high)
        if crossed || hit { hapticTick += 1 }
        #endif
    }

    // MARK: frames and follow

    private static func cellCount(_ width: CGFloat) -> Int {
        min(24, max(8, Int((width / 48).rounded(.down))))
    }

    private func frameKey(width: CGFloat) -> String {
        let start = (window.start * 20).rounded() / 20
        let end = (window.end * 20).rounded() / 20
        let url = session.localVideoURL(for: clip.item)?.path ?? ""
        return "\(url)|\(start)|\(end)|\(Self.cellCount(width))"
    }

    private var followKey: String { "\(preview.isPlaying)-\(zoom)-\(Int(duration * 10))" }

    /// While the selection plays zoomed in, the window stays with the playhead.
    private func followPlayhead() async {
        guard preview.isPlaying, zoom > 1.01 else { return }
        var center = anchor
        while !Task.isCancelled, preview.isPlaying {
            let t = preview.playheadSeconds()
            let shown = ClipTrimMath.window(duration: duration, zoom: zoom, anchor: center)
            if t < shown.start + shown.span * 0.12 || t > shown.end - shown.span * 0.12 {
                center = t
                anchor = t
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// A handle drag. `span` is the window when the finger went down, so the handle tracks it 1:1.
private struct HandleDrag {
    var edge: TimelineTrimHandle.Edge
    var origin: Double
    var span: Double
    var last: Double
}

// MARK: - frames

/// Thumbnails across a source window, one `AVAssetImageGenerator` pass. Replaced when the window or the file changes.
@MainActor @Observable
final class ClipTrimFrames {
    private(set) var images: [CGImage] = []
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var urlPath: String?

    func load(url: URL, start: Double, end: Double, count: Int) async {
        let next = "\(url.path)|\(start)|\(end)|\(count)"
        if next == key, !images.isEmpty { return }
        if urlPath != url.path {
            images = []
            urlPath = url.path
        }
        key = next
        let made = await Self.images(url: url, start: start, end: max(start + 0.01, end), count: max(1, count))
        guard !Task.isCancelled, key == next, !made.isEmpty else { return }
        images = made.map(\.image)
    }

    /// Off the main actor. The generator is not `Sendable`; it stays inside a box that never crosses a boundary of its own.
    private nonisolated static func images(url: URL, start: Double, end: Double, count: Int) async -> [ClipTrimFrameBox] {
        let box = ClipTrimGeneratorBox(url: url)
        let span = max(0.01, end - start)
        var out: [ClipTrimFrameBox] = []
        for i in 0..<count {
            if Task.isCancelled { return [] }
            let seconds = start + (Double(i) + 0.5) / Double(count) * span
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            if let image = await box.image(at: time) {
                out.append(ClipTrimFrameBox(image: image))
            }
        }
        return out
    }
}

/// One generator for a filmstrip pass. `@unchecked Sendable` so the awaits in `images` can keep using it.
private struct ClipTrimGeneratorBox: @unchecked Sendable {
    /// Not `Sendable`. The box is the only thing that touches it, and one filmstrip pass uses it at a time.
    nonisolated(unsafe) let generator: AVAssetImageGenerator

    init(url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.generator = generator
    }

    func image(at time: CMTime) async -> CGImage? {
        try? await generator.image(at: time).image
    }
}

/// A generated frame crossing the main-actor boundary. `CGImage` is not always `Sendable`.
private struct ClipTrimFrameBox: @unchecked Sendable {
    let image: CGImage
}

#if os(macOS)
/// ⌘-scroll over the strip zooms it (1×...8×). The wheel still scrolls when ⌘ is up.
private struct ClipTrimScrollZoom: ViewModifier {
    let enabled: Bool
    let zoom: (Double) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    nonisolated(unsafe) let seen = event
                    let consumed = MainActor.assumeIsolated { handle(seen) }
                    return consumed ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard enabled, event.modifierFlags.contains(.command) else { return false }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return false }
        zoom(exp(delta * 0.012))
        return true
    }
}
#endif

/// The Mac and iPad bar under the composition preview: the source picture and the strip for the selected clip.
struct ClipTrimBar: View {
    let session: EditSession
    let clip: EditClip
    let preview: ClipTrimPreview

    private var aspect: CGFloat {
        guard let display = session.source(for: clip.item)?.display, display.h > 0 else { return 16.0 / 9.0 }
        return CGFloat(display.w) / CGFloat(display.h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipTrimPicture(session: session, clip: clip, preview: preview)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 112)
            ClipTrimStrip(session: session, clip: clip, preview: preview)
        }
        .modifier(ClipTrimSync(session: session, clip: clip, preview: preview))
        .accessibilityElement(children: .contain)
    }
}
