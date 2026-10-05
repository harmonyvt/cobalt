#if DEBUG
import AVFoundation
import CobaltKit
import CoreGraphics
import Foundation

/// `-previewClip <path>` (simulator evidence, debug builds only): the preview pipeline "downloads" a
/// 70-byte placeholder, so nothing on the orbit has pictures or motion. With a real clip given, every
/// placeholder file the store holds is replaced by that clip (the preview run saves it well before the
/// focus layer needs it), and the poster of a run is that clip's first frame instead of a grey gradient.
@MainActor
enum PreviewClip {
    static let url: URL? = UserDefaults.standard.string(forKey: "previewClip")
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    static let webpURL: URL? = UserDefaults.standard.string(forKey: "previewWebp")
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    /// The clip's first frame, standing in for the pipeline's grey preview frames.
    static let poster: CGImage? = {
        guard let url else { return nil }
        // the first frame of the file, decoded once at launch (a one-off debug read, so a short wait is fine)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var image: CGImage?
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, _, _ in
            image = cg
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return image
    }()

    /// The preview pipeline never keeps the original (`isPreview`), so a focused planet would have no video
    /// to play and nothing to hand to the orbit. With a clip given, the clip is stored as the run's original
    /// as soon as the run has a session, the way "keep videos on device" does in the real app (in the
    /// background, well before the planet is ready); any 70-byte placeholder in the store is swapped too.
    /// With `-previewWebp <path>` too, the placeholder the preview "download" leaves for a finished webp is
    /// swapped for that animated file (as soon as the store holds it), so the video-to-webp swap shows a
    /// picture that moves instead of one grey pixel.
    static func runIfRequested(_ model: AppModel) {
        guard let clip = url else { return }
        Task { @MainActor in
            let fm = FileManager.default
            var kept: Set<String> = []
            var swapped: Set<String> = []
            while !Task.isCancelled {
                for video in model.store.videos where !swapped.contains(video.id) {
                    guard let file = video.fileURL,
                          let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int, size > 0
                    else { continue }
                    swapped.insert(video.id)      // each file is looked at once (the loop runs every 5 ms)
                    guard size < 4_096, video.kind == .original || (video.kind == .webp && webpURL != nil) else { continue }
                    try? fm.removeItem(at: file)
                    try? fm.copyItem(at: video.kind == .webp ? (webpURL ?? clip) : clip, to: file)
                }
                if let sid = model.pipeline.sessionID, !kept.contains(sid),
                   let media = model.pipeline.media {
                    kept.insert(sid)
                    _ = try? await model.store.add(
                        file: clip, kind: .original, media: media, sessionID: sid, link: nil, remoteURL: nil, move: false)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}
#endif
