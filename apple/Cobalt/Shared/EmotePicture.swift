import ImageIO
import SwiftUI
import Synchronization

/// One 7TV tile. A still emote stays on the single frame. An animated one plays the webp,
/// which `AsyncImage` never does: it decodes frame 0 and stops. The `animated` flag is the
/// one on the search result.
struct EmotePicture: View {
    let url: URL?
    var animated: Bool
    var side: CGFloat = 64

    var body: some View {
        ZStack {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            if animated, let url {
                EmoteMotion(url: url)
            }
        }
        .frame(width: side, height: side)
    }
}

@MainActor @Observable
private final class EmoteMotionModel {
    var image: EmoteFrame?
    @ObservationIgnored private var stopFlag: EmoteStop?

    func play(data: Data) {
        stop()
        let flag = EmoteStop()
        stopFlag = flag
        _ = EmoteDriver.play(data: data, stop: flag) { [weak self] frame in
            Task { @MainActor in self?.image = frame }
        }
    }

    func stop() {
        stopFlag?.stop()
        stopFlag = nil
    }
}

private struct EmoteMotion: View {
    let url: URL
    @State private var model = EmoteMotionModel()

    var body: some View {
        Color.clear
            .overlay {
                if let image = model.image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFit()
                }
            }
            .task(id: url) {
                guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
                model.play(data: data)
            }
            .onDisappear { model.stop() }
    }
}

private struct EmoteFrame: @unchecked Sendable {
    let image: CGImage
}

private final class EmoteStop: Sendable {
    private let flag = Mutex(false)
    func stop() { flag.withLock { $0 = true } }
    var isStopped: Bool { flag.withLock { $0 } }
}

private enum EmoteDriver {
    static func play(data: Data, stop: EmoteStop, onFrame: @escaping @Sendable (EmoteFrame) -> Void) -> Bool {
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { _, image, halt in
            if stop.isStopped { halt.pointee = true; return }
            onFrame(EmoteFrame(image: image))
        }
        return status == noErr
    }
}
