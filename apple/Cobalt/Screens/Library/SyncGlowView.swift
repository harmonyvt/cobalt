import CobaltKit
import Combine
import Metal
import MetalKit
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The light along the bottom edge of a screen's content. It sits beneath the bars, so the tab bar's
/// glass picks it up instead of it covering the bar. Hit testing is off and it is hidden from
/// accessibility. The keyboard and the Finder extension do not use this view.
struct SyncGlowBand: View {
    var status: SyncGlowStatus?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var previous: SyncGlowState = .upToDate
    @State private var transitionStart = CACurrentMediaTime() - SyncGlowTiming.transition
    @State private var eventStart = CACurrentMediaTime()

    var body: some View {
        let state = status?.state ?? .off
        // The band lies over the last rows and under the tab bar's glass. Its cover is capped, but
        // someone who asked for less transparency or more contrast gets none of it: with Reduce
        // Transparency or Increase Contrast on it is not drawn at all. The modifiers below hang off the
        // band's one child, so while it is not drawn (this, or the glow being off) none of them run,
        // the tick included.
        let plain = reduceTransparency || contrast == .increased
        Group {
            if let status, state != .off, !plain {
                representable(status: status, state: state)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .allowedDynamicRange(.high)
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: state, initial: true) { old, new in
            if old == new {
                previous = new
                return
            }
            previous = old
            transitionStart = CACurrentMediaTime()
            // One-shot moments start their clock here. Leaving one lets its age keep growing so the
            // outgoing glow stays on its settled frame instead of snapping back to the start.
            if SyncGlowPace.isOneShot(new) {
                eventStart = CACurrentMediaTime()
            }
        }
        // The system posts this on whatever queue it likes. State is written on the main thread only.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: taskKey(state)) {
            // One tick whenever the state, the screen or the scene changes. Only a one-shot moment ends
            // by the clock, so only then does the loop keep going. It keeps going behind another window
            // too: a refusal that ended while nobody looked must not still be the state on return.
            let ticking = SyncGlowPace.needsTick(state: state)
            while !Task.isCancelled {
                status?.tick()
                guard ticking else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func taskKey(_ state: SyncGlowState) -> String {
        "\(state.rawValue)-\(onScreen)-\(scenePhase == .active)"
    }

    @ViewBuilder
    private func representable(status: SyncGlowStatus, state: SyncGlowState) -> some View {
        let draw = drawState(status: status, state: state)
        #if os(iOS)
        SyncGlowMetalIOS(draw: draw)
        #else
        SyncGlowMetalMac(draw: draw)
        #endif
    }

    private func drawState(status: SyncGlowStatus, state: SyncGlowState) -> SyncGlowDraw {
        var pinned: Float? = status.pinsEventAge ? Float(status.eventAge(at: Date())) : nil
        var pinTime: Float?
        #if DEBUG
        // `-previewSyncGlowAge` freezes the whole picture at that moment, for stills.
        if status.pinsEventAge, let age = SyncGlowDebugLaunch.frozenAge {
            pinned = Float(age)
            pinTime = Float(age)
        }
        #endif
        let draw = SyncGlowDraw(
            state: state,
            previous: previous,
            transitionStart: transitionStart,
            eventStart: eventStart,
            pinEventAge: pinned,
            pinTime: pinTime,
            pending: status.pendingCount,
            activity: status.activity,
            reduceMotion: reduceMotion,
            lowPower: lowPower,
            intensity: SyncGlowComposer.defaultIntensity,
            dark: colorScheme == .dark,
            visible: onScreen,
            sceneActive: scenePhase == .active)
        return draw
    }
}

struct SyncGlowDraw: Equatable {
    var state: SyncGlowState
    var previous: SyncGlowState
    var transitionStart: TimeInterval
    var eventStart: TimeInterval
    var pinEventAge: Float?
    var pinTime: Float?
    var pending: Int
    /// The owner's own saves and uploads (`SyncGlowActivity`), nil when there are none.
    var activity: Double?
    var reduceMotion: Bool
    var lowPower: Bool
    var intensity: Float
    var dark: Bool
    var visible: Bool
    var sceneActive: Bool
}

#if os(iOS)
private struct SyncGlowMetalIOS: UIViewRepresentable {
    var draw: SyncGlowDraw

    func makeUIView(context: Context) -> SyncGlowMTKView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: SyncGlowMTKView, context: Context) {
        context.coordinator.update(view, draw: draw)
    }

    func makeCoordinator() -> SyncGlowRenderer { SyncGlowRenderer() }
}
#else
private struct SyncGlowMetalMac: NSViewRepresentable {
    var draw: SyncGlowDraw

    func makeNSView(context: Context) -> SyncGlowMTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: SyncGlowMTKView, context: Context) {
        context.coordinator.update(view, draw: draw)
    }

    func makeCoordinator() -> SyncGlowRenderer { SyncGlowRenderer() }
}
#endif

/// Clears hit testing. The band is decoration under the bars, over the last rows of content.
final class SyncGlowMTKView: MTKView {
    /// Told when the platform says whether anybody can see the band: on iOS the view leaves its window
    /// while a full-screen cover is up, on the Mac the window reports being minimised or fully covered.
    /// An ordinary sheet over the band is not reported by either.
    var onShowingChange: ((SyncGlowMTKView, Bool) -> Void)?

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Selector observers are dropped with the view, so nothing is left to remove at the end.
        let centre = NotificationCenter.default
        centre.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            centre.addObserver(
                self, selector: #selector(occlusionChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            SyncGlowInteraction.shared.attach(to: window)
        }
        reportShowing()
    }

