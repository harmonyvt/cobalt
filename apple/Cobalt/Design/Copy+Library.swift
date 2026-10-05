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
        static let sortResolution = "resolution", sortFiles = "files", sortPublic = "public"
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
        static let colPublic = "public", colDate = "date"
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

        // context menu
        static let open = "open"
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
        }
    }

    /// The show filter's word.
    static func name(_ show: LibraryShow) -> String {
        switch show {
        case .everything: return showEverything
        case .publicOnly: return showPublic
        case .privateOnly: return showPrivate
        case .uploads: return showUploads
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
