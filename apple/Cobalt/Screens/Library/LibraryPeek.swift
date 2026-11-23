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
    /// The held view's size, to tell when the finger has slid off it (the recognizer's own view may be larger).
    @State private var size: CGSize = .zero

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
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(HoldRecognizer(enabled: enabled, cancelsWhenDraggedOff: opensOnRelease, size: size) { phase in hold(phase) })
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
        opensOnRelease: Bool = false
    ) -> some View {
        modifier(PeekOnHold(row: row, controller: controller, enabled: enabled, local: local, opensOnRelease: opensOnRelease))
    }
}

/// The peek itself: the media at its own shape over a dimmed library. A video loops muted, a webp moves, anything
/// else is its picture. It takes no touches, so lifting the finger (which the hold is still tracking) closes it.
struct LibraryPeek: View {
    let row: LibraryRow
    /// Dims what is under it (over the grid); off on the other screen of a spread, where nothing is under it.
    var dims = true

    private var face: Rendition { row.item.face }

    private var aspect: CGFloat { CGFloat(MasonryPlan.clampAspect(row.faceAspect)) }

    /// A video's file to loop: this device's copy, else the hosted link, else the public link, else the private copy
    /// streamed with the key.
    private var videoURL: URL? {
        guard !face.playsAsWebp, (face.duration ?? 0) > 0 else { return nil }
        let kept = face.local?.fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return kept ?? face.hosted?.url ?? face.publicURL ?? HeroRemote.keyedStream(face.file)
    }

    private var webpSource: AnimatedImageView.Source? {
        guard face.playsAsWebp else { return nil }
        if let url = face.local?.fileURL { return .file(url) }
        return face.publicURL.map { .remote($0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let room = CGSize(width: max(proxy.size.width - 32, 1), height: max(proxy.size.height - 64, 1))
            let size = Self.fit(aspect: aspect, in: room)
            ZStack {
                Color.black.opacity(dims ? 0.55 : 0).ignoresSafeArea()
                ZStack {
                    FacePicture(item: row.item, maxPixel: 1024, showsGlyph: false)
                    if let url = videoURL {
                        LoopingPlayerView(url: url, span: 0...min(face.duration ?? 3, 60))
                    } else if let source = webpSource {
                        AnimatedImageView(source: source)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Library2.peekA11y)
        .accessibilityValue(row.title)
    }

    /// The largest size of this aspect (width / height) that fits the room.
    static func fit(aspect: CGFloat, in room: CGSize) -> CGSize {
        let a = max(aspect, 0.05)
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
