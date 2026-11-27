import CobaltKit
import SwiftUI

// The orbit: Home's full-bleed background. The two glass circles at the bottom centre are the centre
// of concentric rainbow arcs (`RainbowArcsGeometry`); the on-device media glide along them like a
// conveyor, newest on the innermost band. ONE PLANET PER MEDIA (CONTRACT-MEDIA 1.1): a planet shows its
// media's face, the newest webp else the video, at the face's real aspect; the badge says what the face
// is (`webp ×3` when the media has several). Only the three front-most planets play (a pool of three
// players, or an animated webp); every other planet shows its poster or, once CobaltKit has them, a
// low-rate flipbook. Every planet carries its file type in a small glass capsule in its top-right
// corner (PlanetBadge).

/// The two lines under the planet when there is one media alone ("service · ref", "length · size").
struct OrbitCaption: Equatable {
    var title: String
    var detail: String
}

struct OrbitView: View {
    /// Newest first, WITHOUT the media that is currently in focus (that one is drawn by the focus layer).
    let media: [StoredMedia]
    /// The geometry's inputs and every eased value: owned by the screen so it can ask the same questions.
    let scene: OrbitScene
    /// The timeline runs: the orbit turns, the star lives, or something is still easing.
    let running: Bool
    /// 1 at rest; the orbit dims (rather than shrinks) behind a focused planet or the work capsule.
    var dim: Double = 1
    var freshID: String?
    /// The arrival that pops in (the others, a planet back from focus, just show their outline).
    var popID: String?
    /// The orbit's players, owned by the screen (the focus layer hands its player to it).
    let pool: OrbitPlayerPool
    let playersEnabled: Bool
    /// The inner bands' flipbooks run: off behind a lifted focus view (the posters show instead).
    var flipbooksEnabled = true
    var star: StarState = .none
    var signal = StarSignal()
    var poster: CGImage?
    var lowPower = false
    /// The zoom transition's source namespace: each planet is a `matchedTransitionSource`.
    var zoom: Namespace.ID
    /// The caption under a media that is alone in the orbit (nil: none).
    var caption: (StoredMedia) -> OrbitCaption? = { _ in nil }
    /// Where the orbit really is drawn (global), measured from inside so it is the full-bleed frame.
    var onFrame: (CGRect) -> Void = { _ in }

    /// What the disk has confirmed for the shown planets (face files, the picture of a still, a gallery's turn),
    /// resolved off the view body (a body runs many times a second while the orbit turns).
    @State private var files = OrbitFiles()
    /// What was last drawn for each id: a planet that is leaving (deleted) fades out wearing its own face.
    @State private var retained: [String: StoredMedia] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Lightweight fingerprint of each shown planet's media/face paths so `.task` and `retained` updates avoid
    /// deep `Array<StoredMedia> ==` comparisons and per-render string interpolations.
    private struct OrbitMediaKey: Hashable {
        let id: String
        let faceID: String
        let filePath: String?
        let itemCount: Int
        let posterPath: String?
    }

    private func sources(for shown: [StoredMedia]) -> [String: (url: URL, duration: Double?)] {
        var out: [String: (url: URL, duration: Double?)] = [:]
        for m in shown where m.face.kind == .original && files.onDisk.contains(m.id) && !PlanetStills.isStill(m.face) {
            if let url = m.face.fileURL { out[m.id] = (url, m.face.duration) }
        }
        return out
    }

    var body: some View {
        let shown = Array(media.prefix(CurrentOrbitGeometry.maxItems))
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mediaKeys: [OrbitMediaKey] = shown.map { m in
            let face = m.face
            return OrbitMediaKey(
                id: m.id,
                faceID: face.id,
                filePath: face.fileURL?.path,
                itemCount: m.items.count,
                posterPath: face.posterURL?.path)
        }
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                orbit(
                    size: size,
                    now: context.date.timeIntervalSinceReferenceDate,
                    date: context.date,
                    shown: shown,
                    byID: byID)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
        }
        #if os(iOS)
        // Dimmed with a scrim of the page colour on top: the same look as fading the orbit, without compositing the
        // whole full-screen orbit (canvas, ~35 shadowed planets, players) offscreen on every frame. The Mac keeps the
        // fade: its page is the window material, which a flat scrim would not match.
        .overlay {
            CobaltColor.bg.opacity(1 - dim)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        .opacity(dim)
        #endif
        .animation(reduceMotion ? Motion.fade : Motion.lights, value: dim)
        .task(id: mediaKeys) {
            let planets = shown
            files = await Task.detached(priority: .utility) { OrbitFiles.resolve(planets) }.value
        }
        .onChange(of: mediaKeys, initial: true) { _, _ in
            for m in shown { retained[m.id] = m }
            if retained.count > 80 {
                let keep = Set(shown.map(\.id)).union(scene.dynamics.leaving.map(\.entry))
                retained = retained.filter { keep.contains($0.key) }
            }
        }
        .onDisappear { pool.stopAll() }
    }

