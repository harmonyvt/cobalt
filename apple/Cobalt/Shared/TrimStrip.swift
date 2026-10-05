import CobaltKit
import SwiftUI

// The filmstrip: frames that develop one by one, and the trim bracket over them. The strip spans
// the full width it is given (the card on a phone, the content column under the preview on iPad and
// Mac), with about one cell per 44 pt.

/// One cell of the strip. Blank until its frame arrives, then it develops: opacity 0 to 1, blur 8
/// to 0 and scale 1.12 to 1. Under Reduce Motion it only fades.
private struct FrameCell: View {
    let frame: Frame?
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .overlay {
                if let frame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .brightness(lit ? 0.2 : 0)
                        .transition(
                            .opacity.animation(reduceMotion ? Motion.fade : Motion.developFade)
                                .combined(with: .modifier(
                                    active: DevelopModifier(developed: false, reduced: reduceMotion),
                                    identity: DevelopModifier(developed: true, reduced: reduceMotion))))
                }
            }
            .overlay(alignment: .bottom) {
                if lit && frame != nil {
                    Rectangle().fill(CobaltColor.badgeInk).frame(height: 4).transition(.opacity)
                }
            }
            .clipped()
            .animation(reduceMotion ? Motion.fade : Motion.develop, value: frame != nil)
            .animation(Motion.lights, value: lit)
    }
}

struct Filmstrip: View {
    /// What CobaltKit has read so far: `Pipeline.frameCount` slots, `nil` until each arrives.
    let frames: [Frame?]
    var lit: Set<Int> = []
    /// The width the strip is laid out at; it decides how many cells there are.
    var width: CGFloat

    /// max(9, floor(width / 44)): never fewer cells than frames.
    static func cellCount(for width: CGFloat) -> Int {
        max(Pipeline.frameCount, Int((width / Metrics.stripCell).rounded(.down)))
    }

    /// Which of the real frames a cell shows when there are more cells than frames: each frame is
    /// repeated across its share of the strip, so the strip is always full.
    static func source(cell: Int, of cells: Int, frames: Int) -> Int {
        guard frames > 0, cells > 0 else { return 0 }
        return min(frames - 1, Int((Double(cell) + 0.5) / Double(cells) * Double(frames)))
    }

    var body: some View {
        let cells = Self.cellCount(for: width)
        HStack(spacing: 2) {
            ForEach(0..<cells, id: \.self) { i in
                let src = Self.source(cell: i, of: cells, frames: frames.count)
                FrameCell(frame: frames.indices.contains(src) ? frames[src] : nil, lit: lit.contains(src))
            }
        }
        .background(CobaltColor.frameBase)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.framesA11y)
        .accessibilityValue("\(frames.compactMap { $0 }.count) / \(frames.count)")
    }
}

/// The bracket's border and handles. `over` turns everything red (dragging past the limit).
private struct BracketBody: View {
    let over: Bool
    let breathing: Bool

    var body: some View {
        let tint = over ? CobaltColor.error : CobaltColor.text
        RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
            .strokeBorder(tint, lineWidth: 3)
            .modifier(BreatheGlow(active: breathing, tint: tint))
            .motion(.easeOut(duration: 0.15), value: over, reduced: .jump)
    }
}

private struct BreatheGlow: ViewModifier {
    let active: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            PhaseAnimator([0.0, 6.0]) { spread in
                content.background(
                    RoundedRectangle(cornerRadius: Metrics.radius + spread, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .padding(-spread))
            } animation: { _ in
                .easeInOut(duration: 1.4)
            }
        } else {
            content
        }
    }
}

private struct BracketIn: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).scaleEffect(x: 1, y: on ? 1 : 1.4)
    }
}

private extension View {
    @ViewBuilder
    func spanMatch(_ namespace: Namespace.ID?) -> some View {
        if let namespace { matchedGeometryEffect(id: "span", in: namespace) } else { self }
    }
}

