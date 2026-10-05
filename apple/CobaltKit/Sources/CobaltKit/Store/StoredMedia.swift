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
/// rendition (the original) and any number of webps (CONTRACT-MEDIA 1.1). Built from the store's
/// records in `OfflineStore.adopt`; a value, so a view can hold one and compare it.
public struct StoredMedia: Sendable, Equatable, Identifiable {
    public let id: String                   // the mediaID
    public let original: StoredVideo?
    public let webps: [StoredVideo]         // oldest → newest by createdAt (tab order)

    /// A media is never empty: nil when there is neither an original nor a webp.
    public init?(id: String, original: StoredVideo?, webps: [StoredVideo]) {
        guard original != nil || !webps.isEmpty else { return nil }
        self.id = id
        self.original = original
        self.webps = webps
    }

    /// The planet's face: the newest webp, else the video (CONTRACT-MEDIA 1.4).
    public var face: StoredVideo { webps.last ?? original! }

    /// `[original] + webps`.
    public var renditions: [StoredVideo] { (original.map { [$0] } ?? []) + webps }

    /// The newest `createdAt` of any rendition (CONTRACT-MEDIA 1.5).
    public var latestAt: Date { renditions.map(\.createdAt).max() ?? .distantPast }

    public var sessionIDs: Set<String> { Set(renditions.compactMap(\.sessionID)) }

    /// The original's link, else the newest webp's.
    public var link: URL? {
        if let link = original?.link { return link }
        return webps.reversed().first { $0.link != nil }?.link
    }

    /// The original's name, else the face's name without ".webp".
    public var title: String {
        if let original { return original.name }
        let name = face.name
        return name.lowercased().hasSuffix(".webp") ? String(name.dropLast(5)) : name
    }

    /// The original was hosted ("public share").
    public var isHosted: Bool { original?.publicURL != nil }

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
        var built: [(position: Int, media: StoredMedia)] = []
        for (position, key) in order.enumerated() {
            let group = groups[key] ?? []
            let original = group.filter { $0.video.kind == .original }.sorted(by: older).first?.video
            let webps = group.filter { $0.video.kind == .webp }.sorted(by: older).map(\.video)
            if let media = StoredMedia(id: key, original: original, webps: webps) { built.append((position, media)) }
        }
        built.sort { a, b in
            let (x, y) = (a.media.latestAt, b.media.latestAt)
            return x != y ? x > y : a.position < b.position
        }
        return built.map(\.media)
    }
}