    @objc private func occlusionChanged(_ note: Notification) {
        reportShowing()
    }

    private func reportShowing() {
        onShowingChange?(self, window?.occlusionState.contains(.visible) ?? false)
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { SyncGlowInteraction.shared.attach(to: window) }
        onShowingChange?(self, window != nil)
    }
    #endif

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        #if os(iOS)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        #endif
    }

    #if os(macOS)
    /// `NSView.isOpaque` has no setter. A clear Metal layer still needs the view to report transparent.
    override var isOpaque: Bool { false }
    #endif

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("SyncGlowMTKView is created in code")
    }
}

/// What every band draws with: the device, its queue and the one pipeline. Built once, on the first
/// band. The tabs' bands, the queue sheet's and the editor cover's take turns, and building this again
/// on each turn was a main-thread hitch in the middle of a presentation.
@MainActor
final class SyncGlowResources {
    static let shared = SyncGlowResources()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    private(set) var pipeline: MTLRenderPipelineState?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        guard let device, let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "glowVertex"),
              let fragment = library.makeFunction(name: "glowFragment") else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// Draws the glow into an extended-range drawable. Frame rate comes from `SyncGlowPace`: the syncing
/// light, a crossfade or a one-shot moment runs, a settled calm or offline band is one still frame,
/// and a hidden, covered or background library does not draw.
@MainActor
final class SyncGlowRenderer: NSObject, MTKViewDelegate {
    private let resources: SyncGlowResources
    private var drawState = SyncGlowDraw(
        state: .upToDate, previous: .upToDate, transitionStart: 0, eventStart: 0, pinEventAge: nil,
        pinTime: nil, pending: 0, activity: nil, reduceMotion: false, lowPower: false, intensity: SyncGlowComposer.defaultIntensity,
        dark: true, visible: true, sceneActive: true)
    /// The last settled frame that reached the screen. A frame from the middle of a crossfade is not one.
    private var lastStill: SyncGlowDraw?
    private var drawing = false
    /// A redraw for a new drawable size is already waiting for the next main-actor turn.
    private var resizeRedraw = false
    /// False while the view has no window (iOS) or its window is minimised or fully covered (Mac).
    private var showing = true
    private let started = CACurrentMediaTime()
    /// The band this renderer draws, for a wake from `SyncGlowInteraction` between SwiftUI updates.
    private weak var view: SyncGlowMTKView?

    override init() {
        resources = SyncGlowResources.shared
        super.init()
    }

    func makeView() -> SyncGlowMTKView {
        let view = SyncGlowMTKView(frame: .zero, device: resources.device)
        view.delegate = self
        self.view = view
        SyncGlowInteraction.shared.register(self)
        view.onShowingChange = { [weak self] view, showing in
            self?.showingChanged(showing, in: view)
        }
        view.colorPixelFormat = .rgba16Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = SyncGlowPace.slow
        if let layer = view.layer as? CAMetalLayer {
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
        }
        return view
    }

    func update(_ view: SyncGlowMTKView, draw: SyncGlowDraw) {
        // A new state reaches this view one update before the band's `onChange` hands over the start
        // of its crossfade. A still drawn in between would flash the finished picture for a frame, so
        // that update leaves the still to the one that follows. Reduce Motion has no crossfade.
        let handover = draw.state != drawState.state && draw.transitionStart == drawState.transitionStart
            && !draw.reduceMotion
        drawState = draw
        schedule(view, still: !handover)
    }

    private func showingChanged(_ now: Bool, in view: SyncGlowMTKView) {
        guard now != showing else { return }
        showing = now
        // Coming back, the still is drawn again: the layer may not have kept the old one.
        if now { lastStill = nil }
        schedule(view)
    }

    /// A finger, the pointer or a scroll started moving while this band rested.
    func interactionWoke() {
        guard let view else { return }
        schedule(view)
    }

