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

/// The soft band along the top of the library. Hit testing is off. The keyboard and the Finder
/// extension do not use this view.
struct SyncGlowBand: View {
    var status: SyncGlowStatus?
    var tabVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var previous: SyncGlowState = .upToDate
    @State private var transitionStart = CACurrentMediaTime() - SyncGlowTiming.transition
    @State private var eventStart = CACurrentMediaTime()

    var body: some View {
        let state = status?.state ?? .off
        Group {
            if let status, state != .off {
                representable(status: status, state: state)
                    .frame(height: 152)
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
            // outgoing field stays on the settled frame instead of snapping back to the start.
            if new == .refused || new == .repull || new == .nudge {
                eventStart = CACurrentMediaTime()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: taskKey(state)) {
            while !Task.isCancelled {
                status?.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func taskKey(_ state: SyncGlowState) -> String {
        "\(state.rawValue)-\(onScreen)-\(scenePhase == .active)"
    }

    @ViewBuilder
    private func representable(status: SyncGlowStatus, state: SyncGlowState) -> some View {
        let pinned: Float? = status.pinsEventAge ? Float(status.eventAge(at: Date())) : nil
        let draw = SyncGlowDraw(
            state: state,
            previous: previous,
            transitionStart: transitionStart,
            eventStart: eventStart,
            pinEventAge: pinned,
            pending: status.pendingCount,
            reduceMotion: reduceMotion,
            lowPower: lowPower,
            intensity: colorScheme == .dark ? SyncGlowComposer.defaultIntensity : 0.48,
            density: SyncGlowComposer.defaultDensity,
            visible: onScreen && tabVisible,
            sceneActive: scenePhase == .active)
        #if os(iOS)
        SyncGlowMetalIOS(draw: draw)
        #else
        SyncGlowMetalMac(draw: draw)
        #endif
    }
}

struct SyncGlowDraw: Equatable {
    var state: SyncGlowState
    var previous: SyncGlowState
    var transitionStart: TimeInterval
    var eventStart: TimeInterval
    var pinEventAge: Float?
    var pending: Int
    var reduceMotion: Bool
    var lowPower: Bool
    var intensity: Float
    var density: Float
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

/// Clears hit testing. The band is decoration over the library, including the Mac title bar area.
final class SyncGlowMTKView: MTKView {
    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        #if os(iOS)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #endif
        isOpaque = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("SyncGlowMTKView is created in code")
    }
}

/// Draws the constellation into an extended-range drawable. Frame rate comes from `SyncGlowPace`:
/// idle is slow, a sweep or a crossfade is faster, and a hidden or background library does not draw.
@MainActor
final class SyncGlowRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var starsPipeline: MTLRenderPipelineState?
    private var blurHPipeline: MTLRenderPipelineState?
    private var blurVPipeline: MTLRenderPipelineState?
    private var presentPipeline: MTLRenderPipelineState?
    private var atlas: MTLTexture?
    private var starTex: MTLTexture?
    private var blurTex: MTLTexture?
    private var bloomTex: MTLTexture?
    private var starSize = CGSize.zero
    private var bloomSize = CGSize.zero
    private var drawState = SyncGlowDraw(
        state: .upToDate, previous: .upToDate, transitionStart: 0, eventStart: 0, pinEventAge: nil,
        pending: 0, reduceMotion: false, lowPower: false, intensity: SyncGlowComposer.defaultIntensity,
        density: SyncGlowComposer.defaultDensity, visible: true, sceneActive: true)
    private var lastStill: SyncGlowDraw?
    private var drawing = false
    private let started = CACurrentMediaTime()
    private var glyphs = false

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        super.init()
        guard let device else { return }
        buildPipelines(device)
        if let image = GlyphAtlasBaker.rasterize(), let texture = GlyphAtlasBaker.texture(device: device, image: image) {
            atlas = texture
            glyphs = true
        } else {
            atlas = Self.fallbackAtlas(device)
            glyphs = false
        }
    }

    func makeView() -> SyncGlowMTKView {
        let view = SyncGlowMTKView(frame: .zero, device: device)
        view.delegate = self
        view.colorPixelFormat = .rgba16Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        // The present pass renders into the drawable with its own pass, so the texture cannot be framebuffer-only.
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = SyncGlowPace.idle
        if let layer = view.layer as? CAMetalLayer {
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
        }
        return view
    }

    func update(_ view: SyncGlowMTKView, draw: SyncGlowDraw) {
        drawState = draw
        let fps = SyncGlowPace.framesPerSecond(
            state: draw.state, transitioning: false, reduceMotion: draw.reduceMotion, lowPower: draw.lowPower,
            visible: draw.visible, sceneActive: draw.sceneActive)
        if let fps {
            view.preferredFramesPerSecond = fps
            if view.isPaused { view.isPaused = false }
        } else {
            view.isPaused = true
            if lastStill != draw { view.draw() }
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
        guard !drawing, view.isPaused, lastStill != drawState, size.width > 0, size.height > 0 else { return }
        view.draw()
    }

    private func drawMain(in view: MTKView) {
        guard !drawing else { return }
        drawing = true
        defer { drawing = false }
        guard drawState.visible, drawState.sceneActive, drawState.state != .off else { return }
        guard let drawable = view.currentDrawable, let queue, let command = queue.makeCommandBuffer() else { return }
        guard let starsPipeline, let blurHPipeline, let blurVPipeline, let presentPipeline, let atlas else { return }
        let width = drawable.texture.width
        let height = drawable.texture.height
        guard width > 0, height > 0 else { return }
        let bloomW = max(width / 2, 1)
        let bloomH = max(height / 2, 1)
        guard ensureTargets(width: width, height: height, bloomW: bloomW, bloomH: bloomH),
              let starTex, let blurTex, let bloomTex else { return }

        let now = CACurrentMediaTime()
        let fade = SyncGlowComposer.transition(
            elapsed: now - drawState.transitionStart, reduceMotion: drawState.reduceMotion)
        if let fps = SyncGlowPace.framesPerSecond(
            state: drawState.state, transitioning: fade < 0.999, reduceMotion: drawState.reduceMotion,
            lowPower: drawState.lowPower, visible: true, sceneActive: true
        ), view.preferredFramesPerSecond != fps {
            view.preferredFramesPerSecond = fps
        }
        let age = drawState.pinEventAge.map { TimeInterval($0) } ?? max(0, now - drawState.eventStart)
        let time = Float(now - started)
        var uniforms = SyncGlowComposer.uniforms(
            time: time, state: drawState.state, previous: drawState.previous, transition: fade,
            pendingCount: drawState.pending, reduceMotion: drawState.reduceMotion, lowPower: drawState.lowPower,
            headroom: headroom(of: view), eventAge: age, width: Float(width), height: Float(height),
            glyphsEnabled: glyphs, intensity: drawState.intensity, density: drawState.density)
        var packed = uniforms.packed

        encode(command, pipeline: starsPipeline, target: starTex, clear: true, packed: &packed) { encoder in
            encoder.setFragmentTexture(atlas, index: 0)
        }
        var blurPacked = packed
        blurPacked[SyncGlowUniforms.Index.width] = Float(bloomW)
        blurPacked[SyncGlowUniforms.Index.height] = Float(bloomH)
        encode(command, pipeline: blurHPipeline, target: blurTex, clear: true, packed: &blurPacked) { encoder in
            encoder.setFragmentTexture(starTex, index: 0)
        }
        encode(command, pipeline: blurVPipeline, target: bloomTex, clear: true, packed: &blurPacked) { encoder in
            encoder.setFragmentTexture(blurTex, index: 0)
        }
        encode(command, pipeline: presentPipeline, target: drawable.texture, clear: true, packed: &packed) { encoder in
            encoder.setFragmentTexture(starTex, index: 0)
            encoder.setFragmentTexture(bloomTex, index: 1)
        }
        command.present(drawable)
        command.commit()
        lastStill = drawState
    }

    private func encode(
        _ command: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        target: MTLTexture,
        clear: Bool,
        packed: inout [Float],
        bind: (MTLRenderCommandEncoder) -> Void
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        packed.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 0)
            }
        }
        bind(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureTargets(width: Int, height: Int, bloomW: Int, bloomH: Int) -> Bool {
        guard let device else { return false }
        if starTex == nil || Int(starSize.width) != width || Int(starSize.height) != height {
            starTex = makeTarget(device, width: width, height: height)
            starSize = CGSize(width: width, height: height)
        }
        if bloomTex == nil || Int(bloomSize.width) != bloomW || Int(bloomSize.height) != bloomH {
            blurTex = makeTarget(device, width: bloomW, height: bloomH)
            bloomTex = makeTarget(device, width: bloomW, height: bloomH)
            bloomSize = CGSize(width: bloomW, height: bloomH)
        }
        return starTex != nil && blurTex != nil && bloomTex != nil
    }

    private static func fallbackAtlas(_ device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: UInt8 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 1)
        return texture
    }

    private func makeTarget(_ device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func buildPipelines(_ device: MTLDevice) {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "glowVertex"),
              let stars = library.makeFunction(name: "glowStars"),
              let blurH = library.makeFunction(name: "glowBlurH"),
              let blurV = library.makeFunction(name: "glowBlurV"),
              let present = library.makeFunction(name: "glowPresent") else { return }
        starsPipeline = pipeline(device, vertex: vertex, fragment: stars, format: .rgba16Float)
        blurHPipeline = pipeline(device, vertex: vertex, fragment: blurH, format: .rgba16Float)
        blurVPipeline = pipeline(device, vertex: vertex, fragment: blurV, format: .rgba16Float)
        presentPipeline = pipeline(device, vertex: vertex, fragment: present, format: .rgba16Float)
    }

    private func pipeline(_ device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        return try? device.makeRenderPipelineState(descriptor: descriptor)
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

#if DEBUG
enum SyncGlowDebugLaunch {
    /// `-previewSyncGlow upToDate|syncing|offline|refused|repull|nudge|off`
    /// `-previewSyncGlowPending N` (offline with no number shows three waiting stars)
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
            Button("Off") { model.library.debugSyncGlow(.off, pending: 0) }
            Divider()
            Button("Follow the engine") { model.library.debugSyncGlow(nil, pending: 0) }
        }
    }
}
#endif
