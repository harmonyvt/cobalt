import AVKit
import CobaltKit
import SwiftUI

/// What the hero's full-screen button opens: a video in the system player (sound on, scrub, AirPlay, PiP where the
/// system has them), an animated webp in a black viewer at its real aspect, or a photo in the zoomable viewer.
enum HeroFullScreen: Identifiable {
    case video(url: URL, name: String, start: CMTime)
    case webp(source: AnimatedImageView.Source, aspect: CGFloat, name: String)
    case photo(source: PhotoSource, aspect: CGFloat, name: String)

    var id: String {
        switch self {
        case .video(let url, _, _): return "video-\(url.absoluteString)"
        case .webp(let source, _, _):
            switch source {
            case .file(let url), .remote(let url): return "webp-\(url.absoluteString)"
            }
        case .photo(let source, _, _): return "photo-\(source.url?.absoluteString ?? "none")"
        }
    }
}

/// The glass icon in the hero's bottom-right corner (the type badge keeps the top-right): a 44 pt target around a
/// 30 pt glass circle, `arrow.up.left.and.arrow.down.right`, ⌘⌃F.
struct HeroFullScreenButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(Copy.Media.fullScreen, systemImage: DetailSymbol.fullScreen)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .mediaGlassCircle()
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel(Copy.Media.fullScreen)
    }
}

enum DetailSymbol {
    static let fullScreen = "viewfinder"
}

extension View {
    /// Presents `item` full screen (a sheet on the Mac); `onClose` hears the time a video reached, to carry on from
    /// it in the hero. Reduce Motion presents and dismisses without the slide.
    func heroFullScreen(item: Binding<HeroFullScreen?>, onClose: @escaping (CMTime?) -> Void) -> some View {
        #if DEBUG
        modifier(HeroFullScreenModifier(item: item, onClose: onClose)).task { DetailSnapshot.runIfRequested() }
        #else
        modifier(HeroFullScreenModifier(item: item, onClose: onClose))
        #endif
    }
}

private struct HeroFullScreenModifier: ViewModifier {
    @Binding var item: HeroFullScreen?
    let onClose: (CMTime?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fullScreenStudio) private var fullScreenStudio
    @Environment(\.subtitles) private var subtitles

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $item) { shown in
            HeroFullScreenContent(item: shown, reduceMotion: reduceMotion) { time in
                var transaction = Transaction()
                transaction.disablesAnimations = reduceMotion
                withTransaction(transaction) { item = nil }
                onClose(time)
            }
            .environment(\.fullScreenStudio, fullScreenStudio)
            .environment(\.subtitles, subtitles)
        }
        #else
        content.sheet(item: $item) { shown in
            HeroFullScreenContent(item: shown, reduceMotion: reduceMotion) { time in
                item = nil
                onClose(time)
            }
            .environment(\.fullScreenStudio, fullScreenStudio)
            .environment(\.subtitles, subtitles)
            .frame(minWidth: 920, minHeight: 640)
        }
        #endif
    }
}

private struct HeroFullScreenContent: View {
    let item: HeroFullScreen
    let reduceMotion: Bool
    let close: (CMTime?) -> Void

    var body: some View {
        switch item {
        case .video(let url, let name, let start):
            FullScreenStudioVideo(url: url, name: name, start: start, close: close)
        case .webp(let source, let aspect, let name):
            FullScreenWebp(source: source, aspect: aspect, name: name) { close(nil) }
        case .photo(let source, let aspect, let name):
            FullScreenPhoto(source: source, aspect: aspect, name: name) { close(nil) }
        }
    }
}

// MARK: - webp

/// A black screen with the animated webp at its real aspect. A tap, a swipe down or Escape closes it.
private struct FullScreenWebp: View {
    let source: AnimatedImageView.Source
    let aspect: CGFloat
    let name: String
    let close: () -> Void
    @State private var drag: CGFloat = 0

    /// Letting go here closes.
    private var pastClose: Bool { abs(drag) > 90 }
    private static func isOn(_ on: Bool) -> Bool { on }

    var body: some View {
        DuoMediaOverlay(edge: .bottom) { isSeparated in
            if isSeparated {
                VStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Label(Copy.Media.exitFullScreen, systemImage: Symbol.close)
                    }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
                    .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                VStack {
                    HStack {
                        CloseButton(cancels: true, action: close)
                            .accessibilityLabel(Copy.Media.exitFullScreen)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.top, 8)
                .background(alignment: .top) {
                    MediaEdgeVignette(edge: .top, height: 88, intensity: 0.42)
                }
            }
        } media: {
            ZStack {
                Color.black.opacity(1 - min(Double(abs(drag)) / 500, 0.5)).ignoresSafeArea()
                AnimatedImageView(source: source)
                    .aspectRatio(aspect, contentMode: .fit)
                    .offset(y: drag)
                    .accessibilityLabel(Copy.Media.webpViewerA11y(name))
                    .accessibilityAddTraits(.isButton)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if abs(value.translation.height) > 90 { close() } else { withAnimation(Motion.card) { drag = 0 } }
                    })
        }
        // a tick where letting go would close
        .haptic(.impact(weight: .light), trigger: pastClose, when: Self.isOn)
        .preferredColorScheme(.dark)
    }
}
