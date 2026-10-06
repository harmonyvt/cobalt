import Foundation

/// One tab of a media's detail screen (CONTRACT-MEDIA 1.9): the video, or one of its webps.
public struct Rendition: Sendable, Equatable, Identifiable {
    /// `video`: the media's original (a video, or a single photo). `item`: one original of a gallery. `webp`: a webp of a
    /// video (`number`: 1-based, creation order). `slideshow`, `galleryImage` and `crop`: files made from a gallery
    /// (apple/CONTRACT-GALLERY.md 1.19); `number` is 1 unless an older server left several of one kind (R8 keeps one).
    public enum Kind: Sendable, Equatable {
        case video
        case webp(number: Int)
        case item(index: Int, type: MediaType)
        case slideshow(number: Int, format: SlideshowPlan.Format)
        case galleryImage(layout: GalleryLayout, number: Int)
        /// A crop of item `of` (A7). `spec` is what the server stored (`aspect`, `fill`); the typed `FrameSpec` arrives with the tools wave.
        case crop(of: Int, spec: MadeSpec?)
    }

    public var id: String               // "video", else the local record id, else "f:<library file id>"
    public var kind: Kind
    public var local: StoredVideo?      // the device's record (kept or evicted)
    public var file: LibraryFile?       // .webp: its public file; .video: the private copy
    public var hosted: LibraryFile?     // .video only: the hosted mp4 link
    public var publicURL: URL?          // the webp's url, or the video's public link
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var bytes: Int64?
    public var createdAt: Date
    public var clip: WebpClip?
    public var deletableName: String?   // the server's media_name when `DELETE /media/<name>` takes it
    /// The server's poster (CONTRACT-LIBRARY2 decision 19): a webp's file poster (none today); the video's
    /// hosted link's, else its private copy's. Nil when the server sends none.
    public var posterURL: URL?
    /// Whether this rendition has a public link (CONTRACT-VISIBILITY 6.1). `.video`: the server original's
    /// visibility when the library lists it; `.public` when only a hosted link or a link this device recorded
    /// is known; nil when only this device has it. `.webp`: the file's, else `.public` for a link, nil with none.
    public var visibility: Visibility?
    /// The server takes `PATCH …/visibility` for this rendition: its file says `visibility_toggle`.
    public var canToggleVisibility: Bool

    public init(
        id: String, kind: Kind, local: StoredVideo? = nil, file: LibraryFile? = nil, hosted: LibraryFile? = nil,
        publicURL: URL? = nil, width: Int? = nil, height: Int? = nil, duration: Double? = nil, bytes: Int64? = nil,
        createdAt: Date, clip: WebpClip? = nil, deletableName: String? = nil, posterURL: URL? = nil,
        visibility: Visibility? = nil, canToggleVisibility: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.local = local
        self.file = file
        self.hosted = hosted
        self.publicURL = publicURL
        self.width = width
        self.height = height
        self.duration = duration
        self.bytes = bytes
        self.createdAt = createdAt
        self.clip = clip
        self.deletableName = deletableName
        self.posterURL = posterURL
        self.visibility = visibility
        self.canToggleVisibility = canToggleVisibility
    }

    /// The link is public right now.
    public var isPublic: Bool { visibility == .public }

    /// An animated webp of a video (a tab of `webp n`). A slideshow webp is a made file (`isMade`), not this.
    public var isWebp: Bool {
        if case .webp = kind { return true }
        return false
    }

    /// 1-based creation order of a webp; nil for the video.
    public var webpNumber: Int? {
        if case .webp(let n) = kind { return n }
        return nil
    }

    /// A gallery's item (`index` is its place in the post).
    public var isItem: Bool {
        if case .item = kind { return true }
        return false
    }

    public var itemIndex: Int? {
        if case .item(let index, _) = kind { return index }
        return nil
    }

    public var itemType: MediaType? {
        if case .item(_, let type) = kind { return type }
        return nil
    }

    var isCrop: Bool {
        if case .crop = kind { return true }
        return false
    }

    /// A slideshow, a gallery image or a crop: made from the post, stored and deleted as a library row of its own.
    public var isMade: Bool {
        switch kind {
        case .slideshow, .galleryImage, .crop: return true
        default: return false
        }
    }

    /// A made slideshow webp: stored as an animated webp record (`StoredVideo.Kind.webp`, `role .slideshow`).
    public var isAnimatedMade: Bool {
        if case .slideshow(_, .webp) = kind { return true }
        return false
    }