    private func orbit(size: CGSize, now: Double, date: Date, shown: [StoredMedia], byID: [String: StoredMedia]) -> some View {
        let empty = shown.isEmpty && !scene.ids.contains(OrbitScene.focusID)
        let t = date.timeIntervalSince(star.since)
        let push = StarMath.push(star, t: t, reduced: reduceMotion)
        var scene = scene
        if empty { scene = scene.ghosting() }
        let layout = scene.geometry(at: now, push: push)
        let time = scene.orbitTime(at: now)
        let slots = scene.slots(at: now, geometry: layout, orbitTime: time)
        let front = layout.frontEntries(slots.filter { byID[$0.entry] != nil })
        // born at the visual centre of the orbit area (CONTRACT-ORBIT 1b); the bands part around it
        let starPos = scene.starPoint
        let newest = slots.first { $0.index == 0 }
        let band = scheme == .dark ? 0.17 : 0.16
        let lane = scheme == .dark ? 0.08 : 0.07
        let guideSpecs = scene.guideSpecs(at: now, geometry: layout)
        let items = placed(slots, empty: empty, byID: byID)
        let alone: (item: Placed, media: StoredMedia, caption: OrbitCaption)? = {
            guard !empty, scene.ids.count == 1, let item = items.first, let m = item.media, let c = caption(m) else { return nil }
            return (item, m, c)
        }()
        return ZStack(alignment: .topLeading) {
            // the bands, as hairlines, and a fainter lane either side; cached via Equatable when settled at rest
            OrbitGuidesCanvas(
                size: size,
                center: layout.center,
                edge: layout.edge,
                bottom: layout.bottom,
                specs: guideSpecs,
                bandAlpha: band,
                laneAlpha: lane)
                .equatable()
                .zIndex(-100_000)
                .allowsHitTesting(false)
            // keyed by the media (not the slot), so a planet's view, its player and its flipbook stay
            // with it when the order changes, and when its face changes
            ForEach(items) { item in
                if let media = item.media {
                    // Only what holds still at rest goes in (the box, the band, its scale); the moving parts are
                    // applied out here, so the planet's own body is skipped on frames where nothing about it changed.
                    OrbitThumb(
                        media: media, box: item.slot.box, ring: item.slot.ring, scale: item.slot.scale,
                        isFront: front.contains(media.id),
                        playing: playersEnabled, flipbooks: flipbooksEnabled,
                        hasFile: files.onDisk.contains(media.id) || pool.players[media.id] != nil, pool: pool,
                        still: files.still[media.id], turn: files.turn[media.id] ?? [],
                        fresh: freshID == media.id, pops: popID == media.id, showsLabel: item.slot.ring == 0,
                        zoom: zoom)
                        .equatable()
                        .opacity(item.slot.opacity)
                        .position(item.slot.position)
                        .zIndex(item.slot.z)
                } else {
                    GhostThumb(opacity: item.slot.opacity)
                        .position(item.slot.position)
                        .zIndex(item.slot.z)
                }
            }
            if let alone {
                // one media: its two lines under the planet, on the page colour so the hairlines never cross them
                let box = alone.item.slot.box
                OrbitCaptionView(caption: alone.caption)
                    .opacity(alone.item.slot.opacity * OrbitMath.smooth(Double((box.width * alone.item.slot.scale - 60) / 30)))
                    .position(
                        x: min(max(alone.item.slot.position.x, 150), max(150, size.width - 150)),
                        y: alone.item.slot.position.y + box.height * alone.item.slot.scale / 2 + 28)
                    .zIndex(99_000)
                    .allowsHitTesting(false)
            }
            if star.phase != .none {
                // the newest slot on the innermost band: the star becomes the planet there
                let target = newest.map { CGPoint(x: $0.position.x - starPos.x, y: $0.position.y - starPos.y) } ?? .zero
                StarCanvas(
                    state: star, t: t, signal: signal, growth: signal.growth, rings: Double(signal.developed),
                    poster: poster, frontSlot: target, fit: layout.nearFit, reduceMotion: reduceMotion, lowPower: lowPower)
                    // each step of the signal (bytes, a frame read, the next phase) eases in
                    .animation(reduceMotion ? nil : StarMath.swell, value: signal)
                    .frame(width: 360, height: 360)
                    .position(starPos)
                    .zIndex(100_000)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: front, initial: true) { _, ids in
            pool.sync(front: ids, sources: sources(for: shown), active: playersEnabled)
        }
        .onChange(of: files.onDisk) { _, _ in
            pool.sync(front: front, sources: sources(for: shown), active: playersEnabled)
        }
        .onChange(of: playersEnabled) { _, active in
            if !active { pool.stopAll() } else { pool.sync(front: front, sources: sources(for: shown), active: true) }
        }
    }

    /// A slot with the media that sits in it (nil: a ghost), identified by the media's id.
    private struct Placed: Identifiable {
        let id: String
        let slot: OrbitSlot
        let media: StoredMedia?
    }

    private func placed(_ slots: [OrbitSlot], empty: Bool, byID: [String: StoredMedia]) -> [Placed] {
        slots.compactMap { slot in
            if empty { return Placed(id: slot.entry, slot: slot, media: nil) }
            guard slot.opacity > 0.04, let media = byID[slot.entry] ?? retained[slot.entry] else { return nil }
            return Placed(id: slot.entry, slot: slot, media: media)
        }
    }
}

/// Cached orbit hairlines: skips Canvas evaluation on every 30 fps tick whenever the band radii and draw progress are settled.
private struct OrbitGuidesCanvas: View, Equatable {
    let size: CGSize
    let center: CGPoint
    let edge: CGFloat
    let bottom: CGFloat
    let specs: [OrbitGuideArcSpec]
    let bandAlpha: Double
    let laneAlpha: Double

