import CobaltKit
import SwiftUI

/// The full-screen photo viewer (CONTRACT-GALLERY 1.19-1.20): the picture on black at its real shape, pinch to zoom (a
/// trackpad on the Mac), double-tap to jump in and out, drag to pan while zoomed, a swipe down or Escape to close. A long
/// gallery image opens fitted to its width, from the top.
struct FullScreenPhoto: View {
    let source: PhotoSource
    let aspect: CGFloat
    let name: String
    let close: () -> Void

    @State private var image: ImageBox?
    @State private var dismissDrag: CGFloat = 0
    @State private var zoomed = false

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(Double(abs(dismissDrag)) / 500, 0.5)).ignoresSafeArea()
            if let image {
                ZoomablePhoto(image: image.image, zoomed: $zoomed)
                    .offset(y: dismissDrag)
                    .accessibilityLabel(Copy.Media.webpViewerA11y(name))
                    .accessibilityAddTraits(.isImage)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            #if os(macOS)
            VStack {
                HStack {
                    CloseButton(cancels: true, action: close)
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            #else
            VStack {
                HStack {
                    Button(action: close) {
                        Image(systemName: Symbol.close)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CobaltColor.badgeInk)
                            .frame(width: 34, height: 34)
                            .background(CobaltColor.badgeBack, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Copy.Media.exitFullScreen)
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            #endif
        }
        .contentShape(Rectangle())
        // a swipe down closes, until the picture is zoomed (then the drag pans it)
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { if !zoomed { dismissDrag = $0.translation.height } }
                .onEnded { value in
                    guard !zoomed else { return }
                    if abs(value.translation.height) > 110 { close() } else { withAnimation(Motion.card) { dismissDrag = 0 } }
                },
            including: zoomed ? .subviews : .all)
        .preferredColorScheme(.dark)
        .task(id: source) { image = await PhotoDecoder.load(source, maxPixel: 3600) }
    }
}

/// The picture with pinch, double-tap and pan. `zoomed` is true while it is bigger than the screen allows to dismiss.
struct ZoomablePhoto: View {
    let image: CGImage
    @Binding var zoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var started = false

    private let maxScale: CGFloat = 6

    private var aspect: CGFloat { CGFloat(image.width) / CGFloat(max(1, image.height)) }

    /// How big the picture is at scale 1: fitted whole, except a long strip, which fits its width (a wide one its height).
    static func fitted(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
        let whole = aspect > box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        if aspect < 0.55 { return CGSize(width: box.width, height: box.width / aspect) }     // a strip
        if aspect > 1.8 { return CGSize(width: box.height * aspect, height: box.height) }     // side by side
        return whole
    }

    /// How far the picture may be dragged from the centre: half of what spills over the box, on each axis.
    static func limit(content: CGSize, scale: CGFloat, box: CGSize) -> CGSize {
        CGSize(
            width: max(0, (content.width * scale - box.width) / 2),
            height: max(0, (content.height * scale - box.height) / 2))
    }

    private func clamp(_ value: CGSize, content: CGSize, box: CGSize) -> CGSize {
        let l = Self.limit(content: content, scale: scale, box: box)
        return CGSize(width: min(l.width, max(-l.width, value.width)), height: min(l.height, max(-l.height, value.height)))
    }

    var body: some View {
        GeometryReader { geometry in
            let box = geometry.size
            let content = Self.fitted(aspect: aspect, in: box)
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: content.width, height: content.height)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(maxScale, max(1, base * value.magnification))
                            offset = clamp(offset, content: content, box: box)
                            zoomed = isBigger(content: content, box: box)
                        }
                        .onEnded { _ in
                            base = scale
                            baseOffset = offset
                            if scale <= 1.02 { reset(content: content, box: box) }
                        })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            guard isBigger(content: content, box: box) else { return }
                            offset = clamp(
                                CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height),
                                content: content, box: box)
                        }
                        .onEnded { _ in baseOffset = offset })
                .onTapGesture(count: 2) {
                    withAnimation(Motion.card) {
                        if scale > 1.05 { reset(content: content, box: box) } else {
                            scale = min(maxScale, 2.5)
                            base = scale
                            offset = clamp(offset, content: content, box: box)
                            baseOffset = offset
                            zoomed = true
                        }
                    }
                }
                .onAppear { place(content: content, box: box) }
                .onChange(of: box) { _, new in place(content: Self.fitted(aspect: aspect, in: new), box: new) }
        }
    }

    private func isBigger(content: CGSize, box: CGSize) -> Bool {
        content.width * scale > box.width + 1 || content.height * scale > box.height + 1
    }

    /// A strip opens at its top (or a wide one at its start).
    private func place(content: CGSize, box: CGSize) {
        guard !started || scale == 1 else { return }
        started = true
        let l = Self.limit(content: content, scale: 1, box: box)
        offset = CGSize(width: l.width, height: l.height)
        baseOffset = offset
        zoomed = isBigger(content: content, box: box)
    }

    private func reset(content: CGSize, box: CGSize) {
        scale = 1
        base = 1
        let l = Self.limit(content: content, scale: 1, box: box)
        offset = CGSize(width: l.width, height: l.height)
        baseOffset = offset
        zoomed = isBigger(content: content, box: box)
    }
}