    /// What a remake replaces (R8); nil for anything that is not a made file.
    public var madeKind: MadeKind? {
        switch kind {
        case .slideshow(_, let format): return .slideshow(format)
        case .galleryImage(let layout, _): return .galleryImage(layout)
        case .crop: return .crop
        default: return nil
        }
    }

    /// The tab's name: `video`, `webp 1`, `photo 3`, `slideshow webp`, `slideshow`, `gallery image · 3 across`, `crop`
    /// (a second of one kind, from a server older than R8, says its number).
    public var tabName: String {
        switch kind {
        case .video: return "video"
        case .webp(let n): return "webp \(n)"
        case .item(let index, let type): return "\(type == .photo ? "photo" : type.rawValue) \(index + 1)"
        case .slideshow(let n, let format): return n > 1 ? "\(MadeKind.slideshow(format).tabName) \(n)" : MadeKind.slideshow(format).tabName
        case .galleryImage(let layout, let n):
            return n > 1 ? "\(MadeKind.galleryImage(layout).tabName) \(n)" : MadeKind.galleryImage(layout).tabName
        case .crop: return "crop"
        }
    }

    /// Every library file id this rendition has on the server (a webp's file; the video's private copy
    /// and hosted link). Empty for a rendition the library does not list.
    var serverFileIDs: [String] { [file?.id, hosted?.id].compactMap { $0 } }
}

/// How much of a media is kept on this device (CONTRACT-OFFLINE.md decision 3). Cached files do not count: the
/// cache is plumbing that may leave on its own, and calling such a file "offline" would be a lie.
public enum MediaOffline: Sendable, Equatable, Comparable { case none, some, all }

/// One media as the owner sees it, everywhere (orbit, library, detail): the device's `StoredMedia`
/// and the library's `LibraryPost` merged, so a webp made on another device shows on this one's tabs
/// and a webp made here shows before the library reloads (CONTRACT-MEDIA 1.8, 4.2).
public struct MediaItem: Sendable, Equatable, Identifiable {
    public var id: String               // local mediaID, else "post:<post id>"
    public var local: StoredMedia?
    public var post: LibraryPost?
    public var service: String?
    public var ref: String?
    public var link: URL?
    public var renditions: [Rendition]  // video first (when any), then webps oldest → newest
    /// This device's copy of the media's custom title (CONTRACT-LIBRARY2 decision 8), set by whoever
    /// builds the item from the store; `customTitle` prefers the server's.
    public var localTitle: String?

    public init(
        id: String, local: StoredMedia?, post: LibraryPost?, service: String?, ref: String?, link: URL?,
        renditions: [Rendition]
    ) {
        self.id = id
        self.local = local
        self.post = post
        self.service = service
        self.ref = ref
        self.link = link
        self.renditions = renditions
    }

    /// The video rendition, when the media has one (the original of a video post or a single photo; a gallery has items
    /// instead).
    public var video: Rendition? { renditions.first { $0.kind == .video } }

    /// The webps of a video, oldest to newest.
    public var webps: [Rendition] { renditions.filter(\.isWebp) }

    /// A gallery's items, in the post's order.
    public var items: [Rendition] { renditions.filter(\.isItem) }

    /// What was made from the post: slideshows, gallery images, crops (the tab order of 1.19).
    public var made: [Rendition] { renditions.filter(\.isMade) }

    /// The post's live items (the server's count, else what is known here); 0 for a media that is not a gallery.
    public var itemCount: Int { max(post?.itemCount ?? 0, items.count) }

    /// Item indices the save could not fetch (the post's `items_failed`), that no live item stands in for.
    public var missing: [Int] {
        let have = Set(items.compactMap(\.itemIndex))
        return (post?.itemsFailed ?? []).filter { !have.contains($0) }.sorted()
    }

    /// What this media is (the library's kind chips): the server's word for the post, else derived from the renditions.
    public var kind: MediaKind {
        if items.count >= 2 || (post?.kind == .gallery) { return .gallery }
        if let kind = post?.kind, kind != .gallery { return kind }
        if let only = items.first ?? video {
            let image = only.itemType.map { $0 == .photo }
                ?? (only.local.map { StoredMedia.isStill($0) } ?? (only.file?.contentType?.lowercased().hasPrefix("image/") == true))
            return image ? .photo : .video
        }
        return .webp
    }

