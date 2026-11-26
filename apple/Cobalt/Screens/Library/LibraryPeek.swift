import AVFoundation
import CobaltKit
import SwiftUI

/// Hold to peek: a hold on a tile (while selecting) or on a pick's thumbnail shows the post's media full size, with
/// nothing else on it, for as long as the finger stays down. A short tap still ticks; a scroll still scrolls (the hold
/// only begins once the finger has stayed put).
///
/// `opensOnRelease` (an iPhone tile, select mode or not; owner, 2026-11-23): the hold is the preview of a hold-and-release.
/// Lifting the finger on the tile opens the post in the pane; sliding off the tile before lifting cancels (the preview
/// goes, nothing opens). The Mac and the wide placements never set it: their hold is the peek and the context menu.
struct PeekOnHold: ViewModifier {
    let row: LibraryRow
    let controller: LibraryController
    var enabled = true
    /// A hold inside the pane's own page (a pick's thumbnail in the select actions): the page shows the peek itself, over
    /// itself, instead of asking the pane, which would swap the page the finger is on.
    var local: Binding<LibraryRow?>?
    var opensOnRelease = false
    /// When the caller already knows the view's exact size (every mosaic tile), pass it here to avoid attaching an
    /// `onGeometryChange` tracker to every tile in the scroll view.
    var knownSize: CGSize?
    /// Measured fallback when `knownSize` is nil.
    @State private var measuredSize: CGSize = .zero

    private func hold(_ phase: HoldPhase) {
        if let local {
            if phase == .began { controller.peekSwallowsTap = true; local.wrappedValue = row }
            else if local.wrappedValue?.id == row.id { local.wrappedValue = nil }
            return
        }
        if phase == .began {
            controller.setPeek(row)
            return
        }
        if controller.peek?.id == row.id { controller.setPeek(nil) }
        if phase == .lifted, opensOnRelease { controller.open(row) }
    }

    #if os(iOS)
    func body(content: Content) -> some View {
        let effectiveSize = knownSize ?? measuredSize
        content
            .modifier(OptionalGeometryMeasure(needed: knownSize == nil, size: $measuredSize))
            .gesture(HoldRecognizer(enabled: enabled, cancelsWhenDraggedOff: opensOnRelease, size: effectiveSize) { phase in
                hold(phase)
            })
    }
    #else
    @GestureState private var holding = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    },
                including: enabled ? .all : .subviews)
            .onChange(of: holding) { _, now in hold(now ? .began : .cancelled) }
    }
    #endif
}

#if os(iOS)
/// Attaches `onGeometryChange` only when the caller didn't pass a known size. `needed` is fixed per call site, so
/// the branch never swaps under a view.
private struct OptionalGeometryMeasure: ViewModifier {
    let needed: Bool
    @Binding var size: CGSize

    func body(content: Content) -> some View {
        if needed {
            content.onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        } else {
            content
        }
    }
}
#endif

/// What a hold is doing: it began (the preview shows), the finger was lifted on the view (`lifted`), or the hold ended
/// any other way (dragged off, interrupted: `cancelled`).
enum HoldPhase: Equatable {
    case began, lifted, cancelled
}

#if os(iOS)
/// The hold on iOS, as a UIKit long press. The SwiftUI long press sequenced into a zero-distance drag (still used on
/// the Mac) claims the touch on iOS 18 and later, so with one on every tile the library could not scroll while
/// selecting. A UILongPressGestureRecognizer fails as soon as the finger moves, which leaves the scroll to the scroll
/// view, and once the hold has begun the scroll waits until the finger lifts.
private struct HoldRecognizer: UIGestureRecognizerRepresentable {
    let enabled: Bool
    /// A hold that slid off the view ends as `cancelled` at once (its preview goes), and lifting later does not count.
    let cancelsWhenDraggedOff: Bool
    let size: CGSize
    let changed: (HoldPhase) -> Void

