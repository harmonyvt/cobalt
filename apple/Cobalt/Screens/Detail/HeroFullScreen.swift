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
            Image(systemName: DetailSymbol.fullScreen)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CobaltColor.badgeInk)
                .frame(width: 30, height: 30)
                .background(CobaltColor.badgeBack, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel(Copy.Media.fullScreen)
    }
}

enum DetailSymbol {
    static let fullScreen = "arrow.up.left.and.arrow.down.right"
}

extension View {
    /// Presents `item` full screen (a sheet on the Mac); `onClose` hears the time a video reached, to carry on from
    /// it in the hero. Reduce Motion presents and dismisses without the slide.
    func heroFullScreen(item: Binding<HeroFullScreen?>, onClose: @escaping (CMTime?) -> Void) -> some View {
        modifier(HeroFullScreenModifier(item: item, onClose: onClose))
    }
}

private struct HeroFullScreenModifier: ViewModifier {
    @Binding var item: HeroFullScreen?
    let onClose: (CMTime?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $item) { shown in
            HeroFullScreenContent(item: shown, reduceMotion: reduceMotion) { time in
                var transaction = Transaction()
                transaction.disablesAnimations = reduceMotion
                withTransaction(transaction) { item = nil }
                onClose(time)
            }
        }
        #else
        content.sheet(item: $item) { shown in
            HeroFullScreenContent(item: shown, reduceMotion: reduceMotion) { time in
                item = nil
                onClose(time)
            }
            .frame(minWidth: 860, minHeight: 620)
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
        case .video(let url, _, let start):
            FullScreenVideo(url: url, start: start, close: close)
        case .webp(let source, let aspect, let name):
            FullScreenWebp(source: source, aspect: aspect, name: name) { close(nil) }
        case .photo(let source, let aspect, let name):
            FullScreenPhoto(source: source, aspect: aspect, name: name) { close(nil) }
        }
    }
}

// MARK: - video

/// The system player over a black screen: the clip's own item (sound on), from where the hero had got to.
private struct FullScreenVideo: View {
    let url: URL
    let start: CMTime
    let close: (CMTime?) -> Void
    @State private var player = AVPlayer()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button { finish() } label: {
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
            .padding(.leading, 12)
            .padding(.top, 8)
            .accessibilityLabel(Copy.Media.exitFullScreen)
        }
        .preferredColorScheme(.dark)
        .task {
            AudioPolicy.playback()
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            player.isMuted = false
            await item.seek(to: start.isValid ? start : .zero)
            player.play()
        }
        .onDisappear { player.pause() }
    }

    private func finish() {
        let time = player.currentTime()
        player.pause()
        AudioPolicy.release()
        close(time.isValid ? time : nil)
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

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(Double(abs(drag)) / 500, 0.5)).ignoresSafeArea()
            AnimatedImageView(source: source)
                .aspectRatio(aspect, contentMode: .fit)
                .offset(y: drag)
                .accessibilityLabel(Copy.Media.webpViewerA11y(name))
                .accessibilityAddTraits(.isButton)
            #if os(macOS)
            // the Mac sheet has no swipe down: a visible close, top leading like the video's, that is also Escape
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
            Button(Copy.Media.exitFullScreen, action: close)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            #endif
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if abs(value.translation.height) > 90 { close() } else { withAnimation(Motion.card) { drag = 0 } }
                })
        .preferredColorScheme(.dark)
    }
}
