import CobaltKit
import Foundation

/// The few words the gallery detail needs that `Copy.Gallery` (lane A0's file) does not have. Lowercase like the rest, kept
/// beside the screens that draw them so no shared copy file is edited. Contract strings stay in `Copy.Gallery`.
enum DetailWords {
    // MARK: tabs and names

    /// The pager's tab when the post holds a video or a gif: `items 4`.
    static func itemsTab(_ n: Int) -> String { "items \(n)" }
    static let photo = "photo"

    // MARK: buttons

    static let copyGifLink = "copy gif link"
    static let copyImageLink = "copy image link"
    static let copyLink = "copy link"
    static let copyPhotoLink = Copy.Gallery.copyPhotoLink
    static let makeFromPost = Copy.Gallery.makeFromThisPost
    /// The selection bar's save button, and the menu's `save all`: Photos on iPhone and iPad; the Mac has no Photos sync, so it
    /// saves into a folder the owner picks.
    static var toPhotos: String {
        #if os(macOS)
        return "save…"
        #else
        return "to photos"
        #endif
    }
    static var saveAllTitle: String {
        #if os(macOS)
        return "save all to a folder…"
        #else
        return Copy.Gallery.saveAllToPhotos
        #endif
    }
    static let doneSelecting = "done"
    static func selected(_ n: Int) -> String { n == 0 ? "tick photos" : "\(n) selected" }
    static func deleteN(_ n: Int) -> String { "delete \(n)" }

    // MARK: states

    static func fetching(_ name: String) -> String { "fetching \(name)…" }
    static let fetchedAfter = "fetching again. it joins this post when it lands."
    /// A made file still being switched, with how many links the post has now.
    static func partialSwitch(on: Bool) -> String {
        on ? "some of the links are on, some aren't. turn it on again to finish." : "some of the links are off, some aren't. turn it off again to finish."
    }
    static let noLinks = "no public links: the post is private."
    static func copiedLinks(_ n: Int) -> String { n == 1 ? "copied 1 link." : "copied \(n) links." }
    static let copiedText = "copied the text."
    static let noText = "no text found in this photo."
    static let readingText = "reading the text…"
    static func savedToPhotos(_ n: Int) -> String { n == 1 ? "saved to Photos." : "saved \(n) to Photos." }
    static func savedToFolder(_ n: Int) -> String { n == 1 ? "saved." : "saved \(n) files." }
    static let notOnThisDevice = "not on this \(Copy.device) yet. keep it offline first, or turn on the link to share it."
    static let postBusy = "still working on this post. try again when it's done."
    static let lastPhoto = "that is the last photo. use delete everything instead."
    static let cantMakeWebp = "can't make a webp from this one: the post is not open on the server any more."
    static let noPhotoFile = "this photo is not on this \(Copy.device)."

    /// The made file's meta: how many photos went into it.
    static func fromPhotos(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n) photos" }

    // MARK: confirms

    static func deletePhotosTitle(_ n: Int) -> String { n == 1 ? "delete 1 photo for everyone?" : "delete \(n) photos for everyone?" }
    static let deleteMadeTitle = "delete this file for everyone?"
    static let deleteMadeMessage = "its public link stops working. the photos and the other things you made stay."
    static func removeGalleryMessage(items: Int, made: Int) -> String {
        var what = items == 1 ? "the photo" : "its \(items) photos"
        if made > 0 { what += made == 1 ? " and what you made" : " and the \(made) things you made" }
        return "\(what) leave this \(Copy.device). your library and public links keep them."
    }
    static func deleteEverythingMessage(items: Int, made: Int) -> String {
        var parts = [items == 1 ? "the photo" : "the \(items) photos"]
        if made > 0 { parts.append(made == 1 ? "what you made" : "the \(made) things you made") }
        parts.append("every public link")
        let list = parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "\(list) are deleted for everyone. links you shared stop working. this can't be undone."
    }

    // MARK: the make row

    static let makeSubtitle = "a slideshow webp, a slideshow mp4 or a gallery image from these photos."
    static let makeExpired = "the server keeps a post's originals for 7 days. this one is over."
    static let makeNeedsTwo = "a post needs 2 items to make something from."
}
