import CobaltKit
import Foundation

/// Copy for the library's two views (CONTRACT-LIBRARY2 section 3): mosaic and table, sort and show, search,
/// the table's columns, the context menu and the rename alert. All lowercase. Its own file so the lanes that
/// build the screens never edit `Copy.swift`; compiled into the share extension and the widgets too
/// (`Cobalt/Design` is shared).
extension Copy {
    enum Library2 {
        // views, sort, show, search
        static let mosaic = "mosaic"
        static let table = "table"
        static let view = "view"                                   // switcher a11y label
        static let sort = "sort"
        static let show = "show"
        static let sortDate = "date", sortTitle = "title", sortLength = "length", sortSize = "size"
        static let sortResolution = "resolution", sortFiles = "files", sortPublic = "public", sortKind = "kind"
        static let newestFirst = "newest first", oldestFirst = "oldest first"   // a11y values for date
        static let ascending = "ascending", descending = "descending"           // a11y values otherwise
        static let showEverything = "everything", showPublic = "public", showPrivate = "private"
        static let showUploads = "uploaded files"
        static let searchPrompt = "search titles"
        static func noMatch(_ q: String) -> String { "nothing matches \"\(q)\"." }
        static func loadingAll(_ n: Int, of total: Int) -> String { "loading the whole library · \(n) of \(total)" }
        static let loadMoreFailed = "couldn't load more."
        static let notFound = "couldn't find that in the library."
        static let pickSomething = "pick something to see it here."
        static let pictureFailed = "picture didn't load"                       // VoiceOver value
        static let refresh = "refresh library"                                 // Mac menu, ⌘R
        static let asMosaic = "as mosaic", asTable = "as table"                // Mac view menu
        static let toggleDetail = "show or hide the detail"                    // inspector button a11y

        // table columns and cells
        static let colTitle = "title", colService = "service", colLength = "length"
        static let colResolution = "resolution", colFiles = "files", colSize = "size"
        static let colPublic = "public", colDate = "date", colKind = "kind"
        static let serviceFile = "file"                                        // service cell of an upload
        static let isPublic = "public", isPrivate = "private"
        enum Original { case video, image }                                   // an uploaded png/jpg/heic/gif/webp is an image
        static func files(original: Original?, webps: Int) -> String {         // "video + webp ×3", "image", "webp ×2"
            let w = webps > 0 ? Copy.Media.webpCount(webps) : nil
            let o = original.map { $0 == .video ? "video" : "image" }
            switch (o, w) {
            case (let o?, let w?): return "\(o) + \(w)"
            case (let o?, nil): return o
            case (nil, let w?): return w
            case (nil, nil): return "—"
            }
        }

        /// "10 photos", "2 photos + 2 videos", "10 photos + 2 made", "photo", "photo + 1 made": a gallery's or photo's `files`
        /// cell (items first, then what was made from them).
        static func photoFiles(photos: Int, videos: Int, made: Int) -> String {
            let items = photos + videos
            var out = items <= 1 && videos == 0 ? "photo" : Copy.Gallery.count(photos: photos, videos: videos)
            if made > 0 { out += " + \(made) made" }
            return out
        }

        // kind (apple/CONTRACT-GALLERY.md 1.21; board `Library-Mixed`)
        static let kindFilter = "kind"                                         // the menu section and the chips' a11y label
        static let showEverythingAgain = "show everything"                     // the way out of an empty kind
        static func name(_ kind: LibraryKindFilter) -> String {
            switch kind {
            case .all: return Copy.Gallery.kindAll
            case .videos: return Copy.Gallery.kindVideos
            case .photos: return Copy.Gallery.kindPhotos
            case .galleries: return Copy.Gallery.kindGalleries
            case .webps: return Copy.Gallery.kindWebps
            }
        }
        /// A chip's text: `galleries 3`; the bare word while the whole library is not loaded yet (a count of a page would lie).
        static func chip(_ kind: LibraryKindFilter, count: Int?) -> String {
            count.map { "\(name(kind)) \($0)" } ?? name(kind)
        }
        /// What one media is, in the kind column and the second line: `gallery · 10`, `photo`, `video`, `webp`.
        static func kindWord(_ kind: MediaKind, items: Int) -> String {
            switch kind {
            case .gallery: return Copy.Gallery.galleryKind(items)
            case .photo: return "photo"
            case .video: return "video"
            case .webp: return "webp"
            }
        }
        /// "no galleries yet." / "no photos kept on this iphone yet.": a kind with nothing in it (the filter's own empty state).
        static func nothingOfKind(_ kind: LibraryKindFilter, kept: Bool) -> String {
            Copy.Gallery.nothingHere(kind == .all ? "saves" : name(kind), kept: kept)
        }
        /// VoiceOver on a tile or row of a photo or a gallery.
        static func openPhoto(_ title: String) -> String { "open \(title), photo" }
        static func openGallery(_ title: String, items: String) -> String { "open \(title), gallery, \(items)" }