    /// How far past the view's edge the finger may wander before the hold is cancelled.
    private static let slop: CGFloat = 16

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 10
        // the tile's own tap still sees the touch; the controller swallows the one that ends a peek
        hold.cancelsTouchesInView = false
        hold.delegate = context.coordinator
        hold.isEnabled = enabled
        return hold
    }

    func updateUIGestureRecognizer(_ hold: UILongPressGestureRecognizer, context: Context) {
        if hold.isEnabled != enabled { hold.isEnabled = enabled }
    }

    func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch hold.state {
        case .began:
            coordinator.holding = true
            changed(.began)
        case .changed:
            guard coordinator.holding, cancelsWhenDraggedOff, size.width > 0 else { return }
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: -Self.slop, dy: -Self.slop)
            if !frame.contains(context.converter.localLocation) {
                coordinator.holding = false
                changed(.cancelled)
            }
        case .ended:
            guard coordinator.holding else { return }
            coordinator.holding = false
            changed(.lifted)
        case .cancelled, .failed:
            guard coordinator.holding else { return }
            coordinator.holding = false
            changed(.cancelled)
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The hold began and has not ended (or been cancelled) yet.
        var holding = false

        /// Alongside the tile's tap and the context menu, never alongside a scroll: a held peek does not also scroll.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}
#endif

extension View {
    func peekOnHold(
        _ row: LibraryRow, controller: LibraryController, enabled: Bool = true, local: Binding<LibraryRow?>? = nil,
        opensOnRelease: Bool = false, knownSize: CGSize? = nil
    ) -> some View {
        modifier(PeekOnHold(
            row: row, controller: controller, enabled: enabled, local: local, opensOnRelease: opensOnRelease,
            knownSize: knownSize))
    }
}

// MARK: - peek media players

/// Lightweight muted looping player built specifically for hold-to-peek previews.
/// Mirrors `HeroVideo`'s proven plain-`AVPlayer` + `KeyedStream` + end-of-item seek pattern (avoiding `AVPlayerLooper`
/// stalls and trim-drag delays), resolves local files off the main thread, and publishes the stream's exact rotated
/// `presentationSize` aspect ratio (`width / height`) back to `HeroVideo`'s shared launch cache.
@MainActor @Observable
private final class PeekVideoModel {
    private(set) var player: AVPlayer?
    private(set) var hasFrames = false
    private(set) var loading = false
    /// Measured `width / height` from `AVPlayerItem.presentationSize` (rotation already applied).
    private(set) var aspect: CGFloat?

    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    func start(for face: Rendition) async {
        stop()
        guard !face.playsAsWebp, !face.isStill else { return }
        guard let url = await Self.resolveVideoURL(for: face), !Task.isCancelled else { return }

        loadedURL = url
        if let known = HeroVideo.knownShape(of: url) { aspect = known }
        loading = true
        AudioPolicy.ambient()

        let item = AVPlayerItem(asset: KeyedStream.asset(url))
        item.preferredForwardBufferDuration = 4
        let next = AVPlayer(playerItem: item)
        next.isMuted = true
        next.actionAtItemEnd = .none
        player = next
        watch(next, item: item, url: url)
        PlayerPool.shared.play(next, as: .hero)
    }

    func stop() {
        for w in watches { w.invalidate() }
        watches = []
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens = []
        if let player {
            player.pause()
            PlayerPool.shared.forget(player)
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        loadedURL = nil
        hasFrames = false
        loading = false
    }

    private func shows(_ id: ObjectIdentifier) -> Bool { player.map(ObjectIdentifier.init) == id }

    private func watch(_ player: AVPlayer, item: AVPlayerItem, url: URL) {
        let id = ObjectIdentifier(player)
        watches.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.shows(id), playing else { return }
                self.hasFrames = true
                self.loading = false
            }
        })
        watches.append(item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in
                guard let self, self.shows(id), failed else { return }
                self.loading = false
            }
        })
        watches.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] observed, _ in
            let size = observed.presentationSize
            Task { @MainActor [weak self] in
                guard let self, self.shows(id), size.width > 0, size.height > 0 else { return }
                let shape = size.width / size.height
                HeroVideo.recordShape(shape, for: url)
                if self.aspect.map({ abs($0 - shape) > 0.005 }) ?? true { self.aspect = shape }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        })
    }

    private static func resolveVideoURL(for face: Rendition) async -> URL? {
        if let localURL = face.local?.fileURL {
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: localURL.path)
            }.value
            if exists { return localURL }
        }
        if let hosted = face.hosted?.url,
           face.hosted?.contentType?.lowercased().hasPrefix("image/") != true {
            return HeroSource.resolve(hosted)
        }
        if let pub = face.publicURL,
           face.file?.contentType?.lowercased().hasPrefix("image/") != true {
            return HeroSource.resolve(pub)
        }
        return HeroRemote.keyedStream(face.file)
    }
}

/// Animated webp / gif layer for `LibraryPeek`, routed through `LibraryMediaCache` (reusing the 200 MB disk cache and
/// `-previewMediaDir`) and reporting its decoded frame aspect ratio (`width / height`).
@MainActor @Observable
private final class PeekAnimator {
    static let maxPixel = 1_200