    /// The newest animated webp (a slideshow webp counts), else the newest made video, else the first item, else the video
    /// (CONTRACT-MEDIA 1.4, CONTRACT-GALLERY 1.22).
    public var face: Rendition {
        let animated = renditions.filter { r in
            if case .webp = r.kind { return true }
            if case .slideshow(_, .webp) = r.kind { return true }
            return false
        }.max { $0.createdAt < $1.createdAt }
        if let animated { return animated }
        if let slideshow = renditions.last(where: { if case .slideshow = $0.kind { return true } else { return false } }) { return slideshow }
        return items.first ?? renditions[0]
    }

    public var webpCount: Int { renditions.reduce(0) { $0 + ($1.isWebp ? 1 : 0) } }

    public var latestAt: Date { renditions.map(\.createdAt).max() ?? .distantPast }

    /// `all` when every rendition (server-only webps included) is kept and its file is here; `some` when at least one
    /// is; else `none`.
    public var offline: MediaOffline {
        let kept = renditions.filter { $0.local?.isOffline == true }.count
        if kept == 0 { return .none }
        return kept == renditions.count ? .all : .some
    }

    /// The server holds something of this media: a library file, a hosted link, or a public webp.
    public var hasServerCopy: Bool {
        post != nil || renditions.contains { $0.file != nil || $0.hosted != nil || $0.publicURL != nil }
    }

    public func rendition(id: String) -> Rendition? { renditions.first { $0.id == id } }

    /// The item indices of the items whose library file ids are `ids` (what a made file's `made_from` names).
    func itemIndices(of ids: [String]) -> [Int] {
        ids.compactMap { id in items.first { $0.file?.id == id }?.itemIndex }
    }

    /// A local media and a library post are one item when any local session is the post's id or its
    /// session's id, or any local webp's public URL is one of the post's files (CONTRACT-MEDIA 4.2).
    /// Never by link: a carousel's items share one, and a post shared again later is a new media.
    public static func joins(_ local: StoredMedia, _ post: LibraryPost) -> Bool {
        let sessions = Set([post.id, post.session?.id].compactMap { $0 })
        if !local.sessionIDs.isDisjoint(with: sessions) { return true }
        return local.webps.contains { webp in webp.remoteURL.map { url in post.files.contains { isSameWebp($0, url) } } ?? false }
    }

    /// A post file is the webp behind `url` when it lists that link, or (a webp switched private lists none)
    /// when its `media_name`, the name the link ends in, is the link's own.
    static func isSameWebp(_ file: LibraryFile, _ url: URL) -> Bool {
        if file.url == url { return true }
        guard file.url == nil, file.role == .webp, let name = file.mediaName else { return false }
        return mediaName(of: url) == name
    }

