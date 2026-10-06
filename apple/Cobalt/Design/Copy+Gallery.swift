import CobaltKit
import Foundation

/// Copy for photos, galleries and what is made from them (apple/CONTRACT-GALLERY.md section 3; owner interview
/// 2026-10-07). All lowercase, exactly as the contract gives them. Its own file so the lanes that build the screens never
/// edit `Copy.swift`; compiled into the share extension and the widgets too (`Cobalt/Design` is shared).
extension Copy {
    enum Gallery {
        // MARK: counts and names

        /// "10 photos", "2 photos + 2 videos", "1 photo", "2 videos".
        static func count(photos: Int, videos: Int) -> String {
            func part(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            switch (photos, videos) {
            case (_, 0): return part(photos, "photo")
            case (0, _): return part(videos, "video")
            default: return "\(part(photos, "photo")) + \(part(videos, "video"))"
            }
        }
        /// "photo 3 of 10": `i` is 1-based.
        static func itemName(_ kind: String, _ i: Int, of n: Int) -> String { "\(kind) \(i) of \(n)" }
        /// "photo 3" / "video 3" / "gif 3": the item's index (0-based) as the owner counts it.
        static func itemLabel(_ type: MediaType, index: Int) -> String { "\(type == .photo ? "photo" : type.rawValue) \(index + 1)" }
        /// "photo 2", "photos 2 and 3", "photos 2, 3 and 5": indices are 0-based.
        static func photoNames(_ indices: [Int]) -> String {
            let numbers = indices.sorted().map { String($0 + 1) }
            switch numbers.count {
            case 0: return "no photos"
            case 1: return "photo \(numbers[0])"
            default: return "photos \(numbers.dropLast().joined(separator: ", ")) and \(numbers.last!)"
            }
        }

        // MARK: paste: save all first

        static func saving(_ i: Int, of n: Int) -> String { "saving \(i) of \(n)" }
        static let makeFromIt = "make from it", makeFromThisPost = "make from this post…"
        static let slideshowWebp = "slideshow webp", slideshowMp4 = "slideshow mp4", galleryImage = "gallery image"
        static func afterTheSave(_ i: Int, of n: Int) -> String { "after the save · \(i) of \(n)" }
        /// `place`: "Files › On My iPhone › cobalt › <title>" / "~/Movies/cobalt/<title>".
        static func savedTo(_ place: String) -> String { "saved to cobalt · \(place)" }
        static let notInPhotos = "not in Photos: save to photos is in more"
        static func notFetched(_ name: String, kept: Int) -> String { "\(name) couldn't be fetched: the link expired. the other \(kept) are saved." }
        static func tryItemAgain(_ name: String) -> String { "try \(name) again" }
        static let galleryChanged = "the post changed since. open it to pick again."

        // MARK: combine

        static let eachPhoto = "each photo", crossfade = "crossfade", frame = "frame", sound = "sound"
        static let asPosted = "as posted", soundNone = "none", soundOwn = "the videos' own"
        /// `list`: "12.4 s + gif 3.2 s".
        static func videosInFull(_ list: String) -> String { "videos play in full: \(list)" }
        static let tickAtLeastTwo = "tick at least 2", moveEarlier = "move earlier", moveLater = "move later"
        static func summary(length: String, size: String, server: String) -> String { "length \(length) · about \(size) · about \(server) on the server" }
        static func webpTooLong(_ len: String) -> String { "too long for a webp: \(len). webps stop at 60 s; the mp4 can be up to 3:00." }
        static func usePerPhoto(_ s: String) -> String { "use \(s) a photo" }
        static let makeMp4Instead = "make the mp4 instead"
        static func mp4TooLong(_ len: String) -> String { "too long: \(len). the server makes up to 3:00. untick some or shorten the photos." }
        static func videosTooLong(_ len: String) -> String { "the videos add up to \(len). a slideshow can hold 60 s of video; untick one." }
        static let makeWebp = "make the slideshow webp", makeMp4 = "make the video", makeImage = "make the gallery image", makeAnother = "make another"
        /// `what`: "slideshow webp", "video", "gallery image".
        static func making(_ what: String, _ pct: Int) -> String { "making the \(what) · \(pct)%" }
        static func makeFailed(_ what: String) -> String { "couldn't make the \(what) (the server's encoder stopped). the photos are untouched and your settings are kept." }
        static func addedAsTab(_ tab: String) -> String { "added as a tab: \(tab)" }
        /// R8: `what` is "slideshow webp", "slideshow mp4" or "gallery image".
        static func replacesPrevious(_ what: String) -> String { "this replaces the \(what) you made before." }
        static func inFiles(_ path: String) -> String { "in Files: \(path)" }

        // MARK: gallery image

        static let layoutStrip = "strip", layoutGrid2 = "2 across", layoutGrid3 = "3 across", layoutRow = "side by side"
        static func layout(_ layout: GalleryLayout) -> String { layout.label }
        static func imageMeta(_ w: Int, _ h: Int, _ size: String) -> String { "\(w) × \(h) · jpeg · about \(size)" }
        /// `names`: "photos 2 and 3" (`photoNames`); `cell`: the cells' shape, "4:5".
        static func cropped(_ names: String, cell: String) -> String { "\(names) are cropped to fit the \(cell) cells" }
        /// `x`: "2×" (`GalleryCanvas.Cell.upscale`); `name`: "photo 3".
        static func drawnLarger(_ name: String, _ x: String) -> String { "\(name) is drawn \(x) its own pixels: it is alone in its row" }
        static func videosSkipped(_ n: Int) -> String { n == 1 ? "videos aren't in the image: 1 skipped" : "videos aren't in the image: \(n) skipped" }
        static let needsTwoPhotos = "needs 2 photos"
        static func galleryImageTab(_ layout: String) -> String { "gallery image · \(layout)" }   // file: "gallery image · 3 across.jpg"

        // MARK: share sheet

        static func saveAll(_ n: Int) -> String { "save all \(n)" }
        static let intoCobaltAndFiles = "into cobalt and Files"
        static let saveAndWebp = "save + slideshow webp", saveAndImage = "save + gallery image", noBorders = "no borders"
        /// `sec`: "2 s"; `len`: "20 s"; `size`: "1.8 MB".
        static func shareWebpSub(_ sec: String, _ len: String, _ size: String) -> String { "\(sec) a photo · crossfade · about \(len) · about \(size)" }
        static let videosPlayInFull = "videos play in full"
        /// "2 photos · 2 videos skipped".
        static func photosAndSkipped(_ p: Int, _ v: Int) -> String {
            "\(p) \(p == 1 ? "photo" : "photos") · \(v) \(v == 1 ? "video" : "videos") skipped"
        }
        static let saveNow = "save now", checkingLink = "checking the link", sentToCobalt = "sent to cobalt"
        static func wakingServer(_ s: Int) -> String { "waking the server · \(s) s" }
        /// "saving 10 photos to cobalt" / "saving 4 items to cobalt".
        static func savingItems(_ n: Int, photosOnly: Bool) -> String { "saving \(n) \(photosOnly ? (n == 1 ? "photo" : "photos") : (n == 1 ? "item" : "items")) to cobalt" }
        static let andMakingWebp = " · making a slideshow webp", andMakingImage = " · making a gallery image"
        static let savingEverything = "saving everything to cobalt", makeLater = "open cobalt to make something from it"
        static let serverNoGallery = "this server can't save photo posts yet"
        static let serverNoGallerySub = "update the server, or open cobalt to save them to Photos."
        static let serverCantMake = "this server can't make these yet"

        // MARK: detail

        static func photosTab(_ n: Int) -> String { n == 1 ? "photo" : "photos \(n)" }
        static let copyPhotoLink = "copy photo link", copyText = "copy text", saveToPhotos = "save to photos"
        static let selectPhotos = "select photos", saveAllToPhotos = "save all to photos", copyAllLinks = "copy all links"
        static let makeAWebp = "make a webp", deletePhoto = "delete this photo", deleteFile = "delete this file"
        /// `i`: 1-based.
        static func deletePhotoTitle(_ i: Int) -> String { "delete photo \(i) for everyone?" }
        static let deletePhotoMessage = "its public link stops working. the other photos and what you made stay."
        static func publicLinks(_ n: Int) -> String { "public · \(n) links" }
        static let privateNoLinks = "private · no links"

        // MARK: library (unchanged from 2026-10-06)

        static let kindAll = "all", kindVideos = "videos", kindPhotos = "photos", kindGalleries = "galleries", kindWebps = "webps"
        static func galleryKind(_ n: Int) -> String { "gallery · \(n)" }
        static func nothingHere(_ what: String, kept: Bool) -> String { "no \(what)\(kept ? " kept on this \(Copy.device)" : "") yet." }

        // MARK: repost tools (unchanged from 2026-10-06; wave A7)

        static let crop = "crop", saveCrop = "save crop", keepInCobalt = "keep in cobalt", deleteCrop = "delete this crop"
        static let fillCut = "cut to fit", fillBlur = "whole photo, blurred bars", fillBlurShort = "blurred bars"
        static func cropTab(_ aspect: String) -> String { "crop \(aspect)" }
        static let cropFailed = "couldn't upload the crop. the photo is unchanged."
        static let repostFrame = "repost frame", saveThisOne = "save this one"
        static func saveAllFrames(_ n: Int) -> String { "all \(n)" }
        static func videosSkippedFrames(_ n: Int) -> String { n == 1 ? "1 video skipped" : "\(n) videos skipped" }

        // MARK: numbers the sheets show (the boards' `GM.fmt` and `GM.size`)

        /// 0.5 s steps and short lengths read "2.0 s"; a minute or more reads "1:12".
        static func length(_ seconds: Double) -> String {
            if seconds >= 60 {
                var m = Int(seconds / 60)
                var r = Int((seconds - Double(m) * 60).rounded())
                if r == 60 { m += 1; r = 0 }
                return "\(m):\(r < 10 ? "0" : "")\(r)"
            }
            return String(format: "%.1f s", (seconds * 10).rounded() / 10)
        }
        /// "1.8 MB" / "420 KB".
        static func size(_ bytes: Int64) -> String { Format.bytes(bytes) }
        /// "2×" / "1.1×": `GalleryCanvas.Cell.upscale`.
        static func times(_ x: Double) -> String { x == x.rounded() ? "\(Int(x))×" : String(format: "%.1f×", x) }
        /// "4:5": the shape of the cells of a grid canvas, from its first cell.
        static func shape(_ size: CGSize) -> String {
            let w = Int(size.width.rounded()), h = Int(size.height.rounded())
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
            let g = max(1, gcd(w, h))
            let (a, b) = (w / g, h / g)
            return a > 30 || b > 30 ? String(format: "%.2g:1", Double(w) / Double(max(h, 1))) : "\(a):\(b)"
        }
    }
}
