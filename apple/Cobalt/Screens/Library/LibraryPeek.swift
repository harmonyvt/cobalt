import CobaltKit
import SwiftUI

/// Hold to peek: a hold on a tile (while selecting) or on a pick's thumbnail shows the post's media full size, with
/// nothing else on it, for as long as the finger stays down. A short tap still ticks; a scroll still scrolls (the hold
/// only begins once the finger has stayed put).
struct PeekOnHold: ViewModifier {
    let row: LibraryRow
    let controller: LibraryController
    var enabled = true

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
}

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