    /// Merges the two sides (the caller decides they belong together, see `joins`). A local webp and a
    /// post file are one rendition when `remoteURL == file.url`; the video rendition merges the local
    /// original, the post's private copy and its hosted link; a webp only on one side is kept.
    /// Webps are numbered by `createdAt` (a post file's server time, else the local record's).
    /// Nil when both are nil.
    public static func merge(local: StoredMedia?, post: LibraryPost?) -> MediaItem? {
        guard local != nil || post != nil else { return nil }
        let link = local?.link ?? post?.link
        let linkInfo = link.flatMap { LinkInfo($0) }
        var renditions: [Rendition] = []

        // GET /library?v=3: a gallery's items and the files made from it are rows of their own (`galleryRole`); the video
        // rendition and the webps below read only the rows that are neither.
        let allFiles = post?.files ?? []
        let plainFiles = allFiles.filter { $0.galleryRole == nil }
        let original = local?.original
        let privateFile = plainFiles.first { $0.role == .privateCopy }
        let hostedFile = plainFiles.first { $0.role == .hostedLink }
        if original != nil || privateFile != nil || hostedFile != nil {
            // The server's word on the original beats whatever this device recorded (a stale `publicURL` never
            // wins). A legacy listing carries the visibility on the original too, but its link on the separate
            // hosted file; a server that says nothing keeps the old rule.
            let visibility: Visibility?
            let publicURL: URL?
            switch privateFile?.wireVisibility {
            case .private?:
                visibility = .private
                publicURL = nil
            case .public?:
                visibility = .public
                publicURL = privateFile?.url ?? hostedFile?.url ?? original?.publicURL
            case nil:
                publicURL = hostedFile?.url ?? original?.publicURL
                visibility = publicURL == nil ? nil : .public
            }
            renditions.append(Rendition(
                id: "video", kind: .video, local: original, file: privateFile, hosted: hostedFile,
                publicURL: publicURL,
                width: original?.width ?? privateFile?.width ?? hostedFile?.width ?? post?.width,
                height: original?.height ?? privateFile?.height ?? hostedFile?.height ?? post?.height,
                duration: original?.duration ?? privateFile?.duration ?? hostedFile?.duration ?? post?.duration,
                bytes: original.map(\.bytes) ?? privateFile?.bytes ?? hostedFile?.bytes,
                createdAt: privateFile?.createdAt ?? original?.createdAt ?? hostedFile?.createdAt ?? post?.createdAt ?? .distantPast,
                posterURL: hostedFile?.posterURL ?? privateFile?.posterURL,
                visibility: visibility, canToggleVisibility: privateFile?.canToggleVisibility ?? false))
        }

        renditions.append(contentsOf: itemRenditions(local: local, files: allFiles.filter { $0.galleryRole == .item }, post: post))
        let made = madeRenditions(local: local, files: allFiles.filter { $0.galleryRole != nil && $0.galleryRole != .item }, renditions: renditions)
        renditions.append(contentsOf: made.filter { !$0.isCrop })

        struct WebpPair {
            var order: Int
            var local: StoredVideo?
            var file: LibraryFile?
            var at: Date { file?.createdAt ?? local?.createdAt ?? .distantPast }
        }
        var pairs: [WebpPair] = []
        var unmatched = plainFiles.filter { $0.role == .webp }
        for webp in local?.webps ?? [] {
            var file: LibraryFile?
            if let url = webp.remoteURL, let i = unmatched.firstIndex(where: { Self.isSameWebp($0, url) }) {
                file = unmatched.remove(at: i)
            }
            pairs.append(WebpPair(order: pairs.count, local: webp, file: file))
        }
        for file in unmatched { pairs.append(WebpPair(order: pairs.count, local: nil, file: file)) }
        pairs.sort { $0.at != $1.at ? $0.at < $1.at : $0.order < $1.order }
        for (n, pair) in pairs.enumerated() {
            let webp = pair.local
            let file = pair.file
            // a webp the server holds private has no link, whatever this device recorded for it before
            let url: URL? = file.map { $0.url ?? ($0.wireVisibility == .private ? nil : webp?.remoteURL) } ?? webp?.remoteURL
            var name: String?
            if let file { name = file.deletable ? file.mediaName : nil } else if let url { name = Self.mediaName(of: url) }
            let rid: String = webp?.id ?? "f:\(file?.id ?? "")"
            let bytes: Int64? = webp?.bytes ?? file?.bytes
            renditions.append(Rendition(
                id: rid, kind: .webp(number: n + 1), local: webp, file: file, publicURL: url,
                width: webp?.width ?? file?.width, height: webp?.height ?? file?.height,
                duration: webp?.duration ?? file?.duration, bytes: bytes,
                createdAt: pair.at, clip: webp?.clip, deletableName: name, posterURL: file?.posterURL,
                visibility: file?.wireVisibility ?? (url == nil ? nil : .public),
                canToggleVisibility: file?.canToggleVisibility ?? false))
        }

        renditions.append(contentsOf: made.filter(\.isCrop))

        if renditions.isEmpty {
            // a post whose files are all unknown kinds: still one tab, from the post's own numbers
            renditions.append(Rendition(
                id: "video", kind: .video, width: post?.width, height: post?.height, duration: post?.duration,
                createdAt: post?.createdAt ?? .distantPast, posterURL: post?.posterURL))
        }
        var item = MediaItem(
            id: local?.id ?? "post:\(post?.id ?? "")", local: local, post: post,
            service: post?.service ?? linkInfo?.service, ref: post?.ref ?? linkInfo?.ref, link: link,
            renditions: renditions)
        item.localTitle = local.flatMap(Self.localTitle(of:))
        return item
    }

    // MARK: - Gallery renditions (apple/CONTRACT-GALLERY.md 1.19)

    /// One rendition per item of the post, in the post's order: this device's original and the library's row of the
    /// same `item_index` are one.
    static func itemRenditions(local: StoredMedia?, files: [LibraryFile], post: LibraryPost?) -> [Rendition] {
        let indices = Set((local?.items ?? []).compactMap(\.itemIndex)).union(files.compactMap(\.itemIndex)).sorted()
        return indices.map { index in
            let stored = local?.items.first { $0.itemIndex == index }
            let file = files.first { $0.itemIndex == index }
            let type = MediaType(contentType: file?.contentType)
                ?? stored.map { StoredMedia.isStill($0) ? MediaType.photo : MediaType.video } ?? .photo
            let url = file.flatMap { $0.wireVisibility == .private ? nil : $0.url } ?? stored?.publicURL
            return Rendition(
                id: "item:\(index)", kind: .item(index: index, type: type), local: stored, file: file, publicURL: url,
                width: stored?.width ?? file?.width, height: stored?.height ?? file?.height,
                duration: stored?.duration ?? file?.duration, bytes: stored.map(\.bytes) ?? file?.bytes,
                createdAt: file?.createdAt ?? stored?.createdAt ?? post?.createdAt ?? .distantPast,
                deletableName: nil, posterURL: file?.posterURL,
                visibility: file?.wireVisibility ?? (url == nil ? nil : .public),
                canToggleVisibility: file?.canToggleVisibility ?? false)
        }
    }