/// Frames + dim + bracket + playhead. `interactive` turns on the drag gestures (home); the share
/// sheet shows the bracket read-only.
struct TrimStrip: View {
    let pipeline: Pipeline
    var interactive = true
    var height: CGFloat = Metrics.strip
    /// The bracket's `matchedGeometryEffect(id: "span")` partner is the result tile.
    var spanNamespace: Namespace.ID?
    /// The preview that plays the selection: the playhead reads its clock, and a drag scrubs it.
    var preview: TrimPreview?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hapticsEnabled) private var haptics
    @State private var origin: TrimRange?
    @State private var snap = false

    private var showsBracket: Bool {
        switch pipeline.state {
        case .ready, .rendering, .done: return true
        case .failed(let f): return f.keepsTrim && pipeline.media != nil
        default: return false
        }
    }

    private var isPacking: Bool {
        switch pipeline.state {
        case .rendering(.packing), .rendering(.working): return true
        default: return false
        }
    }

    private var canDrag: Bool {
        if case .ready = pipeline.state { return interactive }
        return false
    }

    private var isReady: Bool {
        if case .ready = pipeline.state { return true }
        return false
    }

    private var duration: Double { max(0.1, pipeline.media?.duration ?? pipeline.maxClipSeconds) }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            // The bracket is an overlay: its 84 pt handles must not make the strip taller than `height`.
            Filmstrip(frames: pipeline.frames, lit: pipeline.litFrames, width: w)
                .frame(width: w, height: height)
                .overlay(alignment: .topLeading) {
                    if showsBracket {
                        bracket(width: w)
                            .transition(.modifier(active: BracketIn(on: false), identity: BracketIn(on: true)))
                    }
                }
            .coordinateSpace(.named("strip"))
            .motion(Motion.bracketIn, value: showsBracket)
            #if DEBUG
            .task(id: showsBracket) { await debugScriptedDrag(width: w) }
            #endif
        }
        .frame(height: height)
        .haptic(.impact(weight: .light), trigger: pipeline.limitHits, enabled: haptics)
    }

    private func bracket(width w: CGFloat) -> some View {
        let d = duration
        let x0 = max(0, CGFloat(pipeline.trim.start / d)) * w
        let x1 = min(1.2, CGFloat(pipeline.trim.end / d)) * w
        let bracketWidth = max(x1 - x0, 6)
        let over = pipeline.trimOverLimit
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(CobaltColor.scrim)
                .frame(width: max(0, x0), height: height)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10))
                .allowsHitTesting(false)
            Rectangle().fill(CobaltColor.scrim)
                .frame(width: max(0, w - x1), height: height)
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10))
                .offset(x: x1)
                .allowsHitTesting(false)
            BracketBody(over: over, breathing: isPacking)
                .frame(width: bracketWidth, height: height + 8)
                .offset(x: x0, y: -4)
                .spanMatch(spanNamespace)
                .contentShape(Rectangle())
                .gesture(drag(.span, width: w), isEnabled: canDrag)
                .accessibilityHidden(true)
            if isReady { playhead(from: x0, to: x1, width: w) }
            if canDrag || interactive {
                handle(.start, x: x0 - 3, width: w, over: over)
                handle(.end, x: x1 + 3, width: w, over: over)
            } else {
                handleBar(over: over).offset(x: x0 - 3 - 6, y: (height - 40) / 2)
                handleBar(over: over).offset(x: x1 + 3 - 6, y: (height - 40) / 2)
            }
        }
        .animation(snap && !reduceMotion ? Motion.snap : nil, value: pipeline.trim)
        .motion(Motion.lights, value: isReady)
    }

    /// The playhead is the preview's own clock, held inside the selection: it sweeps the loop the picture
    /// plays, and while a handle is dragged it is pinned to that handle's frame. (It used to be a phase of
    /// the wall clock modulo the selection's length, which jumped to an unrelated place every time a drag
    /// changed that length.) With no preview it rests on the in point.
    private func playhead(from x0: CGFloat, to x1: CGFloat, width w: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion && !(preview?.isScrubbing ?? false))) { _ in
            let range = pipeline.trim
            let seconds = preview?.playhead(in: range) ?? range.start
            let x = min(max(CGFloat(seconds / duration) * w, x0), x1)
            VStack(spacing: 0) {
                Circle().fill(.white).frame(width: 9, height: 9)
                Rectangle().fill(.white).frame(width: 2, height: height - 9)
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: x - 4.5, y: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handleBar(over: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(over ? CobaltColor.error : CobaltColor.text)
            .frame(width: 12, height: 40)
    }

    /// A 44 pt wide, 84 pt tall hit area around a 12 x 40 bar.
    private func handle(_ which: TrimHandle, x: CGFloat, width w: CGFloat, over: Bool) -> some View {
        let isStart = which == .start
        let label = isStart ? Copy.inPoint : Copy.outPoint
        let seconds = isStart ? pipeline.trim.start : pipeline.trim.end
        return handleBar(over: over)
            .frame(width: Metrics.hit, height: 84)
            .contentShape(Rectangle())
            .offset(x: x - Metrics.hit / 2, y: (height - 84) / 2)
            .gesture(drag(which, width: w), isEnabled: canDrag)
            .focusable(canDrag)
            .onKeyPress(.leftArrow) { nudge(which, -0.1) }
            .onKeyPress(.rightArrow) { nudge(which, 0.1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(Copy.trimAdjustHint)
            .accessibilityValue(Format.timecode(seconds))
            .accessibilityAdjustableAction { direction in
                guard canDrag else { return }
                switch direction {
                case .increment: _ = nudge(which, 0.1)
                case .decrement: _ = nudge(which, -0.1)
                @unknown default: break
                }
            }
    }

    private func nudge(_ which: TrimHandle, _ by: Double) -> KeyPress.Result {
        guard canDrag else { return .ignored }
        snap = true
        pipeline.nudgeTrim(which, by: by)
        preview?.select(pipeline.trim)
        return .handled
    }

    private func drag(_ which: TrimHandle, width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
            .onChanged { value in dragChanged(which, translation: value.translation.width, width: w) }
            .onEnded { _ in dragEnded() }
    }

    /// One drag delta. The handle follows the finger 1:1 inside the bounds (the time is the trim at the start
    /// of the drag plus the translation), and the picture shows the frame of the handle in the owner's hand
    /// (the in point for the span).
    private func dragChanged(_ which: TrimHandle, translation: CGFloat, width w: CGFloat) {
        if origin == nil {
            origin = pipeline.trim
            snap = false
            preview?.beginScrub()
        }
        guard let start = origin, w > 0 else { return }
        let dt = Double(translation / w) * duration
        let base = which == .end ? start.end : start.start
        pipeline.dragTrim(which, to: base + dt)
        let range = pipeline.trim
        preview?.scrub(to: which == .end ? range.end : range.start)
    }

    private func dragEnded() {
        snap = true
        pipeline.endTrimDrag()
        origin = nil
        preview?.endScrub(selection: pipeline.trim)
    }

    #if DEBUG
    /// `-previewTrimDrag YES` (simulator evidence only): drags the out handle from the clip's 10 s to 4 s over
    /// 3 s, holds, then the in handle from 0 to 3 s over 3 s, through the same two functions the gesture
    /// calls (a real finger cannot be slowed down through the automation tools).
    private func debugScriptedDrag(width w: CGFloat) async {
        guard UserDefaults.standard.bool(forKey: "previewTrimDrag"), canDrag, w > 0 else { return }
        try? await Task.sleep(for: .seconds(9))
        func run(_ which: TrimHandle, from: Double, to: Double, seconds: Double) async {
            let steps = Int(seconds * 60)
            for i in 0...steps {
                if Task.isCancelled { return }
                let t = from + (to - from) * Double(i) / Double(steps)
                dragChanged(which, translation: CGFloat((t - from) / duration) * w, width: w)
                try? await Task.sleep(for: .milliseconds(16))
            }
            dragEnded()
        }
        await run(.end, from: 0, to: -6, seconds: 3)
        try? await Task.sleep(for: .seconds(2))
        await run(.start, from: 0, to: 3, seconds: 3)
    }
    #endif
}

/// "0 s  7.4 s  14.8 s" under the strip; "0 s … …" while frames are still arriving.
struct StripScale: View {
    let duration: Double
    let developing: Bool

    var body: some View {
        HStack {
            Text(Copy.scaleStart)
            Spacer()
            Text(developing ? Copy.scaleUnknown : Format.seconds(duration / 2))
            Spacer()
            Text(developing ? Copy.scaleUnknown : Format.seconds(duration))
        }
        .font(CobaltType.tab)
        .foregroundStyle(CobaltColor.caption)
        .accessibilityHidden(true)
    }
}
