import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Where the map is looking: zoom and pan, shared by the canvas and the screen's `reset view` button. A glide eases
/// back to the whole sky (a jump under Reduce Motion).
@MainActor @Observable
final class SkyCamera {
    var viewport = SkyViewport()
    @ObservationIgnored private var glide: Task<Void, Never>?

    func set(_ v: SkyViewport) {
        glide?.cancel()
        viewport = v
    }

    func home(animated: Bool) {
        glide?.cancel()
        let from = viewport
        guard animated, !from.isHome else {
            viewport = SkyViewport()
            return
        }
        glide = Task { [weak self] in
            let steps = 18
            for s in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let t = Double(s) / Double(steps), e = 1 - pow(1 - t, 3)
                self?.viewport = SkyViewport(
                    zoom: from.zoom + (1 - from.zoom) * e,
                    pan: CGSize(width: from.pan.width * (1 - e), height: from.pan.height * (1 - e)))
            }
            self?.viewport = SkyViewport()
        }
    }
}

/// The card on screen: for which star, where it was anchored, whether a press pinned it (it has `open`) or a pointer's
/// hover shows it (it only describes).
struct SkyCardTarget: Equatable {
    var index: Int
    var anchor: CGPoint
    var pinned: Bool
    var near: [String]
}

/// The sky itself: a `Canvas` over the model's latest layout, with pinch and drag to zoom and pan, a double tap to
/// come back, a tap on a star to open its post and a long press for a preview. The stars ease towards each snapshot
/// the model publishes while it lays out, so the sky visibly settles; Reduce Motion shows only the finished layout.
struct SkyMapView: View {
    let sky: SkyMapModel
    let camera: SkyCamera
    let insets: SkyInsets
    /// A star was chosen: its post key (`MapPost.id`, the library's post id).
    let onOpen: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var stage = SkyStage()
    @State private var size: CGSize = .zero
    @State private var nebulaImages: [CGImage] = []
    @State private var settling = false
    @State private var card: SkyCardTarget?
    @State private var cardSize = CGSize(width: SkyPostCard.width, height: 280)
    @State private var hover: Int?
    @State private var press: PressState?
    @State private var pinchBase: SkyViewport?
    @State private var lastTap: TapMark?
    @State private var pressTask: Task<Void, Never>?
    @State private var hoverTask: Task<Void, Never>?
    #if os(macOS)
    @State private var pointer: CGPoint?
    #endif

    private struct PressState {
        var basePan: CGSize
        var moved = false
        var cancelled = false
        var longFired = false
    }

    private struct TapMark {
        var time: Date
        var location: CGPoint
    }

    private struct NebulaKey: Equatable {
        var nebulae: [SkyNebula]
        var dark: Bool
    }

    /// How close a finger or pointer must be to a star to mean it.
    private var hitRadius: CGFloat {
        #if os(macOS)
        14
        #else
        22
        #endif
    }

