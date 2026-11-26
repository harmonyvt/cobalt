import AVFoundation
import CobaltKit
import CoreVideo
import SwiftUI

// MARK: - Unchecked Sendable Box for Read-Only CVPixelBuffer Sampling

private struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

// MARK: - Bounded Off-Main-Thread Static Palette Cache

/// Extracts and caches pixel-accurate 3×3 `AmbientPalette` values strictly off the main thread.
actor AmbientPaletteCache {
    static let shared = AmbientPaletteCache()

    private var entries: [String: AmbientPalette] = [:]
    private var order: [String] = []
    private let limit = 48

    func cached(for rendition: Rendition?, item: MediaItem?) -> AmbientPalette? {
        guard let target = rendition ?? item?.face else { return nil }
        return entries[Self.cacheKey(rendition: target, item: item)]
    }

    func store(_ palette: AmbientPalette, for key: String) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit {
                let oldest = order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = palette
    }

    /// Resolves the best still image for `rendition` (falling back to `item?.face`), decodes a tiny 96 px
    /// thumbnail off the main thread, and extracts its true 3×3 spatial ambient palette.
    func palette(for rendition: Rendition?, item: MediaItem?) async -> AmbientPalette? {
        guard let target = rendition ?? item?.face else { return nil }
        let key = Self.cacheKey(rendition: target, item: item)
        if let hit = entries[key] {
            return hit
        }

        guard let cgImage = await Self.decodeThumbnail(rendition: target, item: item) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let sampled = AmbientColorSampler.sample(cgImage: cgImage)
        store(sampled, for: key)
        return sampled
    }

    private static func cacheKey(rendition: Rendition, item: MediaItem?) -> String {
        let urlPart = rendition.local?.posterURL?.path
            ?? rendition.local?.fileURL?.path
            ?? rendition.posterURL?.absoluteString
            ?? rendition.publicURL?.absoluteString
            ?? rendition.file?.url?.absoluteString
            ?? (rendition.isItem ? nil : item?.post?.posterURL?.absoluteString)
            ?? rendition.id
        return "\(rendition.id)|\(urlPart)"
    }

    private static func decodeThumbnail(rendition: Rendition, item: MediaItem?) async -> CGImage? {
        let maxPixel = 96
        let fm = FileManager.default

        // 1. Local poster (fast path for videos & local files).
        if let localPoster = rendition.local?.posterURL, fm.fileExists(atPath: localPoster.path) {
            if let hit = LibraryPictureCache.shared.best(in: [.file(localPoster)], maxPixel: maxPixel) {
                return hit.box.image
            }
            if let box = MediaPipeline.still(file: localPoster, maxPixel: maxPixel) {
                return box.image
            }
        }

        // 2. Local file itself (photo / webp / gif still frame, or first frame of local video).
        if let localFile = rendition.local?.fileURL, fm.fileExists(atPath: localFile.path) {
            if rendition.isStillPicture || rendition.isWebp || rendition.isAnimatedMade || rendition.isGifItem {
                if let hit = LibraryPictureCache.shared.best(in: [.file(localFile)], maxPixel: maxPixel) {
                    return hit.box.image
                }
                if let box = MediaPipeline.still(file: localFile, maxPixel: maxPixel) {
                    return box.image
                }
            } else {
                if let frame = await firstVideoFrame(at: localFile) {
                    return frame
                }
            }
        }

        // 3. Remote still / poster for this exact active rendition (supports gallery slides & rendition tabs).
        if rendition.isStillPicture, let url = rendition.publicURL ?? rendition.file?.url {
            let resolved = HeroSource.resolve(url)
            if resolved.isFileURL {
                if let box = MediaPipeline.still(file: resolved, maxPixel: maxPixel) { return box.image }
            } else {
                let source = LibraryPictureSource.image(resolved)
                if let hit = LibraryPictureCache.shared.best(in: [source], maxPixel: maxPixel) {
                    return hit.box.image
                }
                if let box = await LibraryPictureLoader.shared.picture(source, maxPixel: maxPixel) {
                    return box.image
                }
            }
        }

        let remote = HeroRemote(rendition, in: item)
        if let still = remote.still {
            let resolved = HeroSource.resolve(still.url)
            if resolved.isFileURL {
                if still.isVideo, let frame = await firstVideoFrame(at: resolved) {
                    return frame
                }
                if let box = MediaPipeline.still(file: resolved, maxPixel: maxPixel) {
                    return box.image
                }
            } else {
                let source: LibraryPictureSource = still.isVideo ? .videoFrame(resolved) : .image(resolved)
                if let hit = LibraryPictureCache.shared.best(in: [source], maxPixel: maxPixel) {
                    return hit.box.image
                }
                if let box = await LibraryPictureLoader.shared.picture(source, maxPixel: maxPixel) {
                    return box.image
                }
            }
        }

        // 4. Fallback to rendition's own poster (and post/face poster only when not on a non-cover gallery slide,
        //    so slide 2+ never falsely borrows slide 1's cover color).
        let canUsePostPoster = !rendition.isItem || rendition.id == item?.face.id
        let fallbackURL = rendition.posterURL ?? (canUsePostPoster ? (item?.post?.posterURL ?? item?.face.posterURL) : nil)
        if let fallbackURL {
            let resolved = HeroSource.resolve(fallbackURL)
            if resolved.isFileURL {
                if let box = MediaPipeline.still(file: resolved, maxPixel: maxPixel) { return box.image }
            } else {
                let source = LibraryPictureSource.image(resolved)
                if let hit = LibraryPictureCache.shared.best(in: [source], maxPixel: maxPixel) {
                    return hit.box.image
                }
                if let box = await LibraryPictureLoader.shared.picture(source, maxPixel: maxPixel) {
                    return box.image
                }
            }
        }

        return nil
    }

    private static func firstVideoFrame(at url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        return try? await generator.image(at: .zero).image
    }
}