    /// Something on top of the state still moves: a save running, or the owner's hands.
    private func live(at now: TimeInterval) -> Bool {
        guard !drawState.reduceMotion else { return false }
        if drawState.activity != nil { return true }
        guard SyncGlowInteraction.shared.isLive(now: now), let view else { return false }
        return SyncGlowInteraction.shared.point(in: view.window) != nil || SyncGlowInteraction.shared.scroll(now: now) > 0
    }

    /// The finger or pointer as this band sees it: x in points from its left edge (-1 when it is not
    /// over the band's width), and how strongly it lights the line. A finger anywhere on the screen
    /// lights it, more the nearer it is to the bottom; a hovering pointer only near the bottom.
    private func touch(in view: MTKView, now: TimeInterval) -> (x: Float, level: Float) {
        let interaction = SyncGlowInteraction.shared
        let level = interaction.level(now: now)
        guard level > 0, let point = interaction.point(in: view.window) else { return (-1, 0) }
        let local = view.convert(point, from: nil)
        let bounds = view.bounds
        guard local.x >= 0, local.x <= bounds.width else { return (-1, 0) }
        #if os(iOS)
        let fromBottom = Double(bounds.maxY - local.y)
        #else
        let fromBottom = Double(view.isFlipped ? bounds.maxY - local.y : local.y)
        #endif
        let near: Double = interaction.isTouch
            ? max(0.45, 1 - max(fromBottom, 0) / 260)
            : max(0, 1 - max(fromBottom, 0) / 200)
        return (Float(local.x), level * Float(near))
    }

    private func crossfade(at now: TimeInterval) -> Float {
        SyncGlowComposer.transition(elapsed: now - drawState.transitionStart, reduceMotion: drawState.reduceMotion)
    }

    /// Runs the display link while something moves. Otherwise the view is paused and one still is drawn
    /// if the picture on screen is not already this one. A state change arrives through `update` with a
    /// fresh `transitionStart`, which is what wakes a resting band.
    private func schedule(_ view: MTKView, still: Bool = true) {
        let fps = SyncGlowPace.framesPerSecond(
            state: drawState.state, transitioning: !SyncGlowPace.isSettled(transition: crossfade(at: CACurrentMediaTime())),
            reduceMotion: drawState.reduceMotion, lowPower: drawState.lowPower,
            visible: drawState.visible && showing, sceneActive: drawState.sceneActive,
            live: live(at: CACurrentMediaTime()))
        if let fps {
            view.preferredFramesPerSecond = fps
            if view.isPaused { view.isPaused = false }
        } else {
            view.isPaused = true
            if still, lastStill != drawState { view.draw() }
        }
    }

    /// `MTKView` calls its delegate on the view's thread. The view is created on the main actor and never
    /// given another queue, so the draw below stays there.
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { self.mtkViewMain(view, drawableSizeWillChange: size) }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { self.drawMain(in: view) }
    }

    private func mtkViewMain(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A paused band shows a still, and a still drawn for the old size is stretched to the new one
        // until something else changes. Rotation and a window resize change nothing else, so the still
        // is drawn again. Not from in here: this is the "will change" call, and a draw inside it may
        // still get a drawable of the old size. The next main-actor turn has the new one either way.
        guard size.width > 0, size.height > 0, !resizeRedraw else { return }
        resizeRedraw = true
        Task { @MainActor [weak self, weak view] in
            guard let self else { return }
            self.resizeRedraw = false
            guard let view else { return }
            // Forgotten here, not above: a frame in flight when the size changed would mark itself kept.
            self.lastStill = nil
            self.schedule(view)
        }
    }

    private func drawMain(in view: MTKView) {
        guard !drawing else { return }
        drawing = true
        defer { drawing = false }
        guard drawState.visible, showing, drawState.sceneActive, drawState.state != .off else { return }
        guard let pipeline = resources.pipeline else { return }
        guard let drawable = view.currentDrawable, let command = resources.queue?.makeCommandBuffer() else { return }
        let width = drawable.texture.width
        let height = drawable.texture.height
        guard width > 0, height > 0 else { return }

        let now = CACurrentMediaTime()
        let fade = crossfade(at: now)
        let settled = SyncGlowPace.isSettled(transition: fade)
        if let fps = SyncGlowPace.framesPerSecond(
            state: drawState.state, transitioning: !settled, reduceMotion: drawState.reduceMotion,
            lowPower: drawState.lowPower, visible: true, sceneActive: true, live: live(at: now)
        ) {
            if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        } else if !view.isPaused {
            // The crossfade into calm has just finished. This frame is the still; no more are scheduled.
            view.isPaused = true
        }
        let hand = touch(in: view, now: now)
        let age = drawState.pinEventAge.map { TimeInterval($0) } ?? max(0, now - drawState.eventStart)
        let time = drawState.pinTime ?? Float(now - started)
        // Pixels per point, from the drawable against the view's own size, so the line and the light
        // keep their size in points at 1x, 2x and 3x.
        let boundsWidth = Double(view.bounds.width)
        let pointScale = boundsWidth > 0 ? Float(Double(width) / boundsWidth) : 1
        var uniforms = SyncGlowComposer.uniforms(
            time: time, state: drawState.state, previous: drawState.previous, transition: fade,
            pendingCount: drawState.pending, reduceMotion: drawState.reduceMotion, lowPower: drawState.lowPower,
            headroom: headroom(of: view), eventAge: age, width: Float(width), height: Float(height),
            intensity: drawState.intensity, pointScale: pointScale, dark: drawState.dark,
            activity: drawState.activity, touchX: hand.x, touchLevel: hand.level,
            scroll: SyncGlowInteraction.shared.scroll(now: now))
        var packed = uniforms.packed

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        packed.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        // A frame lit by a finger, a scroll or a running save is not the resting picture.
        lastStill = settled && hand.level == 0 && uniforms.scroll == 0 && drawState.activity == nil ? drawState : nil
    }

    private func headroom(of view: MTKView) -> Float {
        #if os(iOS)
        let value = view.window?.windowScene?.screen.currentEDRHeadroom ?? 1
        #else
        let value = view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        #endif
        return Float(max(value, 1))
    }
}