        // context menu
        static let open = "open"
        static let copyPhotoLink = Copy.Gallery.copyPhotoLink
        static let copyAllLinks = Copy.Gallery.copyAllLinks
        static let saveAllToPhotos = Copy.Gallery.saveAllToPhotos
        static let makeFromPost = Copy.Gallery.makeFromThisPost
        static func copiedLinks(_ n: Int) -> String { "copied \(n) \(n == 1 ? "link" : "links")." }
        static let noPublicLinks = "no public links yet. make it public first."
        /// The confirm of `delete everything…` for a photo or a gallery (the message of Copy.Media's is about a video).
        static func deleteGalleryMessage(items: Int, made: Int) -> String {
            var parts = [items == 1 ? "the photo" : "the \(items) items"]
            if made > 0 { parts.append(made == 1 ? "the file you made" : "the \(made) files you made") }
            let list = parts.joined(separator: " and ")
            return "\(list) \(parts.count > 1 || items > 1 ? "are" : "is") deleted for everyone. links you shared stop working. this can't be undone."
        }
        static let copyWebpLink = "copy webp link"
        static let copyVideoLink = "copy video link"
        static let share = "share"
        static let saveToPhotos = "save to photos"
        static let rename = "rename"
        static let deleteEverything = "delete everything…"                    // confirm: Copy.Media (CONTRACT-MEDIA 3)
        static let makePublic = "make public"                                  // the video's switch (CONTRACT-VISIBILITY 6.2)
        static let makePrivate = "make private…"                               // asks first: Copy.Media.makePrivateTitle
        static let nowPublic = "public now."
        static let nowPrivate = "private now."
        static let makingPublic = "making the link…"
        static let publicBadgeA11y = "public link"                              // VoiceOver on a tile's globe
        static let privateBadgeA11y = "private"                                 // ... and its lock

        // titles
        static let nameIt = "name it"
        static let titleField = "title"                                       // field a11y label
        static let done = "done"
        static let skip = "skip"
        static func titleCount(_ n: Int) -> String { "\(n) of 80" }           // shown from 60 code points
        static let renameTitle = "rename"
        static func renameMessage(default d: String) -> String { "leave it empty to use \"\(d)\"." }
        static let renameLocalOnly = "only on this iphone until the server is updated."
        static let save = "save"
        static let cancel = "cancel"
        static let renameFailed = "couldn't rename that. try again."
    }
}

extension Copy.Library2 {
    /// A sort key's word in the sort menu and the table's header.
    static func name(_ key: LibrarySortKey) -> String {
        switch key {
        case .date: return sortDate
        case .title: return sortTitle
        case .length: return sortLength
        case .size: return sortSize
        case .resolution: return sortResolution
        case .files: return sortFiles
        case .visibility: return sortPublic
        case .offline: return Copy.Offline.column
        case .kind: return sortKind
        }
    }

    /// The show filter's word.
    static func name(_ show: LibraryShow) -> String {
        switch show {
        case .everything: return showEverything
        case .publicOnly: return showPublic
        case .privateOnly: return showPrivate
        case .uploads: return showUploads
        case .offline: return Copy.Offline.filter
        }
    }

    /// VoiceOver's value for the current sort: "newest first", "oldest first", "ascending", "descending".
    static func direction(_ sort: LibrarySort) -> String {
        if sort.key == .date { return sort.ascending ? oldestFirst : newestFirst }
        return sort.ascending ? ascending : descending
    }

    /// The mosaic and table switcher's segment names.
    static func name(_ mode: LibraryViewMode) -> String {
        mode == .mosaic ? mosaic : table
    }
}