// MARK: - Real-Time Video-Reactive Ambient Sampler

/// Attaches a lightweight `AVPlayerItemVideoOutput` to the active `AVPlayer` and samples live playing (and scrubbed)
/// video frames off the main thread (~6–7 fps) with exponential temporal smoothing and track-orientation correction.
///
/// Automatically pauses/tears down sampling when:
/// - Ambient glow is toggled off (`enabled == false`)
/// - Reduce Motion is enabled (`accessibilityReduceMotion == true`)
/// - The app leaves the foreground (`!lifecycle.isForeground`)
/// - The player detaches or the media switches to a non-video rendition
@MainActor @Observable
final class AmbientVideoSampler {
    /// Most recent temporally smoothed palette from the live video frame, or `nil` when inactive.
    private(set) var livePalette: AmbientPalette?

    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var activeOwner: UUID?
    @ObservationIgnored private weak var attachedItem: AVPlayerItem?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var orientation: AmbientOrientation = .up
    @ObservationIgnored private var orientationTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var lastSampledSeconds: Double?
    @ObservationIgnored private var active = false
    @ObservationIgnored private let defaultOwner = UUID()

    /// Registers the active hero or full-screen `AVPlayer` for live frame sampling, scoped to `owner` so
    /// overlapping gallery transitions sharing a `HeroKept` player never detach the incoming slide.
    func attach(player newPlayer: AVPlayer?, owner: UUID? = nil) {
        let ownerID = owner ?? defaultOwner
        if player === newPlayer {
            if newPlayer != nil { activeOwner = ownerID }
            syncLoop()
            return
        }
        detachOutput()
        player = newPlayer
        activeOwner = newPlayer != nil ? ownerID : nil
        lastSampledSeconds = nil
        if newPlayer == nil {
            livePalette = nil
        }
        syncLoop()
    }

    /// Detaches only if `owner` (or `oldPlayer` when no owner token is given) is still the active registrant.
    func detach(owner: UUID) {
        guard activeOwner == owner else { return }
        detachOutput()
        player = nil
        activeOwner = nil
        lastSampledSeconds = nil
        livePalette = nil
        syncLoop()
    }

    /// Detaches only if `oldPlayer` is still the currently registered player.
    func detach(player oldPlayer: AVPlayer?) {
        guard let oldPlayer, player === oldPlayer else { return }
        detachOutput()
        player = nil
        activeOwner = nil
        lastSampledSeconds = nil
        livePalette = nil
        syncLoop()
    }

    /// Clears any stale live palette when switching posts, rendition tabs, or gallery slides.
    func resetForMediaChange() {
        livePalette = nil
        lastSampledSeconds = nil
    }

    /// Enables or disables live video polling (respecting glow toggle, Reduce Motion, and foreground lifecycle).
    func setActive(_ shouldRun: Bool) {
        guard active != shouldRun else { return }
        active = shouldRun
        if !shouldRun {
            stopLoopAndOutput()
            livePalette = nil
            lastSampledSeconds = nil
        } else {
            syncLoop()
        }
    }

    /// Cleanly tears down all AVFoundation output attachments.
    func tearDown() {
        active = false
        stopLoopAndOutput()
        player = nil
        activeOwner = nil
        lastSampledSeconds = nil
        livePalette = nil
    }

    // MARK: - Sampling Loop