extension View {
    /// The glow along the bottom of this content: `SyncGlowLook.bandHeight` points above the bottom
    /// safe area, reaching down under the bars to the edge. Attach it to content that sits beneath the
    /// bars (a tab's root, the Mac detail column, a sheet's stack), never on top of a whole window, or
    /// it is drawn over the bars instead of under their glass. `suppressed` is true while another
    /// presentation in this window draws the band itself.
    func syncGlow(_ status: SyncGlowStatus?, suppressed: Bool = false) -> some View {
        overlay(alignment: .bottom) {
            if !suppressed, status != nil {
                GeometryReader { proxy in
                    let inset = proxy.safeAreaInsets.bottom
                    SyncGlowBand(status: status)
                        .frame(height: SyncGlowPlacement.bandHeight(bottomInset: Double(inset)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

#if DEBUG
@MainActor
enum SyncGlowDebugLaunch {
    /// `-previewSyncGlow upToDate|syncing|offline|refused|repull|nudge|off`
    /// `-previewSyncGlowPending N` (offline with no number shows three counted dashes)
    /// `-previewSyncGlowAge S` freezes the picture S seconds into the state (the event age and the
    /// clock both), so a still lands on a chosen moment: mid-flash, mid-wipe, mid-pulse.
    /// `-previewTab save|library|links|chat|stage|names|queue|settings` chooses which screen is up.
    /// Every tab, the queue sheet and the editor have their own band, so the flags work on each.
    static var frozenAge: Double? {
        guard let raw = UserDefaults.standard.string(forKey: "previewSyncGlowAge"),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return max(0, value)
    }

    static func apply(to model: AppModel) {
        let defaults = UserDefaults.standard
        guard let state = SyncGlowDebugParse.state(from: defaults.string(forKey: "previewSyncGlow")) else { return }
        let pending = SyncGlowDebugParse.pending(from: defaults.string(forKey: "previewSyncGlowPending"))
            ?? (state == .offlinePending ? 3 : 0)
        model.library.debugSyncGlow(state, pending: pending)
    }
}

struct SyncGlowDebugCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Sync glow") {
            Button("Up to date") { model.library.debugSyncGlow(.upToDate, pending: 0) }
            Button("Syncing") { model.library.debugSyncGlow(.syncing, pending: 0) }
            Button("Offline, 3 waiting") { model.library.debugSyncGlow(.offlinePending, pending: 3) }
            Button("Refused") { model.library.debugSyncGlow(.refused, pending: 1) }
            Button("Full re-pull") { model.library.debugSyncGlow(.repull, pending: 0) }
            Button("Nudge") { model.library.debugSyncGlow(.nudge, pending: 0) }
            Button("New posts") { model.library.debugSyncGlow(.arrived, pending: 0) }
            Button("Off") { model.library.debugSyncGlow(.off, pending: 0) }
            Divider()
            Button("Saving 40%") { model.library.debugSyncActivity(0.4) }
            Button("Working, no progress") { model.library.debugSyncActivity(SyncGlowActivity.indeterminate) }
            Button("No work") { model.library.debugSyncActivity(nil) }
            Divider()
            Button("Follow the engine") { model.library.debugSyncGlow(nil, pending: 0) }
        }
    }
}
#endif
