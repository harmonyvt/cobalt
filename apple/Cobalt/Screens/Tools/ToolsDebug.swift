#if DEBUG
import CobaltKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The repost tools' launch flags (simulator evidence, debug builds only). The detail itself is opened as for any media
/// (`-previewDetail N`, `-previewOpenFirst YES`, or the owner's tap on the planet); these put a tool in a state:
///
///   -previewTool crop|cropFree|cropCut|repost|repostCut   open that tool when the detail's menu appears (once): `crop` is 9:16 on
///                                  blurred bars, `cropCut` a cut at 4:5, `cropFree` a free crop, `repost` 9:16 on blurred
///                                  bars, `repostCut` 1:1 cut to fit
///   -previewToolPhoto <path>       write that picture over the file of every kept photo of the media first (the preview
///                                  server's files are placeholders, not pictures)
///   -previewToolPage N             the photo (0-based place in the post) the tool opens on
///   -previewToolSave 1             press the sheet's own save button a moment after it opens (`save crop`, `save this one`);
///                                  with `galleryMakeFails` the first crop upload fails (the stay-in-crop-mode state)
///   -previewToolMove 1             a cut's rectangle is nudged off the middle, so the dimmed edges show
@MainActor
enum ToolsDebug {
    private static let defaults = UserDefaults.standard
    private static var opened = false

    /// The sheet the flags ask for, once.
    static func launch(for item: MediaItem) -> ToolSheet? {
        guard !opened, let raw = defaults.string(forKey: "previewTool") else { return nil }
        let page = defaults.string(forKey: "previewToolPage").flatMap(Int.init)
        let photos = ToolPhotos.photos(of: item)
        let rendition = photos.first { $0.itemIndex == page } ?? photos.first
        let sheet: ToolSheet?
        switch raw {
        case "crop": sheet = rendition.map { .crop($0, initial: FrameSpec(aspect: .story, fill: .blur)) }
        case "cropFree": sheet = rendition.map { .crop($0, initial: FrameSpec(aspect: .free, fill: .cut)) }
        case "cropCut": sheet = rendition.map { .crop($0, initial: FrameSpec(aspect: .portrait, fill: .cut)) }
        case "repost": sheet = .repost(start: rendition, initial: FrameSpec(aspect: .story, fill: .blur))
        case "repostCut": sheet = .repost(start: rendition, initial: FrameSpec(aspect: .square, fill: .cut))
        default: sheet = nil
        }
        opened = sheet != nil
        return sheet
    }

    /// `-previewToolPhoto`: a real picture behind every kept photo of the media.
    static func seedPhotos(of item: MediaItem) {
        guard let path = defaults.string(forKey: "previewToolPhoto"), let data = FileManager.default.contents(atPath: path) else { return }
        for r in item.items {
            if let url = r.local?.fileURL { try? data.write(to: url) }
        }
        if item.items.isEmpty, let url = item.video?.local?.fileURL { try? data.write(to: url) }
    }

    /// The crop sheet: nudge the rectangle, and press `save crop` when asked.
    static func apply(to crop: FrameCropModel, save: @MainActor (FrameCropModel) -> Void) async {
        if defaults.bool(forKey: "previewToolMove"), crop.cuts {
            crop.drag(.move, from: crop.rect, by: CGSize(width: crop.source.width * 0.12, height: crop.source.height * 0.08))
            crop.drag(.corner(.bottomRight), from: crop.rect, by: CGSize(width: -crop.source.width * 0.05, height: 0))
        }
        guard defaults.bool(forKey: "previewToolSave") else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        save(crop)
    }

    /// The repost sheet: press `save this one` when asked.
    static func apply(to draft: RepostSheet.Draft, save: @MainActor () -> Void) async {
        guard defaults.bool(forKey: "previewToolSave") else { return }
        try? await Task.sleep(for: .milliseconds(2500))
        save()
    }
}
#endif
