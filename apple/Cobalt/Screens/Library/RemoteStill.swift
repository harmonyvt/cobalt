import AVFoundation
import CobaltKit
import ImageIO
import SwiftUI

/// What a library card borrows its poster from when the media has no poster on this device: the face's public
/// animated webp (its first frame) or the hosted mp4 (a frame from the start), both from the server's
/// public media bucket. Private-only media have neither, and keep their placeholder.
struct RemotePoster: Equatable, Sendable {
    let url: URL
    let isVideo: Bool

    init(url: URL, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
    }
}

/// First frames of public media, decoded off the main thread at thumbnail size and cached (bounded:
/// 64 of them), one request per URL at a time.
actor RemoteStillLoader {
    static let shared = RemoteStillLoader()
    private let cache: NSCache<NSURL, Holder> = {
        let c = NSCache<NSURL, Holder>()
        c.countLimit = 64
        return c
    }()
    private var inFlight: [URL: Task<ImageBox?, Never>] = [:]

    private final class Holder: Sendable {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    func image(for poster: RemotePoster, maxPixel: Int = 360) async -> ImageBox? {
        let key = Self.resolve(poster.url)
        if let hit = cache.object(forKey: key as NSURL) { return hit.box }
        if let running = inFlight[key] { return await running.value }
        let isVideo = poster.isVideo
        let task = Task<ImageBox?, Never> {
            isVideo ? await Self.videoFrame(key, maxPixel: maxPixel) : await Self.imageFrame(key, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let box = await task.value
        inFlight[key] = nil
        if let box { cache.setObject(Holder(box), forKey: key as NSURL) }
        return box
    }

    private static func imageFrame(_ url: URL, maxPixel: Int) async -> ImageBox? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ImageBox.init)
    }

    private static func videoFrame(_ url: URL, maxPixel: Int) async -> ImageBox? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
        return ImageBox(image)
    }

    /// `-previewMediaDir /some/folder` (DEBUG) reads the public media from a local folder instead of the
    /// network, so the simulator evidence run shows real posters without the server.
    private static func resolve(_ url: URL) -> URL {
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "previewMediaDir"), !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent)
        }
        #endif
        return url
    }
}

/// A poster from the network, filling its frame. Blank until decoded, and blank when it cannot be.
struct RemoteStill: View {
    let poster: RemotePoster
    @State private var image: ImageBox?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.25), value: image != nil)
            .task(id: poster) { image = await RemoteStillLoader.shared.image(for: poster) }
    }
}
