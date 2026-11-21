@preconcurrency import AVFoundation
import CobaltKit
import CoreGraphics
import ImageIO
import Observation
import SwiftUI

// The picture the editor works on, on the device (APP-API-CONTRACT 71.4): a still or animated picture's first frame at full
// size (`AppModel.cropPicture`: the copy on this device, else a download), or a video's frame at the moment (AVFoundation)
// with a strip of frames for the moment picker. The crop box, the squash and the "source" side of the compare line are drawn
// from this; the made file itself always comes from the server.

@MainActor @Observable
final class EmoteSourceLoader {
    enum State: Equatable { case loading, ready, failed }

    private(set) var state: State = .loading
    /// The picture the crop box sits on (a video: the frame at `frameTime`).
    private(set) var image: CGImage?
    /// A video's length in seconds.
    private(set) var duration: Double?
    /// A video's frames, evenly spread, for the moment picker (empty until read).
    private(set) var strip: [CGImage] = []
    private(set) var frameTime: Double = 0

    @ObservationIgnored private var video: FrameSource?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var frameTask: Task<Void, Never>?

    init() {}

    /// A loader that is already done (previews).
    init(preview image: CGImage, duration: Double? = nil, strip: [CGImage] = []) {
        self.image = image
        self.duration = duration
        self.strip = strip
        state = .ready
    }

    var pixels: CGSize? { image.map { CGSize(width: $0.width, height: $0.height) } }

    func load(model: AppModel, rendition: Rendition, source: EmoteSource, at time: Double) async {
        guard state != .ready else { return }
        state = .loading
        do {
            if source.isVideo {
                try await loadVideo(model: model, rendition: rendition, at: time)
            } else {
                image = try await model.cropPicture(of: rendition)
            }
            state = image == nil ? .failed : .ready
        } catch {
            state = .failed
        }
    }

    private func loadVideo(model: AppModel, rendition: Rendition, at time: Double) async throws {
        let source = try await model.frameSource(of: rendition)
        video = source
        let asset = AVURLAsset(url: source.url)
        let length = try await asset.load(.duration).seconds
        duration = length.isFinite && length > 0 ? length : nil
        let made = AVAssetImageGenerator(asset: asset)
        made.appliesPreferredTrackTransform = true
        made.maximumSize = CGSize(width: 1280, height: 1280)
        made.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        made.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator = made
        let first = try await made.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
        image = first
        frameTime = max(0, time)
        await loadStrip(asset: asset, length: duration)
    }

    private func loadStrip(asset: AVAsset, length: Double?) async {
        guard let length, length > 0 else { return }
        let thumbs = AVAssetImageGenerator(asset: asset)
        thumbs.appliesPreferredTrackTransform = true
        thumbs.maximumSize = CGSize(width: 160, height: 160)
        thumbs.requestedTimeToleranceBefore = CMTime(seconds: length / 24, preferredTimescale: 600)
        thumbs.requestedTimeToleranceAfter = CMTime(seconds: length / 24, preferredTimescale: 600)
        let count = 12
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * length / Double(count), preferredTimescale: 600) }
        var arrived: [Int: CGImage] = [:]
        for await result in thumbs.images(for: times) {
            if Task.isCancelled { return }
            guard let index = times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 }),
                let picture = try? result.image
            else { continue }
            arrived[index] = picture
        }
        strip = arrived.keys.sorted().compactMap { arrived[$0] }
    }

    /// A video's frame at `seconds` (the crop stage shows it; the box stays where it is). The newest request wins.
    func showFrame(at seconds: Double) {
        guard let generator else { return }
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            guard let result = try? await generator.image(at: time), !Task.isCancelled else { return }
            self?.image = result.image
            self?.frameTime = seconds
        }
    }

    /// The device's copy of a download goes (a video that was fetched for the editor).
    func discard() {
        frameTask?.cancel()
        video?.discard()
        video = nil
        generator = nil
    }
}

/// The frames of the made draft, played once for every picture of the editor (the stage, the sizes, the chat lines), so seven
/// views do not run seven decoders. A still or a one-frame file is decoded once; Reduce Motion keeps the first frame.
@MainActor @Observable
final class EmotePlayback {
    private(set) var frame: CGImage?
    /// The `draftRevision` this plays; a view uses the draft only while it equals the editor's.
    private(set) var revision = -1
    @ObservationIgnored private var animation: MediaAnimation?
    @ObservationIgnored private var stillTask: Task<Void, Never>?

    func play(data: Data, animated: Bool, revision: Int, reduceMotion: Bool, maxPixel: Int = 512) {
        stop()
        self.revision = revision
        if animated, !reduceMotion {
            animation = MediaAnimation.play(data: data, maxPixel: maxPixel) { [weak self] box in
                self?.frame = box.image
            }
            if animation != nil { return }
        }
        stillTask = Task { [weak self] in
            let image = await Self.firstFrame(of: data, maxPixel: maxPixel)
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            self.frame = image
        }
    }

    func stop() {
        stillTask?.cancel()
        stillTask = nil
        animation?.stop()
        animation = nil
    }

    @concurrent
    nonisolated static func firstFrame(of data: Data, maxPixel: Int) async -> CGImage? {
        MainThreadGuard.assertOffMain()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
