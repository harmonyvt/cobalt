import Foundation

/// What a webp was made from, as the app sent it (CONTRACT-MEDIA 4.1). Nil on a webp made elsewhere
/// (another device, the web) or before this existed: the server keeps a render's crop only in its job
/// record, so the meta line can only show trim and crop for webps made on this device.
public struct WebpClip: Sendable, Codable, Equatable {
    public var start: Double
    public var length: Double
    public var crop: CropRect?          // nil = whole frame
    public var quality: WebpQuality?
    public var width: Int?              // requested width

    public init(start: Double, length: Double, crop: CropRect?, quality: WebpQuality?, width: Int?) {
        self.start = start
        self.length = length
        self.crop = crop
        self.quality = quality
        self.width = width
    }

    /// The trim as a range, for `Copy.timecodeRange`.
    public var range: TrimRange { TrimRange(start: start, end: start + length) }
}

/// One media on this device: a source (a saved post, an uploaded file) with at most one video
/// rendition (the original) and any number of webps (CONTRACT-MEDIA 1.1). A **gallery** media (apple/CONTRACT-GALLERY.md
/// 1.1) instead has one original per item (`items`, in the post's order) and the files made from it (`made`: slideshows,
/// gallery images, crops), beside the webps of its video items. Built from the store's records in `OfflineStore.adopt`;
/// a value, so a view can hold one and compare it.
public struct StoredMedia: Sendable, Equatable, Identifiable {
    public let id: String                   // the mediaID
    public let original: StoredVideo?       // the video or the single photo (never an item of a gallery)
    public let webps: [StoredVideo]         // oldest → newest by createdAt (tab order)
    /// The originals of a gallery's items, in the post's order (`itemIndex`); empty for every other media.
    public let items: [StoredVideo]
    /// Files made from the post: slideshows (webp or mp4), gallery images and crops, oldest → newest.
    public let made: [StoredVideo]

    /// A media is never empty: nil when there is no record at all.
    public init?(id: String, original: StoredVideo?, webps: [StoredVideo], items: [StoredVideo] = [], made: [StoredVideo] = []) {
        guard original != nil || !webps.isEmpty || !items.isEmpty || !made.isEmpty else { return nil }
        self.id = id
        self.original = original
        self.webps = webps
        self.items = items
        self.made = made
    }

    /// A gallery: two or more item originals (the server calls a post a gallery from 2 live items).
    public var isGallery: Bool { items.count >= 2 }

    /// What this media is, for the library's kind chips and the orbit.
    public var kind: MediaKind {
        if isGallery { return .gallery }
        if let only = items.first ?? original {
            return Self.isStill(only) ? .photo : .video
        }
        return .webp
    }

    /// A still photo (not a video or a gif): by the record's file name, else its name.
    static func isStill(_ video: StoredVideo) -> Bool {
        let name = (video.fileURL?.lastPathComponent ?? video.name).lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains((name as NSString).pathExtension)
            && video.kind == .original
    }

    /// The planet's face: the newest animated webp (a slideshow webp counts), else the newest made video, else the
    /// first item or the original, else the newest webp (CONTRACT-MEDIA 1.4, CONTRACT-GALLERY 1.22).
    public var face: StoredVideo {
        let animated = (webps + made.filter { $0.kind == .webp }).max { $0.createdAt < $1.createdAt }
        if let animated { return animated }
        if let video = made.last(where: { $0.role == .slideshow }) { return video }
        return original ?? items.first ?? made.last ?? webps.last!
    }

    /// `[original] + items + made + webps`: the video (or the photo), a gallery's items in order, what was made, the
    /// webps.
    public var renditions: [StoredVideo] { (original.map { [$0] } ?? []) + items + made + webps }

    /// The newest `createdAt` of any rendition (CONTRACT-MEDIA 1.5).
    public var latestAt: Date { renditions.map(\.createdAt).max() ?? .distantPast }

    public var sessionIDs: Set<String> { Set(renditions.compactMap(\.sessionID)) }

    /// The original's link, else the first item's, else the newest webp's.
    public var link: URL? {
        if let link = original?.link ?? items.first?.link { return link }
        return (webps + made).reversed().first { $0.link != nil }?.link
    }

    /// The owner's title (decision 8): every record carries the same one; the original's, else the newest
    /// webp's that has one.
    public var customTitle: String? {
        original?.title ?? items.first?.title ?? (made + webps).reversed().compactMap(\.title).first
    }

    /// The original's name, else the first item's, else the face's name without ".webp".
    public var title: String {
        if let original { return original.name }
        if let item = items.first { return item.name }
        let name = face.name
        return name.lowercased().hasSuffix(".webp") ? String(name.dropLast(5)) : name
    }

    /// The original was hosted ("public share").
    public var isHosted: Bool { original?.publicURL != nil }

    /// The made file a remake of `kind` replaces, if this device has one.
    public func made(_ kind: MadeKind) -> [StoredVideo] { made.filter { $0.madeKind == kind } }

    /// Groups records into media: latest activity first, ties keep the index's order (newest added
    /// first). A media's webps are oldest to newest; a record the index gave to a media that already
    /// has an original is never a second original (`OfflineStore.add` and the migration prevent it).
    static func build(from videos: [StoredVideo]) -> [StoredMedia] {
        var order: [String] = []
        var groups: [String: [(index: Int, video: StoredVideo)]] = [:]
        for (i, v) in videos.enumerated() {
            if groups[v.mediaID] == nil { order.append(v.mediaID) }
            groups[v.mediaID, default: []].append((i, v))
        }
        func older(_ a: (index: Int, video: StoredVideo), _ b: (index: Int, video: StoredVideo)) -> Bool {
            a.video.createdAt != b.video.createdAt ? a.video.createdAt < b.video.createdAt : a.index > b.index
        }
        func inPost(_ a: (index: Int, video: StoredVideo), _ b: (index: Int, video: StoredVideo)) -> Bool {
            let (x, y) = (a.video.itemIndex ?? Int.max, b.video.itemIndex ?? Int.max)
            return x != y ? x < y : older(a, b)
        }
        var built: [(position: Int, media: StoredMedia)] = []
        for (position, key) in order.enumerated() {
            let group = groups[key] ?? []
            let original = group.filter { $0.video.kind == .original && $0.video.role == nil }.sorted(by: older).first?.video
            let items = group.filter { $0.video.role == .item }.sorted(by: inPost).map(\.video)
            let made = group.filter { $0.video.role != nil && $0.video.role != .item }.sorted(by: older).map(\.video)
            let webps = group.filter { $0.video.kind == .webp && $0.video.role == nil }.sorted(by: older).map(\.video)
            if let media = StoredMedia(id: key, original: original, webps: webps, items: items, made: made) {
                built.append((position, media))
            }
        }
        built.sort { a, b in
            let (x, y) = (a.media.latestAt, b.media.latestAt)
            return x != y ? x > y : a.position < b.position
        }
        return built.map(\.media)
    }
}
