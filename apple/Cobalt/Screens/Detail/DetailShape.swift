import CobaltKit
import Foundation

// What kind of detail a media gets, and the pieces the gallery detail is built from (apple/CONTRACT-GALLERY.md 1.18-1.20;
// owner decision 3: kind tabs + a pager with a thumbnail strip). Pure functions of a `MediaItem`, so the previews and the
// tests read the same answer the screens do.

/// `classic`: a video and its webps, exactly today's tabs. `photo`: one photo (or one item) and what was made from it, the
/// same screen without the strip. `gallery`: two or more items: kind tabs, a pager, a thumbnail strip.
enum DetailShape: Equatable {
    case classic, photo, gallery
}

/// One page of the pager: an item of the post by its place in the post, or a hole where an item was never saved.
struct GalleryPage: Identifiable, Equatable {
    /// The item's place in the post (0-based): `photo 7` is index 6, and it is the file name `07.jpg`.
    let index: Int
    /// Nil: the item could not be fetched (the post's `items_failed`); the page offers `try photo 7 again`.
    let rendition: Rendition?

    var id: Int { index }
    var isMissing: Bool { rendition == nil }
}

/// One tab above the hero. Classic media tab by rendition id; a gallery has ONE `items` tab for every photo (the pager's
/// pages) and one tab per file made from it.
struct DetailTabEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
}

enum DetailTab {
    /// The tab that holds the pager (a gallery's photos, a single photo).
    static let items = "items"
}

extension Rendition {
    /// A picture that is a still, not a clip: a photo item, a gallery image, a crop, or an older single photo stored as the
    /// media's `video` (a direct image link). The hero shows these with the photo viewer, never the player.
    var isStillPicture: Bool {
        switch kind {
        case .item(_, let type): return type == .photo
        case .galleryImage, .crop: return true
        case .video:
            if let ext = local?.fileURL?.pathExtension.lowercased() ?? local?.name.split(separator: ".").last.map({ $0.lowercased() }),
               Self.stillExtensions.contains(ext) { return true }
            return file?.contentType?.lowercased().hasPrefix("image/") == true && file?.contentType?.lowercased() != "image/gif"
        default: return false
        }
    }

    private static let stillExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    /// A gif item: an animated picture the hero plays like a webp (a clip of its own, never a photo).
    var isGifItem: Bool { itemType == .gif }

    /// A video or gif item of a gallery: has a length, a player and a `make a webp`.
    var isMotionItem: Bool {
        guard let type = itemType else { return false }
        return type != .photo
    }

    /// `photo 3`, `video 3`, `gif 3` for an item; the tab's words for anything else.
    var itemLabel: String? {
        guard case .item(let index, let type) = kind else { return nil }
        return Copy.Gallery.itemLabel(type, index: index)
    }
}

extension MediaItem {
    var detailShape: DetailShape {
        let pieces = items.count + missing.count
        if pieces >= 2 { return .gallery }
        if pieces == 1 { return .photo }
        if let video, video.isStillPicture { return .photo }
        return .classic
    }

    /// The pager's pages, in the post's order: every live item and every item that could not be fetched. An older single
    /// photo stored as the media's `video` is one page.
    var galleryPages: [GalleryPage] {
        var pages = items.compactMap { r in r.itemIndex.map { GalleryPage(index: $0, rendition: r) } }
        pages += missing.map { GalleryPage(index: $0, rendition: nil) }
        if pages.isEmpty, let video, video.isStillPicture { return [GalleryPage(index: 0, rendition: video)] }
        return pages.sorted { $0.index < $1.index }
    }

    /// The `of N` of `photo 3 of 10`: the post's size as it was saved (a deleted photo leaves a gap in the numbers, never
    /// renumbers them: the file `07.jpg` stays photo 7).
    var galleryTotal: Int {
        let pages = galleryPages
        return max(pages.count, (pages.map(\.index).max() ?? -1) + 1)
    }

    /// Photos only (no video or gif item).
    var itemsArePhotos: Bool { galleryPages.allSatisfy { $0.rendition?.itemType.map { $0 == .photo } ?? true } }

    /// The tab that holds the pager: `photo` for one, `photos 10` for a gallery of photos, `items 4` when a video or a gif
    /// is in the post.
    var itemsTabName: String {
        let pages = galleryPages
        if detailShape == .photo { return pages.first?.rendition?.itemType.map { $0 == .photo ? "photo" : $0.rawValue } ?? "photo" }
        return itemsArePhotos ? Copy.Gallery.photosTab(pages.count) : DetailWords.itemsTab(pages.count)
    }

    /// The tabs above the hero. Classic: one per rendition, as always. Gallery and photo: `items` first, then every file
    /// made from the post and every webp of one of its videos (CONTRACT-GALLERY 1.19), never an item.
    var detailTabs: [DetailTabEntry] {
        guard detailShape != .classic else {
            return renditions.map { DetailTabEntry(id: $0.id, name: $0.tabName(of: self), symbol: $0.tabSymbol) }
        }
        let pageIDs = Set(galleryPages.compactMap { $0.rendition?.id })
        var tabs = [DetailTabEntry(
            id: DetailTab.items, name: itemsTabName,
            symbol: detailShape == .gallery ? Symbol.Gallery.gallery : Symbol.Gallery.photo)]
        for r in renditions where !r.isItem && !pageIDs.contains(r.id) {
            tabs.append(DetailTabEntry(id: r.id, name: r.tabName(of: self), symbol: r.tabSymbol))
        }
        return tabs
    }
}