    /// The files made from the post, this device's and the library's joined by the library row's id: slideshow webps
    /// first, then slideshow mp4s, then gallery images, then crops, each oldest to newest (the tab order of 1.19). An
    /// export that is not a gallery image (a long image or a PDF made by an older build) is not a tab.
    static func madeRenditions(local: StoredMedia?, files: [LibraryFile], renditions items: [Rendition]) -> [Rendition] {
        struct Entry { var kind: MadeKind; var local: StoredVideo?; var file: LibraryFile?; var at: Date }
        var entries: [Entry] = []
        var unmatched = local?.made ?? []
        for file in files {
            guard let kind = file.madeKind else { continue }
            var stored: StoredVideo?
            if let i = unmatched.firstIndex(where: { $0.libraryID == file.id }) { stored = unmatched.remove(at: i) }
            entries.append(Entry(kind: kind, local: stored, file: file, at: file.createdAt))
        }
        for stored in unmatched {
            guard let kind = stored.madeKind else { continue }
            entries.append(Entry(kind: kind, local: stored, file: nil, at: stored.createdAt))
        }
        func rank(_ kind: MadeKind) -> Int {
            switch kind {
            case .slideshow(.webp): return 0
            case .slideshow(.mp4): return 1
            case .galleryImage(let layout): return 2 + (GalleryLayout.allCases.firstIndex(of: layout) ?? 0)
            case .crop: return 10
            }
        }
        entries.sort { a, b in
            let (x, y) = (rank(a.kind), rank(b.kind))
            return x != y ? x < y : a.at < b.at
        }
        var seen: [MadeKind: Int] = [:]
        func itemIndex(_ ids: [String]?, _ numbers: [Int]?) -> Int {
            if let id = ids?.first, let index = items.first(where: { $0.file?.id == id })?.itemIndex { return index }
            return numbers?.first ?? 0
        }
        return entries.map { entry in
            seen[entry.kind, default: 0] += 1
            let number = seen[entry.kind] ?? 1
            let kind: Rendition.Kind
            switch entry.kind {
            case .slideshow(let format): kind = .slideshow(number: number, format: format)
            case .galleryImage(let layout): kind = .galleryImage(layout: layout, number: number)
            case .crop: kind = .crop(of: itemIndex(entry.file?.madeFrom, entry.local?.madeFrom), spec: entry.file?.madeSpec ?? entry.local?.madeSpec.flatMap { MadeSpec(data: $0) })
            }
            let file = entry.file, stored = entry.local
            let url = file.flatMap { $0.wireVisibility == .private ? nil : $0.url } ?? stored?.publicURL
            return Rendition(
                id: file.map { "m:\($0.id)" } ?? stored.map { $0.libraryID.map { "m:\($0)" } ?? "l:\($0.id)" } ?? "m:",
                kind: kind, local: stored, file: file, publicURL: url,
                width: stored?.width ?? file?.width, height: stored?.height ?? file?.height,
                duration: stored?.duration ?? file?.duration, bytes: stored.map(\.bytes) ?? file?.bytes,
                createdAt: entry.at, posterURL: file?.posterURL,
                visibility: file?.wireVisibility ?? (url == nil ? nil : .public),
                canToggleVisibility: file?.canToggleVisibility ?? false)
        }
    }

    /// This device's custom title of a media: `StoredVideo.title` (decision 8). A rename of a post this
    /// device holds no media for lives in `LibraryModel.localTitles`, which `AppModel.mediaItem` overlays.
    static func localTitle(of local: StoredMedia) -> String? { local.customTitle }

    /// The server's media name of a public webp URL (`<10 letters or digits>.webp`), the name
    /// `DELETE /media/<name>` takes; nil for any other URL.
    static func mediaName(of url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.count == 15, name.hasSuffix(".webp"), name.dropLast(5).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return name
    }
}
