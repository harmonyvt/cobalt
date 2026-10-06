import CobaltKit
import ImageIO
import SwiftUI

/// The photo a tool works on, as the sheet draws it: decoded once for display (the picture the owner sees, rotated upright,
/// at most 1600 px on the long side) and its true size in pixels, which the frame's numbers are about. The tools draw the
/// real frame from the file again, at full size, with `FrameRenderer`; this is only the preview.
@MainActor @Observable
final class ToolPhoto {
    enum State: Equatable { case loading, ready, failed }

    let rendition: Rendition
    private(set) var state: State = .loading
    private(set) var image: CGImage?
    /// The photo's size in pixels, as the owner sees it.
    private(set) var pixels: CGSize = .zero

    init(_ rendition: Rendition) {
        self.rendition = rendition
    }

    /// A photo that is already decoded (previews).
    init(_ rendition: Rendition, image: CGImage, pixels: CGSize) {
        self.rendition = rendition
        self.image = image
        self.pixels = pixels
        self.state = .ready
    }

    /// The photo's shape (width over height).
    var aspect: CGFloat { pixels.height > 0 ? pixels.width / pixels.height : 1 }

    func load(model: AppModel) async {
        guard state != .ready else { return }
        state = .loading
        do {
            let source = try await model.frameSource(of: rendition)
            defer { source.discard() }
            guard let size = FrameRenderer.sourceSize(of: source.url),
                  let box = await PhotoDecoder.shared.image(at: source.url, maxPixel: 1600)
            else {
                state = .failed
                return
            }
            pixels = size
            image = box.image
            state = .ready
        } catch {
            state = .failed
        }
    }
}

/// Where the repost tools take their pictures from: a gallery's photos and an older single photo (stored as the media's
/// `video`). Pure, so the menu, the sheets and the previews agree.
enum ToolPhotos {
    /// A photo the tools can draw from: a still the device holds or the library lists. Not a crop or a gallery image (a
    /// frame of a frame is made from the original), not a video or a gif.
    static func isSource(_ r: Rendition) -> Bool {
        switch r.kind {
        case .item(_, let type): return type == .photo && (r.hasFileHere || r.file != nil)
        case .video: return r.isStillPicture && (r.hasFileHere || r.file != nil)
        default: return false
        }
    }

    /// Every photo of the media, in the post's order.
    static func photos(of item: MediaItem) -> [Rendition] {
        let items = item.items.filter(isSource)
        if !items.isEmpty { return items }
        if let video = item.video, isSource(video) { return [video] }
        return []
    }

    /// Videos and gifs of the post: left out of a repost, counted.
    static func skipped(in item: MediaItem) -> Int {
        item.items.filter { $0.isMotionItem }.count
    }
}