    var body: some View {
        let theme = SkyTheme.of(scheme)
        let phase = sky.phase
        let ready = phase == .ready
        let points = sky.points
        let degrees = sky.degrees
        let membership = sky.constellationOf
        let constellations = sky.constellations
        let nebulae = sky.nebulae
        let viewport = camera.viewport
        let focus = card?.index ?? hover

        TimelineView(.animation(minimumInterval: settling ? 1.0 / 30 : 1.0 / 12, paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { ctx, canvasSize in
                let now = timeline.date.timeIntervalSinceReferenceDate
                stage.advance(target: points, now: now, animate: !reduceMotion)
                let reveal = reduceMotion ? (ready ? 1 : 0) : stage.reveal(ready: ready, now: now, animate: true)
                let shown = stage.shown
                var scene = SkyScene(theme: theme, size: canvasSize, frame: nil, viewport: viewport)
                scene.points = shown
                scene.degrees = degrees
                scene.membership = membership
                scene.constellations = constellations
                scene.nebulae = nebulae
                scene.nebulaImages = nebulaImages
                scene.reveal = reveal
                scene.time = now
                scene.twinkle = !reduceMotion
                scene.focus = focus
                scene.showsStars = reduceMotion ? ready : !shown.isEmpty
                if !shown.isEmpty {
                    scene.frame = SkyFrame(bounds: SkyBounds(points: shown), size: canvasSize, insets: insets, viewport: viewport)
                }
                SkyPainter.draw(scene, stage: stage, into: &ctx)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture.simultaneously(with: magnifyGesture))
        .onContinuousHover { phase in hoverChanged(phase) }
        .modifier(SkyPointer(hovering: hover != nil))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: NebulaKey(nebulae: nebulae, dark: theme.dark)) {
            nebulaImages = nebulae.compactMap { SkyBitmaps.nebula($0, dark: theme.dark) }
        }
        .onChange(of: phase, initial: true) { _, new in settle(new) }
        .onChange(of: viewport) { dismissCard() }
        .accessibilityElement()
        .accessibilityLabel(Copy.SkyMap.mapA11y(posts: sky.posts.count, constellations: sky.constellations.count))
        .accessibilityAddTraits(.isImage)
        .overlay(alignment: .topLeading) { cardOverlay(theme: theme) }
        #if os(macOS)
        .modifier(SkyScrollWheel { scrolled($0) })
        #endif
        .onDisappear {
            pressTask?.cancel()
            hoverTask?.cancel()
        }
    }

    // MARK: settling

    /// The timeline runs fast while the stars move and for a moment after, then slows to a gentle twinkle.
    private func settle(_ phase: SkyMapModel.Phase) {
        switch phase {
        case .laying:
            settling = true
        case .ready:
            settling = true
            Task {
                try? await Task.sleep(for: .milliseconds(1400))
                if sky.phase == .ready { settling = false }
            }
        default:
            settling = false
        }
    }

    // MARK: geometry

    private func frame() -> SkyFrame? {
        let shown = stage.shown
        guard !shown.isEmpty, size.width > 0 else { return nil }
        return SkyFrame(bounds: SkyBounds(points: shown), size: size, insets: insets, viewport: camera.viewport)
    }

    private var centre: CGPoint {
        CGPoint(x: insets.side + max(40, size.width - 2 * insets.side) / 2, y: insets.top + max(40, size.height - insets.top - insets.bottom) / 2)
    }

    /// The star nearest `p` within the hit radius (only once the sky has settled).
    private func nearest(_ p: CGPoint) -> Int? {
        guard sky.phase == .ready, let f = frame() else { return nil }
        var best: Int?
        var bestDistance = hitRadius * hitRadius
        for (i, w) in stage.shown.enumerated() {
            let s = f.point(w)
            let d = (s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    // MARK: gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if press == nil {
                    press = PressState(basePan: camera.viewport.pan)
                    schedulePress(at: v.startLocation)
                }
                guard var state = press, !state.cancelled else { return }
                if !state.moved {
                    guard hypot(v.translation.width, v.translation.height) > 6 else { return }
                    state.moved = true
                    press = state
                    pressTask?.cancel()
                    dismissCard()
                }
                var next = camera.viewport
                next.pan = CGSize(width: state.basePan.width + v.translation.width, height: state.basePan.height + v.translation.height)
                camera.set(next.clamped(in: size))
            }
            .onEnded { v in
                let state = press
                press = nil
                pressTask?.cancel()
                guard let state, !state.cancelled, !state.moved, !state.longFired else { return }
                tapped(at: v.location)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil {
                    pinchBase = camera.viewport
                    press?.cancelled = true
                    pressTask?.cancel()
                    dismissCard()
                }
                guard let base = pinchBase else { return }
                let anchor = CGPoint(x: v.startAnchor.x * size.width, y: v.startAnchor.y * size.height)
                camera.set(base.zoomed(by: v.magnification, anchor: anchor, centre: centre).clamped(in: size))
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// A tap: on a star it opens the post (a pinned card just closes); two quick taps come back to the whole sky.
    private func tapped(at p: CGPoint) {
        let now = Date()
        if let last = lastTap, now.timeIntervalSince(last.time) < 0.32, hypot(p.x - last.location.x, p.y - last.location.y) < 36 {
            lastTap = nil
            dismissCard()
            camera.home(animated: !reduceMotion)
            return
        }
        lastTap = TapMark(time: now, location: p)
        if card?.pinned == true {
            dismissCard()
            return
        }
        guard let i = nearest(p), sky.posts.indices.contains(i) else { return }
        dismissCard()
        onOpen(sky.posts[i].id)
    }

    /// A finger held on a star for 0.42 s pins its preview card.
    private func schedulePress(at p: CGPoint) {
        pressTask?.cancel()
        pressTask = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, var state = press, !state.moved, !state.cancelled, let i = nearest(p) else { return }
            state.longFired = true
            press = state
            show(i, pinned: true)
        }
    }

    // MARK: hover (iPad pointer, Mac)

    private func hoverChanged(_ phase: HoverPhase) {
        switch phase {
        case .active(let p):
            #if os(macOS)
            pointer = p
            #endif
            guard press == nil else { return }
            let i = nearest(p)
            guard i != hover else { return }
            hover = i
            hoverTask?.cancel()
            if card?.pinned != true { card = nil }
            guard let i, card == nil else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled, hover == i, card == nil else { return }
                show(i, pinned: false)
            }
        case .ended:
            #if os(macOS)
            pointer = nil
            #endif
            hover = nil
            hoverTask?.cancel()
            if card?.pinned == false { card = nil }
        }
    }

    #if os(macOS)
    /// The trackpad's two-finger scroll pans; a mouse wheel or ⌘ with the scroll zooms about the pointer.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard let pointer, size.width > 0 else { return false }
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || !precise {
            let factor = exp(Double(event.scrollingDeltaY) * (precise ? 0.01 : 0.04))
            camera.set(camera.viewport.zoomed(by: factor, anchor: pointer, centre: centre).clamped(in: size))
        } else {
            var next = camera.viewport
            next.pan.width += event.scrollingDeltaX
            next.pan.height += event.scrollingDeltaY
            camera.set(next.clamped(in: size))
        }
        return true
    }
    #endif

