import CobaltKit
import SwiftUI

/// One 7TV tile. A still emote stays on the single frame. An animated one plays the webp, which `AsyncImage` never does:
/// it decodes frame 0 and stops. The `animated` flag is the one on the search result.
///
/// Everything goes through `MediaPipeline` (8.17): the still is downsampled to the tile's own pixels off the main thread
/// and kept in the shared cache, and a moving emote plays only while `MotionBudget` gives it a slot (on screen, within the
/// device's limit), its frames shrunk to the same size off the main thread and gated one at a time. An emote off screen
/// or over the budget shows its first frame. 8.16's emotes skipped all of that: the 7TV tab hitched 401 ms per second.
struct EmotePicture: View {
    let url: URL?
    var animated: Bool
    var side: CGFloat = 64
    var fill: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var ticket = MotionTicket()
    @State private var onScreen = false
    @State private var playing = false

    /// Pixels on the tile's side: the still and every frame are decoded to this, never the 7TV file's own size.
    private var maxPixel: Int { MediaPipeline.maxPixel(points: side, scale: displayScale) }

    /// Reduce Motion keeps every emote on its still.
    private var wantsMotion: Bool { animated && !reduceMotion && url != nil }
    private var moves: Bool { wantsMotion && ticket.granted }

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View { mediaBody.mediaMask() }

    @ViewBuilder private var mediaBody: some View {
        ZStack {
            // The still leaves once a frame is playing. An emote's frames are transparent, so a first frame left
            // underneath shows as a second, frozen copy.
            if !moves || !playing {
                EmoteStill(url: url, maxPixel: maxPixel, fill: fill)
            }
            if moves, let url {
                // a new emote is a new player: the old one's last frame never sits under the new animation
                EmoteMotion(url: url, maxPixel: maxPixel, fill: fill, started: $playing).id(url)
            }
        }
        .frame(width: fill ? nil : side, height: fill ? nil : side)
        .onChange(of: url) { _, _ in playing = false }
        .onChange(of: moves) { _, now in if !now { playing = false } }
        .onChange(of: wantsMotion) { _, _ in askBudget() }
        .onAppear { onScreen = true; askBudget() }
        .onDisappear { onScreen = false; askBudget() }
        // a lazy grid keeps a few rows past the edge alive: those give their slot back too
        .onScrollVisibilityChange(threshold: 0.1) { visible in onScreen = visible; askBudget() }
    }

    private func askBudget() {
        MotionBudget.shared.want(ticket, onScreen && wantsMotion)
    }
}

@MainActor @Observable
private final class EmoteMotionModel {
    var image: ImageBox?
    var hasFrame = false
    @ObservationIgnored private var animation: MediaAnimation?

    func play(data: Data, maxPixel: Int) {
        stop()
        // frames arrive here already shrunk to the tile, one at a time; this only assigns them
        animation = MediaAnimation.play(data: data, maxPixel: maxPixel) { [weak self] frame in
            guard let self else { return }
            self.image = frame
            if !self.hasFrame { self.hasFrame = true }
        }
    }

    func stop() {
        animation?.stop()
        animation = nil
    }
}

private struct EmoteMotion: View {
    let url: URL
    let maxPixel: Int
    var fill: Bool = false
    var started: Binding<Bool>
    @State private var model = EmoteMotionModel()

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View { mediaBody.mediaMask() }

    @ViewBuilder private var mediaBody: some View {
        Color.clear
            .overlay {
                if let image = model.image {
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                }
            }
            .clipped()
            .onChange(of: model.hasFrame) { _, up in
                if up, started.wrappedValue != true { started.wrappedValue = true }
            }
            .task(id: url) {
                // the same bytes as the still, from the device's emote cache (57.13), read off the main actor
                guard let data = await EmoteCache.shared.data(for: url), !Task.isCancelled else { return }
                model.play(data: data, maxPixel: maxPixel)
            }
            .onDisappear { model.stop() }
    }
}

/// The first frame at the tile's size, from `MediaPipeline` (the shared cache at once when it is there, else `EmoteCache`
/// bytes decoded off the main thread). Replaces `AsyncImage`, which kept nothing between launches.
private struct EmoteStill: View {
    let url: URL?
    let maxPixel: Int
    var fill: Bool = false
    @State private var still: ImageBox?
    @State private var shown: Key?

    private struct Key: Hashable {
        let url: URL
        let maxPixel: Int
    }

    private var key: Key? { url.map { Key(url: $0, maxPixel: maxPixel) } }

    var body: some View {
        Group {
            if fill {
                Color.clear
                    .overlay {
                        if let frame = current {
                            Image(decorative: frame.image, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .clipped()
            } else if let frame = current {
                Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: key) {
            guard let key else { still = nil; shown = nil; return }
            if shown == key, still != nil { return }
            let frame = await MediaPipeline.emoteStill(key.url, maxPixel: key.maxPixel)
            guard !Task.isCancelled else { return }
            still = frame
            shown = key
        }
    }

    /// The still for this url: the one this tile decoded, else one decoded before (no blank first frame on scroll back).
    private var current: ImageBox? {
        if let still, shown == key { return still }
        guard let key else { return nil }
        return MediaPipeline.cachedEmoteStill(key.url, maxPixel: key.maxPixel)
    }
}
