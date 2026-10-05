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

    /// Ids of the media whose face file the disk has confirmed, resolved off the view body (a body runs
    /// many times a second while the orbit turns).
    @State private var onDisk: Set<String> = []
    /// What was last drawn for each id: a planet that is leaving (deleted) fades out wearing its own face.
    @State private var retained: [String: StoredMedia] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var shown: [StoredMedia] { Array(media.prefix(CurrentOrbitGeometry.maxItems)) }

    private var sources: [String: (url: URL, duration: Double?)] {
        var out: [String: (url: URL, duration: Double?)] = [:]
        for m in shown where m.face.kind == .original && onDisk.contains(m.id) {
            if let url = m.face.fileURL { out[m.id] = (url, m.face.duration) }
        }
        return out
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                orbit(size: size, now: context.date.timeIntervalSinceReferenceDate, date: context.date)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
        }
        .opacity(dim)
        .animation(reduceMotion ? Motion.fade : Motion.lights, value: dim)
        .task(id: shown.map { "\($0.id)|\($0.face.id)|\($0.face.fileURL?.path ?? "")" }) {
            let candidates = shown.compactMap { m in m.face.fileURL.map { (m.id, $0.path) } }
            onDisk = await Task.detached(priority: .utility) {
                Set(candidates.filter { FileManager.default.fileExists(atPath: $0.1) }.map(\.0))
            }.value
        }
        .onChange(of: shown, initial: true) { _, now in
            for m in now { retained[m.id] = m }
            if retained.count > 80 {
                let keep = Set(now.map(\.id)).union(scene.dynamics.leaving.map(\.entry))
                retained = retained.filter { keep.contains($0.key) }
            }
        }
        .onDisappear { pool.stopAll() }
    }

    private func orbit(size: CGSize, now: Double, date: Date) -> some View {
        let empty = shown.isEmpty && !scene.ids.contains(OrbitScene.focusID)
        let t = date.timeIntervalSince(star.since)
        let push = StarMath.push(star, t: t, reduced: reduceMotion)
        var scene = scene
        if empty { scene = scene.ghosting() }
        let layout = scene.geometry(at: now, push: push)
        let time = scene.orbitTime(at: now)
        let slots = scene.slots(at: now, geometry: layout, orbitTime: time)
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let front = layout.frontEntries(slots.filter { byID[$0.entry] != nil })
        // born at the visual centre of the orbit area (CONTRACT-ORBIT 1b); the bands part around it
        let starPos = scene.starPoint
        let newest = slots.first { $0.index == 0 }
        let band = scheme == .dark ? 0.17 : 0.16
        let lane = scheme == .dark ? 0.08 : 0.07
        let items = placed(slots, empty: empty, byID: byID)
        let alone: (item: Placed, media: StoredMedia, caption: OrbitCaption)? = {
            guard !empty, scene.ids.count == 1, let item = items.first, let m = item.media, let c = caption(m) else { return nil }
            return (item, m, c)
        }()
        return ZStack(alignment: .topLeading) {
            // the bands, as hairlines, and a fainter lane either side; a new band draws itself from the apex
            Canvas { ctx, _ in
                for guide in scene.guides(at: now, geometry: layout) {
                    ctx.stroke(guide.path, with: .color(Color.primary.opacity(guide.isLane ? lane : band)), lineWidth: 1)
                }
            }
            .frame(width: size.width, height: size.height)
            .zIndex(-100_000)
            .allowsHitTesting(false)
            // keyed by the media (not the slot), so a planet's view, its player and its flipbook stay
            // with it when the order changes, and when its face changes
            ForEach(items) { item in
                if let media = item.media {
                    OrbitThumb(
                        media: media, slot: item.slot,
                        isFront: front.contains(media.id),
                        playing: playersEnabled, flipbooks: flipbooksEnabled,
                        hasFile: onDisk.contains(media.id) || pool.players[media.id] != nil, pool: pool,
                        fresh: freshID == media.id, pops: popID == media.id, showsLabel: item.slot.ring == 0,
                        zoom: zoom)
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
            pool.sync(front: ids, sources: sources, active: playersEnabled)
        }
        .onChange(of: onDisk) { _, _ in
            pool.sync(front: front, sources: sources, active: playersEnabled)
        }
        .onChange(of: playersEnabled) { _, active in
            if !active { pool.stopAll() } else { pool.sync(front: front, sources: sources, active: true) }
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

    var body: some View {
        let face = media.face
        ZStack {
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
                // (6 and 5 fps); no player, nothing bigger than 160 px is decoded. The outer bands show
                // their posters (a flipbook per planet over 35 planets is a lot of decoding for a sliver).
                FlipbookView(urls: face.previewFrameURLs, fps: ring == 0 ? 6 : 5)
            }
            // tier (c): the poster above stays under everything until frames exist
        }
    }
}

private struct OrbitThumb: View {
    let media: StoredMedia
    let slot: OrbitSlot
    let isFront: Bool
    let playing: Bool
    let flipbooks: Bool
    /// The face's file is on this device (resolved by the orbit, not in this body).
    let hasFile: Bool
    let pool: OrbitPlayerPool
    let fresh: Bool
    let pops: Bool
    let showsLabel: Bool
    let zoom: Namespace.ID

    @State private var popScale: CGFloat = 1
    /// The shimmer that crosses the planet when its face changes under it (a webp arrived): 0 = off,
    /// else how far it has travelled.
    @State private var sweep: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var face: StoredVideo { media.face }
    private var size: CGSize { slot.box }

    var body: some View {
        let visibleShort = min(size.width, size.height) * slot.scale
        let counts = face.kind == .webp && media.webps.count > 1
        let shape = RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
        // The picture alone: this is what the detail's zoom grows out of (and returns to), so the zoom
        // carries the picture itself; the chips and the outline below stay out of the transition.
        ZStack {
            shape.fill(FrameGradient.fill(1))
            // the same planet, a new picture: the old face and the new crossfade
            PlanetPicture(
                media: media, ring: slot.ring, isFront: isFront, playing: playing, flipbooks: flipbooks,
                hasFile: hasFile, pool: pool)
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
            if showsLabel && size.width * slot.scale >= 58 {
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
                compact: visibleShort < (counts ? PlanetBadge.compactBelowWithCount : PlanetBadge.compactBelow))
                .padding(PlanetBadge.inset)
        }
        .overlay {
            shape
                .stroke(CobaltColor.text, lineWidth: 2)
                .padding(-4)
                .opacity(fresh ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: fresh)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
        .scaleEffect(slot.scale * popScale)
        .opacity(slot.opacity)
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

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1 / fps)) { context in
            let i = Int(context.date.timeIntervalSinceReferenceDate * fps) % max(1, urls.count)
            Color.clear
                .overlay {
                    if let image { Image(decorative: image.image, scale: 1).resizable().scaledToFill() }
                }
                .clipped()
                .task(id: i) { if let box = await FlipbookLoader.shared.frame(for: urls[i], maxPixel: 160) { image = box } }
        }
    }
}
