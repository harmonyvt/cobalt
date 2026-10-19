import CobaltKit
import SwiftUI

/// Hold to peek: a hold on a tile (while selecting) or on a pick's thumbnail shows the post's media full size, with
/// nothing else on it, for as long as the finger stays down. A short tap still ticks; a scroll still scrolls (the hold
/// only begins once the finger has stayed put).
struct PeekOnHold: ViewModifier {
    let row: LibraryRow
    let controller: LibraryController
    var enabled = true

    #if os(iOS)
    func body(content: Content) -> some View {
        content.gesture(HoldRecognizer(enabled: enabled) { holding in
            if holding { controller.setPeek(row) } else if controller.peek?.id == row.id { controller.setPeek(nil) }
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
            .onChange(of: holding) { _, now in
                if now { controller.setPeek(row) } else if controller.peek?.id == row.id { controller.setPeek(nil) }
            }
    }
    #endif
}

#if os(iOS)
/// The hold on iOS, as a UIKit long press. The SwiftUI long press sequenced into a zero-distance drag (still used on
/// the Mac) claims the touch on iOS 18 and later, so with one on every tile the library could not scroll while
/// selecting. A UILongPressGestureRecognizer fails as soon as the finger moves, which leaves the scroll to the scroll
/// view, and once the hold has begun the scroll waits until the finger lifts.
private struct HoldRecognizer: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (Bool) -> Void

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
        switch hold.state {
        case .began: changed(true)
        case .ended, .cancelled, .failed: changed(false)
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Alongside the tile's tap and the context menu, never alongside a scroll: a held peek does not also scroll.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}
#endif

extension View {
    func peekOnHold(_ row: LibraryRow, controller: LibraryController, enabled: Bool = true) -> some View {
        modifier(PeekOnHold(row: row, controller: controller, enabled: enabled))
    }
}

/// The peek itself: the media at its own shape over a dimmed library. A video loops muted, a webp moves, anything
/// else is its picture. It takes no touches, so lifting the finger (which the hold is still tracking) closes it.
struct LibraryPeek: View {
    let row: LibraryRow

    private var face: Rendition { row.item.face }

    private var aspect: CGFloat { CGFloat(MasonryPlan.clampAspect(row.faceAspect)) }

    /// A video's file to loop: this device's copy, else the hosted link, else the public link.
    private var videoURL: URL? {
        guard !face.playsAsWebp, (face.duration ?? 0) > 0 else { return nil }
        return face.local?.fileURL ?? face.hosted?.url ?? face.publicURL
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
                Color.black.opacity(0.55).ignoresSafeArea()
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