    private func syncLoop() {
        guard active, player != nil else {
            stopLoopAndOutput()
            return
        }
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active, let player = self.player else { break }
                await self.sampleCurrentFrameIfNeeded(from: player)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stopLoopAndOutput() {
        loopTask?.cancel()
        loopTask = nil
        detachOutput()
    }

    private func ensureOutput(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if attachedItem === item, let existing = videoOutput {
            return existing
        }
        detachOutput()
        let attrs: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        output.suppressesPlayerRendering = false
        item.add(output)
        attachedItem = item
        videoOutput = output
        orientation = .up
        lastSampledSeconds = nil
        loadOrientation(for: item)
        return output
    }

    private func loadOrientation(for item: AVPlayerItem) {
        orientationTask?.cancel()
        orientationTask = Task { [weak self, weak item] in
            guard let item,
                  let tracks = try? await item.asset.loadTracks(withMediaType: .video),
                  let track = tracks.first,
                  let transform = try? await track.load(.preferredTransform)
            else {
                return
            }
            let loaded = AmbientOrientation(preferredTransform: transform)
            guard !Task.isCancelled, let self, self.attachedItem === item else { return }
            self.orientation = loaded
        }
    }

    private func detachOutput() {
        orientationTask?.cancel()
        orientationTask = nil
        if let output = videoOutput, let item = attachedItem {
            item.remove(output)
        }
        videoOutput = nil
        attachedItem = nil
        orientation = .up
    }

    private func sampleCurrentFrameIfNeeded(from player: AVPlayer) async {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let output = ensureOutput(for: item)
        let isPlaying = player.timeControlStatus == .playing

        let targetTime: CMTime
        if isPlaying {
            let hostTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if hostTime.isValid, hostTime.isNumeric, output.hasNewPixelBuffer(forItemTime: hostTime) {
                targetTime = hostTime
            } else if livePalette == nil {
                // Capture the first decoded frame promptly right after attach/resume.
                let current = player.currentTime()
                guard current.isValid, current.isNumeric else { return }
                targetTime = current
            } else {
                return
            }
        } else {
            // While paused, sample once initially or whenever the user scrubs to a new timestamp.
            let current = player.currentTime()
            guard current.isValid, current.isNumeric else { return }
            let seconds = current.seconds
            guard seconds.isFinite else { return }
            if livePalette != nil, let last = lastSampledSeconds, abs(seconds - last) < 0.08 {
                return
            }
            targetTime = current
        }

        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: targetTime, itemTimeForDisplay: nil) else {
            return
        }

        let currentOrientation = orientation
        let box = PixelBufferBox(buffer: pixelBuffer)
        let sampled = await Self.sampleOffMainThread(box, orientation: currentOrientation)
        guard !Task.isCancelled, active, self.player === player, self.attachedItem === item else { return }

        let seconds = targetTime.seconds
        if seconds.isFinite {
            lastSampledSeconds = seconds
        }

        if let previous = livePalette {
            livePalette = previous.blended(with: sampled, factor: isPlaying ? 0.34 : 0.65)
        } else {
            livePalette = sampled
        }
    }

    nonisolated private static func sampleOffMainThread(
        _ box: PixelBufferBox,
        orientation: AmbientOrientation
    ) async -> AmbientPalette {
        await Task.detached(priority: .utility) {
            AmbientColorSampler.sample(pixelBuffer: box.buffer, orientation: orientation)
        }.value
    }
}

private struct AmbientVideoSamplerKey: EnvironmentKey {
    static var defaultValue: AmbientVideoSampler? { nil }
}

extension EnvironmentValues {
    /// Active ambient cinema video sampler injected by `AmbientCinemaPostStudio` / `FullScreenStudio`.
    var ambientVideoSampler: AmbientVideoSampler? {
        get { self[AmbientVideoSamplerKey.self] }
        set { self[AmbientVideoSamplerKey.self] = newValue }
    }
}

// MARK: - Pixel-Accurate Seamless Ambient Cinema Backdrop

/// Edge-to-edge Ambient Cinema backlight rendered with pure SwiftUI `MeshGradient` (zero `UIViewRepresentable`,
/// zero `.mediaMask()`, zero `.drawingGroup()`, zero `.clipped()`). Tracks the active post, rendition tab, and
/// gallery carousel slide, and reacts live to playing/scrubbed video frames via `AmbientVideoSampler`, bleeding
/// edge-to-edge into all safe areas with zero dark bottom clip seam.
struct AmbientCinemaBackdrop: View {
    let item: MediaItem?
    /// Currently visible rendition (active gallery slide or selected rendition tab). `nil` falls back to `item?.face`.
    var rendition: Rendition? = nil
    /// Live video-reactive palette when video playback is active.
    var livePalette: AmbientPalette? = nil
    var enabled: Bool = true
    /// Softly feathers the trailing edge into `#070709` when sitting next to a Studio Deck or Book crease.
    var featherTrailing: Bool = false
    /// Softly feathers the bottom edge into `#070709` when sitting above a Tabletop horizontal crease.
    var featherBottom: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var staticPalette: AmbientPalette = .darkNeutral
    @State private var loadedItemID: MediaItem.ID?