    var image: ImageBox?
    private let slot = MediaAnimationSlot()

    func play(data: Data, onFirstAspect: @escaping @MainActor (CGFloat) -> Void) {
        halt()
        var reported = false
        slot.set(MediaAnimation.play(data: data, maxPixel: Self.maxPixel) { [weak self] frame in
            guard let self else { return }
            self.image = frame
            if !reported {
                let w = frame.image.width, h = frame.image.height
                if w > 0, h > 0 {
                    reported = true
                    onFirstAspect(CGFloat(w) / CGFloat(h))
                }
            }
        })
    }

    func halt() { slot.stop() }
}

private struct PeekAnimatedLayer: View {
    let url: URL
    let onDecodedAspect: @MainActor (CGFloat) -> Void
    @State private var animator = PeekAnimator()

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View { mediaBody.mediaMask() }

    @ViewBuilder private var mediaBody: some View {
        Color.clear
            .overlay {
                if let image = animator.image {
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .allowsHitTesting(false)
            .task(id: url) {
                guard let data = try? await LibraryMediaCache.data(from: url), !Task.isCancelled else { return }
                animator.play(data: data, onFirstAspect: onDecodedAspect)
            }
            .onDisappear { animator.halt() }
    }
}

/// The peek itself: the media at its true natural dimensions over a dimmed library. A video plays muted and loops,
/// an animated webp/gif moves, and stills show at high resolution (with instant frame-0 tile cache fallback). It takes
/// no touches, so lifting the finger (which the hold is still tracking) closes it.
struct LibraryPeek: View {
    let row: LibraryRow
    /// Dims what is under it (over the grid); off on the other screen of a spread, where nothing is under it.
    var dims = true

    @State private var video = PeekVideoModel()
    @State private var decodedAspect: CGFloat?
    @State private var appeared = false
    @State private var showBuffering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var face: Rendition { row.item.face }

    private var animatedURL: URL? {
        let contentType = (face.file?.contentType ?? face.hosted?.contentType)?.lowercased()
        guard face.playsAsWebp || contentType == "image/gif" else { return nil }
        return face.local?.fileURL ?? face.publicURL ?? face.hosted?.url
    }

    private var isVideo: Bool {
        animatedURL == nil && !face.isStill && row.kind != .photo && !row.originalIsImage
    }

    /// True width ÷ height of the media: prefers live measured video presentationSize, then decoded image/animation
    /// pixels, then cached launch shape, then metadata width/height, then inverted `row.faceAspect` (`faceAspect` is
    /// `height / width`).
    private var aspect: CGFloat {
        if let measured = video.aspect { return Self.clampAspect(measured) }
        if let decoded = decodedAspect { return Self.clampAspect(decoded) }
        for candidate in [face.local?.fileURL, face.hosted?.url, face.publicURL, HeroRemote.keyedStream(face.file)].compactMap({ $0 }) {
            if let known = HeroVideo.knownShape(of: HeroSource.resolve(candidate)) {
                return Self.clampAspect(known)
            }
        }
        return Self.naturalAspect(of: row)
    }

    private var customTitle: String? {
        if case .custom(let title) = row.item.title { return title }
        return nil
    }

    private var metaLine: String {
        var parts: [String] = [LibraryRowCopy.kind(row)]
        if row.length > 0, row.kind != .gallery { parts.append(Format.seconds(row.length)) }
        if row.pixels > 0, row.kind != .gallery { parts.append(LibraryRowCopy.resolution(row)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = dims ? 20 : 12
            let verticalInset: CGFloat = dims ? 40 : 16
            let metaReserve: CGFloat = dims ? 54 : 0
            let room = CGSize(
                width: max(proxy.size.width - horizontalInset * 2, 1),
                height: max(proxy.size.height - verticalInset * 2 - metaReserve, 1))
            let size = Self.fit(aspect: aspect, in: room)
            ZStack {
                if dims {
                    Color.black
                        .opacity(appeared ? 0.66 : 0)
                        .ignoresSafeArea()
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: appeared)
                }
                VStack(spacing: 12) {
                    mediaFrame(size: size)
                    if dims {
                        metadataPill(maxWidth: min(room.width, max(size.width, 220)))
                    }
                }
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: appeared)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .onAppear { appeared = true }
        .onDisappear { video.stop() }
        .task(id: row.id) {
            decodedAspect = nil
            if isVideo { await video.start(for: face) } else { video.stop() }
        }
        .task(id: video.loading && !video.hasFrames) {
            guard video.loading, !video.hasFrames else {
                showBuffering = false
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled, video.loading, !video.hasFrames {
                showBuffering = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Library2.peekA11y)
        .accessibilityValue(row.title)
    }

    private func mediaFrame(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            FacePicture(
                item: row.item, maxPixel: 1024, showsGlyph: false, contentMode: .fit,
                onDecodedAspect: { measured in
                    if decodedAspect == nil { decodedAspect = Self.clampAspect(measured) }
                })
            if let player = video.player {
                PlayerSurface(player: player, gravity: .resizeAspect)
                    .opacity(video.hasFrames ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: video.hasFrames)
            } else if let url = animatedURL {
                PeekAnimatedLayer(url: url) { measured in
                    decodedAspect = Self.clampAspect(measured)
                }
            }
            if showBuffering, video.loading, !video.hasFrames {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .padding(6)
                    .background(TileBadgeSurface.fill, in: Circle())
                    .overlay(Circle().strokeBorder(TileBadgeSurface.stroke, lineWidth: 0.5))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.28))
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .mediaMask()
        .shadow(color: .black.opacity(dims ? 0.52 : 0.28), radius: 28, y: 12)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.88), value: size)
    }

    private func metadataPill(maxWidth: CGFloat) -> some View {
        VStack(spacing: 2) {
            if let customTitle {
                Text(customTitle)
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(metaLine)
                .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(customTitle != nil ? 0.76 : 0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, customTitle != nil ? 7 : 6)
        .frame(maxWidth: maxWidth)
        .background(Color.black.opacity(0.66), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    /// True `width / height` from the row's metadata, inverting `row.faceAspect` (`height / width`) when explicit
    /// dimensions aren't present.
    static func naturalAspect(of row: LibraryRow) -> CGFloat {
        let face = row.item.face
        if let w = face.width, let h = face.height, w > 0, h > 0 {
            return clampAspect(CGFloat(w) / CGFloat(h))
        }
        if let w = row.width, let h = row.height, w > 0, h > 0 {
            return clampAspect(CGFloat(w) / CGFloat(h))
        }
        let hw = row.faceAspect
        guard hw.isFinite, hw > 0 else { return 1 }
        return clampAspect(CGFloat(1 / hw))
    }

    static func clampAspect(_ aspect: CGFloat) -> CGFloat {
        guard aspect.isFinite, aspect > 0 else { return 1 }
        return min(max(aspect, 0.2), 5.0)
    }

    /// The largest size of this aspect (`width / height`) that fits `room`.
    static func fit(aspect: CGFloat, in room: CGSize) -> CGSize {
        let a = max(aspect, 0.05)
        guard room.width > 0, room.height > 0 else { return .zero }
        if room.width / room.height > a {
            return CGSize(width: room.height * a, height: room.height)
        }
        return CGSize(width: room.width, height: room.width / a)
    }
}

// MARK: - in the pane

/// `.peek(id)`: the held post's media in the pane, nothing else on it. The same page the library's overlay peek is, opened
/// beside the tab while a finger holds a tile; it takes no touches (the hold on the tile is still tracking), and lifting
/// the finger puts back whatever the pane showed (`Pane.endPeek`).
struct PanePeekPage: View {
    let id: String
    let model: AppModel

    @Environment(\.paneShape) private var shape

    private var row: LibraryRow? {
        model.libraryRows.first { $0.id == id } ?? model.paneMedia(id: id).map { LibraryRow(item: $0) }
    }

    var body: some View {
        if let row {
            PanePage(title: row.title, subtitle: row.kind.rawValue) {
                // a fixed room in the tall shape (the hero is not given a height there); the other shapes fill theirs
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: shape == .tall ? 380 : nil)
                    .frame(maxHeight: shape == .tall ? nil : .infinity)
                    .overlay { LibraryPeek(row: row, dims: false) }
            } controls: {
                EmptyView()
            }
            .allowsHitTesting(false)
            .hiddenCover(whenHidden: row.isHidden || model.isHiddenPost(row.item))
        } else {
            PaneGonePage()
        }
    }
}

#if DEBUG
#Preview("peek · tall", traits: .fixedLayout(width: 440, height: 700)) {
    PreviewHost(.happy, tab: .library) { model in
        PanePeekPage(id: model.libraryRows.first?.id ?? "none", model: model)
            .environment(\.paneShape, .tall)
            .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
            .environment(Pane(route: PaneRoute(item: .peek("p"), state: .screen)))
            .background(CobaltColor.bg)
    }
}
#endif