    // MARK: the card

    private func show(_ index: Int, pinned: Bool) {
        guard sky.posts.indices.contains(index), let f = frame() else { return }
        let anchor = f.point(stage.shown[index])
        card = SkyCardTarget(index: index, anchor: anchor, pinned: pinned, near: sky.neighbourhoodKeywords(of: index, max: 4))
    }

    private func dismissCard() {
        if card != nil { card = nil }
    }

    /// The card goes beside the star (right, else left), or above or below it on a narrow screen.
    private func origin(of target: SkyCardTarget) -> CGPoint {
        let w = SkyPostCard.width, h = cardSize.height, gap: CGFloat = 16, edge: CGFloat = 8
        let a = target.anchor
        let top = max(edge, insets.top - 40), bottom = size.height - h - edge
        if a.x + gap + w <= size.width - edge { return CGPoint(x: a.x + gap, y: min(max(a.y - h / 2, top), max(top, bottom))) }
        if a.x - gap - w >= edge { return CGPoint(x: a.x - gap - w, y: min(max(a.y - h / 2, top), max(top, bottom))) }
        let x = min(max(a.x - w / 2, edge), size.width - w - edge)
        let below = a.y + gap + h <= size.height - edge
        return CGPoint(x: x, y: below ? a.y + gap : max(top, a.y - gap - h))
    }

    @ViewBuilder
    private func cardOverlay(theme: SkyTheme) -> some View {
        ZStack(alignment: .topLeading) {
            if let target = card, sky.posts.indices.contains(target.index) {
                let post = sky.posts[target.index]
                let place = origin(of: target)
                SkyPostCard(post: post, near: target.near, theme: theme, showsOpen: target.pinned) {
                    dismissCard()
                    onOpen(post.id)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .offset(x: place.x, y: place.y)
                .onTapGesture {}
                .transition(.scale(scale: 0.94, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // only a pinned card takes touches; the rest of the sky belongs to the map's own gestures
        .allowsHitTesting(card?.pinned == true)
        .motion(Motion.card, value: card)
    }
}

#if os(macOS)
/// Hands the scroll wheel to the map while the pointer is over it (SwiftUI has no scroll-wheel event of its own).
private struct SkyScrollWheel: ViewModifier {
    let handle: @MainActor (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    // local monitors run on the main thread
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
}
#endif

/// The pointing-hand cursor over a star (a pointer exists on the Mac; `pointerStyle` is macOS only).
private struct SkyPointer: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.pointerStyle(hovering ? .link : nil)
        #else
        content
        #endif
    }
}