    var body: some View {
        Canvas { ctx, _ in
            let bandStyle = GraphicsContext.Shading.color(Color.primary.opacity(bandAlpha))
            let laneStyle = GraphicsContext.Shading.color(Color.primary.opacity(laneAlpha))
            for spec in specs {
                ctx.stroke(
                    RainbowArcsGeometry.arcPath(center: center, radius: spec.radius, edge: edge, bottom: bottom, draw: spec.draw),
                    with: bandStyle,
                    lineWidth: 1)
                ctx.stroke(
                    RainbowArcsGeometry.arcPath(center: center, radius: spec.radius - spec.lane, edge: edge, bottom: bottom, draw: spec.draw),
                    with: laneStyle,
                    lineWidth: 1)
                ctx.stroke(
                    RainbowArcsGeometry.arcPath(center: center, radius: spec.radius + spec.lane, edge: edge, bottom: bottom, draw: spec.draw),
                    with: laneStyle,
                    lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The caption of a media that is alone in the orbit: "instagram · Dd7P496wolG", "10.1 s · 480×480 · 2 webps".
private struct OrbitCaptionView: View {
    let caption: OrbitCaption

    var body: some View {
        VStack(spacing: 1) {
            Text(caption.title)
                .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .background(CobaltColor.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(caption.detail)
                .font(Font.cobalt(11, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .background(CobaltColor.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(maxWidth: 300)
        .accessibilityHidden(true)
    }
}

/// A slot with nothing in it yet (an empty store): a faint outline that still glides.
private struct GhostThumb: View {
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
            .strokeBorder(CobaltColor.caption, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            .frame(width: 56, height: 80)
            .opacity(0.55 * opacity)
    }
}

/// What a planet's picture is made of for one face: the poster under everything, then the playing video
/// or webp (tier a), the flipbook (tier b), or nothing more (tier c).
private struct PlanetPicture: View {
    let media: StoredMedia
    let ring: Int
    let isFront: Bool
    let playing: Bool
    let flipbooks: Bool
    let hasFile: Bool
    let pool: OrbitPlayerPool
    /// The picture of a still face (a photo, a gallery's item): its poster, else the photo itself.
    var still: URL?
    /// A gallery's pictures, in order: the front band turns through them while the orbit moves.
    var turn: [URL] = []

    var body: some View {
        let face = media.face
        ZStack {
            if PlanetStills.isStill(face) {
                // a photo planet: the still at its aspect, nothing to play. A gallery planet in the front band, while the
                // orbit moves, turns through its items (Reduce Motion and Low Power hold item 1: `playing` is off).
                if isFront && playing && turn.count >= 2 {
                    GalleryTurner(urls: turn, seed: media.id)
                } else if let still {
                    StillImage(url: still)
                }
            } else {
            // a webp without a poster of its own borrows the video's (the frame is aspect-filled)
            if let poster = face.posterURL ?? media.original?.posterURL { StillImage(url: poster) }
            if isFront && playing && hasFile, let url = face.fileURL {
                // tier (a): the three nearest play for real
                if face.kind == .webp {
                    AnimatedImageView(source: .file(url))
                } else if let player = pool.players[media.id] {
                    PlayerSurface(player: player)
                }
            } else if playing, flipbooks, ring < 2, !face.previewFrameURLs.isEmpty {
                // tier (b): the planets on the two inner bands flip through their small preview frames
                // (5 and 4 fps); no player, nothing bigger than 160 px is decoded. The outer bands show
                // their posters (a flipbook per planet over 35 planets is a lot of decoding for a sliver).
                FlipbookView(urls: face.previewFrameURLs, fps: ring == 0 ? 5 : 4)
            }
            // tier (c): the poster above stays under everything until frames exist
            }
        }
    }
}

private struct OrbitThumb: View, Equatable {
    let media: StoredMedia
    /// The box the picture fills at scale 1, its band and the band's scale (all still at rest).
    let box: CGSize
    let ring: Int
    let scale: CGFloat
    let isFront: Bool
    let playing: Bool
    let flipbooks: Bool
    /// The face's file is on this device (resolved by the orbit, not in this body).
    let hasFile: Bool
    let pool: OrbitPlayerPool
    var still: URL?
    var turn: [URL] = []
    let fresh: Bool
    let pops: Bool
    let showsLabel: Bool
    let zoom: Namespace.ID

    @State private var popScale: CGFloat = 1
    /// The shimmer that crosses the planet when its face changes under it (a webp arrived): 0 = off,
    /// else how far it has travelled.
    @State private var sweep: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// O(1) comparison of only the rendered properties (avoids deep `StoredMedia` / `[StoredVideo]` array equality
    /// ~1,050 times/sec while the 30 fps orbit ticks). The pool and namespace live as long as the orbit.
    nonisolated static func == (a: OrbitThumb, b: OrbitThumb) -> Bool {
        guard a.box == b.box, a.ring == b.ring, a.scale == b.scale, a.isFront == b.isFront,
              a.playing == b.playing, a.flipbooks == b.flipbooks, a.hasFile == b.hasFile,
              a.still == b.still, a.turn == b.turn, a.fresh == b.fresh, a.pops == b.pops,
              a.showsLabel == b.showsLabel,
              a.media.id == b.media.id, a.media.isHosted == b.media.isHosted,
              a.media.isGallery == b.media.isGallery, a.media.items.count == b.media.items.count,
              a.media.webps.count == b.media.webps.count
        else { return false }
        let af = a.media.face
        let bf = b.media.face
        return af.id == bf.id && af.kind == bf.kind && af.duration == bf.duration
            && af.fileURL == bf.fileURL && af.posterURL == bf.posterURL
            && af.previewFrameURLs.count == bf.previewFrameURLs.count
            && a.media.original?.posterURL == b.media.original?.posterURL
    }

    private var size: CGSize { box }

    var body: some View {
        let face = media.face                       // computed (a scan of the webps and made files): once per body
        let visibleShort = min(size.width, size.height) * scale
        let counts = face.kind == .webp && media.webps.count > 1
        let shape = RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
        // The picture alone: this is what the detail's zoom grows out of (and returns to), so the zoom
        // carries the picture itself; the chips and the outline below stay out of the transition.
        ZStack {
            shape.fill(FrameGradient.fill(1))
            // the same planet, a new picture: the old face and the new crossfade
            PlanetPicture(
                media: media, ring: ring, isFront: isFront, playing: playing, flipbooks: flipbooks,
                hasFile: hasFile, pool: pool, still: still, turn: turn)
                .id(face.id)
                .transition(.opacity)
            if sweep > 0 {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.55), location: 0.5), .init(color: .clear, location: 1)],
                    startPoint: UnitPoint(x: sweep - 0.9, y: sweep - 0.9), endPoint: UnitPoint(x: sweep + 0.1, y: sweep + 0.1))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? Motion.fade : .easeInOut(duration: 0.5), value: face.id)
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .matchedTransitionSource(id: media.id, in: zoom) { source in source.clipShape(shape) }
        .overlay(alignment: .bottomLeading) {
            if showsLabel && size.width * scale >= 58 && !PlanetStills.isStill(face) {
                Text(face.duration.map { Format.seconds($0) } ?? "video")
                    .font(CobaltType.badge)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(CobaltColor.badgeInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            PlanetBadges(
                type: PlanetType(face), linked: media.isHosted, webpCount: media.webps.count,
                stack: media.isGallery ? media.items.count : nil,
                compact: visibleShort < (counts || media.isGallery ? PlanetBadge.compactBelowWithCount : PlanetBadge.compactBelow))
                .padding(PlanetBadge.inset)
        }
        .overlay {
            shape
                .stroke(CobaltColor.text, lineWidth: 2)
                .padding(-4)
                .opacity(fresh ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: fresh)
        }
        .background {
            // a gallery: two card edges peek out behind, up and to the right
            if media.isGallery {
                CardEdges(
                    size: size, radius: Metrics.thumbRadius,
                    step: CardEdges.step(forShort: visibleShort) / max(0.01, scale))
            }
        }
        .background {
            // Zero-blur layered drop shadow: avoids 35 per-frame offscreen Gaussian blur render passes while the orbit turns.
            ZStack {
                shape.fill(Color.black.opacity(0.08))
                    .padding(-4)
                    .offset(y: 6)
                shape.fill(Color.black.opacity(0.18))
                    .padding(-1.5)
                    .offset(y: 3.5)
            }
            .allowsHitTesting(false)
        }
        .scaleEffect(scale * popScale)
        .accessibilityHidden(true)
        .onChange(of: pops) { _, isFresh in
            guard isFresh else { return }
            if reduceMotion {
                popScale = 1
            } else {
                popScale = 0.2
                withAnimation(Motion.orbitPop) { popScale = 1 }
            }
        }
        .onChange(of: face.id) { _, _ in
            guard !reduceMotion else { return }
            sweep = 0.001
            withAnimation(.easeInOut(duration: 0.9)) { sweep = 1.9 }
            Task {
                try? await Task.sleep(for: .milliseconds(950))
                sweep = 0
            }
        }
    }
}

/// A flipbook: small JPEG frames shown in turn at a few frames per second. Frames are decoded off
/// the main thread at thumbnail size through `FlipbookLoader`'s own cache, bounded by decoded bytes
/// (posters have theirs, so the two never evict each other).
struct FlipbookView: View {
    let urls: [URL]
    let fps: Double
    @State private var image: ImageBox?

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View { mediaBody.mediaMask() }

    @ViewBuilder private var mediaBody: some View {
        if urls.count <= 1 {
            frameSurface
                .task(id: urls.first) {
                    guard let first = urls.first else { return }
                    if let box = await FlipbookLoader.shared.frame(for: first, maxPixel: 160) { image = box }
                }
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1 / fps)) { context in
                let i = Int(context.date.timeIntervalSinceReferenceDate * fps) % urls.count
                frameSurface
                    .task(id: i) { if let box = await FlipbookLoader.shared.frame(for: urls[i], maxPixel: 160) { image = box } }
            }
        }
    }

    private var frameSurface: some View {
        Color.clear
            .overlay {
                if let image { Image(decorative: image.image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
    }
}
