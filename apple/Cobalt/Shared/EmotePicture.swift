import CobaltKit
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion keeps every emote on its still.
    private var moves: Bool { animated && !reduceMotion }

    var body: some View {
        ZStack {
            // The still leaves once a frame is playing. An emote's frames are transparent, so a
            // first frame left underneath shows as a second, frozen copy.
            if !moves || !playing {
                EmoteStill(url: url)
            }
            if moves, let url {
                // a new emote is a new player: the old one's last frame never sits under the new animation
                EmoteMotion(url: url, started: $playing).id(url)
            }
        }
        .frame(width: side, height: side)
        .onChange(of: url) { _, _ in playing = false }
    }

    @State private var playing = false
}

@MainActor @Observable
private final class EmoteMotionModel {
    var image: EmoteFrame?
    @ObservationIgnored private var stopFlag: EmoteStop?

    var hasFrame = false

    func play(data: Data) {
        stop()
        let flag = EmoteStop()
        stopFlag = flag
        _ = EmoteDriver.play(data: data, stop: flag) { [weak self] frame in
            Task { @MainActor in
                guard let self else { return }
                self.image = frame
                if !self.hasFrame { self.hasFrame = true }
            }
        }
    }

    func stop() {
        stopFlag?.stop()
        stopFlag = nil
    }
}

private struct EmoteMotion: View {
    let url: URL
    var started: Binding<Bool>
    @State private var model = EmoteMotionModel()

    var body: some View {
        Color.clear
            .overlay {
                if let image = model.image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFit()
                }
            }
            .onChange(of: model.hasFrame) { _, up in
                if up, started.wrappedValue != true { started.wrappedValue = true }
            }
            .task(id: url) {
                // the same bytes as the still, from the device's emote cache (57.13)
                guard let data = await EmoteCache.shared.data(for: url), !Task.isCancelled else { return }
                model.play(data: data)
            }
            .onDisappear { model.stop() }
    }
}

/// The first frame, from `EmoteCache` (memory at once when it is there, else disk or the network), decoded off the main
/// thread. Replaces `AsyncImage`, which kept nothing between launches.
private struct EmoteStill: View {
    let url: URL?
    @State private var still: EmoteFrame?
    @State private var shown: URL?

    var body: some View {
        Group {
            if let frame = current {
                Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let url else { still = nil; shown = nil; return }
            if shown == url, still != nil { return }
            let frame = await Task.detached(priority: .userInitiated) { () -> EmoteFrame? in
                guard let data = await EmoteCache.shared.data(for: url) else { return nil }
                return EmoteStill.decode(data, url: url)
            }.value
            guard !Task.isCancelled else { return }
            still = frame
            shown = url
        }
    }

    /// The still for this url: the one this tile decoded, else one decoded before (no blank first frame on scroll back).
    private var current: EmoteFrame? {
        if let still, shown == url { return still }
        guard let url else { return nil }
        return Self.decoded.object(forKey: url as NSURL)?.frame
    }

    /// Decoded stills, about 400 (thread safe).
    nonisolated(unsafe) private static let decoded: NSCache<NSURL, FrameHolder> = {
        let c = NSCache<NSURL, FrameHolder>()
        c.countLimit = 400
        return c
    }()

    nonisolated static func decode(_ data: Data, url: URL) -> EmoteFrame? {
        if let hit = decoded.object(forKey: url as NSURL) { return hit.frame }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let frame = EmoteFrame(image: image)
        decoded.setObject(FrameHolder(frame), forKey: url as NSURL)
        return frame
    }
}

private final class FrameHolder: Sendable {
    let frame: EmoteFrame
    init(_ frame: EmoteFrame) { self.frame = frame }
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