    private var activeRendition: Rendition? { rendition ?? item?.face }

    private var effectivePalette: AmbientPalette {
        if let livePalette, !reduceMotion {
            return livePalette
        }
        return staticPalette
    }

    private var taskKey: String {
        let rID = activeRendition?.id ?? "none"
        let iID = item?.id ?? "none"
        let urlPart = activeRendition?.local?.posterURL?.path
            ?? activeRendition?.local?.fileURL?.path
            ?? activeRendition?.posterURL?.absoluteString
            ?? activeRendition?.publicURL?.absoluteString
            ?? activeRendition?.file?.url?.absoluteString
            ?? ""
        return "\(iID)|\(rID)|\(urlPart)|\(enabled)"
    }

    private static let meshPositions: [SIMD2<Float>] = [
        SIMD2(0.0, 0.0), SIMD2(0.5, 0.0), SIMD2(1.0, 0.0),
        SIMD2(0.0, 0.5), SIMD2(0.5, 0.5), SIMD2(1.0, 0.5),
        SIMD2(0.0, 1.0), SIMD2(0.5, 1.0), SIMD2(1.0, 1.0),
    ]

    var body: some View {
        ZStack {
            Color(hex: 0x070709)

            if enabled {
                ZStack {
                    MeshGradient(
                        width: AmbientPalette.gridDimension,
                        height: AmbientPalette.gridDimension,
                        points: Self.meshPositions,
                        colors: effectivePalette.points.map { rgb in
                            Color(red: rgb.r, green: rgb.g, blue: rgb.b)
                        },
                        smoothsColors: true
                    )
                    .opacity(0.86)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: effectivePalette)

                    // Soft theatrical vignette so media edges and Clear Liquid Glass pills remain crisp over any frame.
                    RadialGradient(
                        colors: [
                            Color.black.opacity(0.08),
                            Color.black.opacity(0.32),
                            Color.black.opacity(0.66),
                        ],
                        center: .center,
                        startRadius: 48,
                        endRadius: 560
                    )

                    if featherTrailing {
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color(hex: 0x070709).opacity(0.38),
                                Color(hex: 0x070709).opacity(0.88),
                            ],
                            startPoint: UnitPoint(x: 0.72, y: 0.5),
                            endPoint: .trailing
                        )
                    }

                    if featherBottom {
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color(hex: 0x070709).opacity(0.35),
                                Color(hex: 0x070709).opacity(0.86),
                            ],
                            startPoint: UnitPoint(x: 0.5, y: 0.74),
                            endPoint: .bottom
                        )
                    }
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: enabled)
        .task(id: taskKey) {
            guard enabled else { return }
            let targetItem = item
            let targetRendition = activeRendition

            // Missing gallery slide or empty media: transition cleanly to neutral dark.
            guard targetRendition != nil else {
                applyStaticPalette(.darkNeutral, itemID: targetItem?.id)
                return
            }

            // Fast path: if already cached, transition immediately without flashing to dark.
            if let cached = await AmbientPaletteCache.shared.cached(for: targetRendition, item: targetItem) {
                guard !Task.isCancelled else { return }
                applyStaticPalette(cached, itemID: targetItem?.id)
                return
            }

            // Switching to a different post before its thumbnail is cached: clear the previous post's glow
            // immediately so unrelated colors never linger behind the new post while decoding.
            if targetItem?.id != loadedItemID {
                applyStaticPalette(.darkNeutral, itemID: targetItem?.id)
            }

            let sampled = await AmbientPaletteCache.shared.palette(for: targetRendition, item: targetItem)
            guard !Task.isCancelled else { return }
            applyStaticPalette(sampled ?? .darkNeutral, itemID: targetItem?.id)
        }
    }

    private func applyStaticPalette(_ palette: AmbientPalette, itemID: MediaItem.ID?) {
        loadedItemID = itemID
        if reduceMotion {
            staticPalette = palette
        } else {
            withAnimation(.easeInOut(duration: 0.45)) {
                staticPalette = palette
            }
        }
    }
}
