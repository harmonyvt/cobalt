import CobaltKit
import SwiftUI

/// The two repost tools, as a sheet the detail's `more` menu opens (apple/CONTRACT-GALLERY.md 1.19-1.20, 1.23-1.24):
/// `crop…` on the photo in view, `repost frame…` for the post's photos (starting on the one in view).
enum ToolSheet: Identifiable {
    case crop(Rendition, initial: FrameSpec?)
    case repost(start: Rendition?, initial: FrameSpec?)

    var id: String {
        switch self {
        case .crop(let r, _): return "crop:\(r.id)"
        case .repost: return "repost"
        }
    }

    // MARK: what the menu offers

    /// `crop…` is on a photo that can be drawn from (an item, or an older single photo), never on a clip, a crop, or a page that
    /// was never saved.
    static func canCrop(_ rendition: Rendition?) -> Bool {
        rendition.map(ToolPhotos.isSource) ?? false
    }

    /// `repost frame…` is on a media with at least one photo.
    static func canRepost(_ item: MediaItem) -> Bool {
        !ToolPhotos.photos(of: item).isEmpty
    }
}

/// The content of the sheet: the crop's, or the repost frame's, over the live model. `done` is told when the work ends the sheet
/// (a crop that became a tab: nil; a picture sent to Photos: the line to say).
struct ToolSheetContent: View {
    let model: AppModel
    let item: MediaItem
    let sheet: ToolSheet
    var done: (String?) -> Void

    var body: some View {
        switch sheet {
        case .crop(let rendition, let initial):
            CropSheet(model: model, item: item, rendition: rendition, initial: initial, done: done)
        case .repost(let start, let initial):
            RepostSheet(model: model, item: item, start: start, initial: initial, done: done)
        }
    }
}

extension View {
    /// Presents the tool sheet that `sheet` names; on the Mac it is a sheet of its own size.
    func toolSheet(_ sheet: Binding<ToolSheet?>, model: AppModel, item: MediaItem, done: @escaping (String?) -> Void) -> some View {
        self.sheet(item: sheet) { current in
            ToolSheetContent(model: model, item: item, sheet: current, done: done)
        }
    }
}
