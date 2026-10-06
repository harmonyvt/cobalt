import Foundation

/// One tab of a media's detail screen (CONTRACT-MEDIA 1.9): the video, or one of its webps.
public struct Rendition: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case video, webp(number: Int) }   // number: 1-based, creation order

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

    public var isWebp: Bool {
        if case .webp = kind { return true }
        return false
    }

    /// 1-based creation order of a webp; nil for the video.
    public var webpNumber: Int? {
        if case .webp(let n) = kind { return n }
        return nil
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

    /// The video rendition, when the media has one.
    public var video: Rendition? { renditions.first { !$0.isWebp } }

    /// The webps, oldest to newest.
    public var webps: [Rendition] { renditions.filter(\.isWebp) }

    /// The newest webp, else the video (CONTRACT-MEDIA 1.4).
    public var face: Rendition { renditions.last(where: \.isWebp) ?? renditions[0] }

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

        let original = local?.original
        let privateFile = post?.files.first { $0.role == .privateCopy }
        let hostedFile = post?.files.first { $0.role == .hostedLink }
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

        struct WebpPair {
            var order: Int
            var local: StoredVideo?
            var file: LibraryFile?
            var at: Date { file?.createdAt ?? local?.createdAt ?? .distantPast }
        }
        var pairs: [WebpPair] = []
        var unmatched = (post?.files ?? []).filter { $0.role == .webp }
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
