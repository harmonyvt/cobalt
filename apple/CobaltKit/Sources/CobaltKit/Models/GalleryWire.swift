import Foundation

// The wire of galleries and made files (APP-API-CONTRACT 18.2, 18.5, 18.10-18.13): what the create takes, what a make
// answers, how a make progresses, and what a whole-post visibility switch returns.

/// Everything `POST /studio` can be asked beside the link (APP-API-CONTRACT 13.2, 14.1, 17.3, 18.2, 18.12). The old
/// `createStudio(link:public:queue:title:)` is this with the gallery fields empty.
public struct StudioCreateOptions: Sendable, Equatable {
    /// `public` (13.2): nil leaves the field out (private).
    public var makePublic: Bool?
    /// `queue: true` (17.3).
    public var queue: Bool
    /// The post's custom title (17.3).
    public var title: String?
    /// `"origin": "share"` (14.1) for a save the share sheet made; nil leaves it out.
    public var origin: String?
    /// The Hark opt-in sent with the create (14.1, 18.12); nil leaves it out.
    public var notify: NotifyOptIn?
    /// `items` (18.2): which items of a multi-item post to save. Nil = the server's own rule (and, for a photo-only
    /// post, 18.9's "save whole").
    public var items: GalleryChoice?
    /// `item_count` (18.2): the count the client saw; a post that changed since fails `error.studio.gallery_changed`.
    public var itemCount: Int?
    /// `slideshow` (18.12): make a slideshow as soon as the save is ready (needs `items`). `seconds` is built from
    /// `itemInfo` (a number for a photo, `null` for a video or gif).
    public var slideshow: SlideshowPlan?
    /// `gallery_image` (18.12): make a gallery image as soon as the save is ready (needs `items`; not with `slideshow`).
    public var galleryImage: GalleryImagePlan?
    /// The items of the post as the client knows them: their types give the plan's `seconds`, and a gallery image's
    /// `items` are cut down to the photos among them.
    public var itemInfo: [GalleryItem]

    public init(
        makePublic: Bool? = nil, queue: Bool = false, title: String? = nil, origin: String? = nil, notify: NotifyOptIn? = nil,
        items: GalleryChoice? = nil, itemCount: Int? = nil, slideshow: SlideshowPlan? = nil,
        galleryImage: GalleryImagePlan? = nil, itemInfo: [GalleryItem] = []
    ) {
        self.makePublic = makePublic
        self.queue = queue
        self.title = title
        self.origin = origin
        self.notify = notify
        self.items = items
        self.itemCount = itemCount
        self.slideshow = slideshow
        self.galleryImage = galleryImage
        self.itemInfo = itemInfo
    }

    /// Nothing here needs more than the old create (no gallery field, no origin, no notify).
    var isPlain: Bool {
        items == nil && itemCount == nil && slideshow == nil && galleryImage == nil && origin == nil && notify == nil
    }

    /// The JSON body of `POST /studio` for `link`.
    func body(link: URL) -> [String: Any] {
        var fields: [String: Any] = ["url": link.absoluteString]
        if let makePublic { fields["public"] = makePublic }
        if queue { fields["queue"] = true }
        if let title { fields["title"] = title }
        if let origin { fields["origin"] = origin }
        if let notify { fields["notify"] = ["on": notify.on.map(\.rawValue), "label": notify.label] as [String: Any] }
        if let items { fields["items"] = items.wireValue }
        if let itemCount { fields["item_count"] = itemCount }
        if let slideshow { fields["slideshow"] = slideshow.wireBody(items: itemInfo, includesQueue: false) }
        if let galleryImage { fields["gallery_image"] = galleryImage.wireBody(items: itemInfo, includesQueue: false) }
        return fields
    }
}

extension SlideshowPlan {
    /// The body of `POST /studio/<sid>/slideshow` (18.5, 18.10), or the `slideshow` object of the create (18.12, which has
    /// no `queue`/`priority`/`notify`).
    func wireBody(items: [GalleryItem], includesQueue: Bool, focused: Bool = false, notify: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "items": self.items,
            "seconds": seconds(for: items).map { $0.map { $0 as Any } ?? NSNull() },
            "fade": fade,
            "frame": frame.rawValue,
            "sound": sound.rawValue,
            "format": format.rawValue,
        ]
        if format == .webp {
            if let quality { body["quality"] = quality.rawValue }
            if let width { body["width"] = width }
        }
        if includesQueue {
            body["queue"] = true
            if focused { body["priority"] = "focused" }
            if notify { body["notify"] = true }
        }
        return body
    }
}

extension GalleryImagePlan {
    /// The body of `POST /studio/<sid>/gallery-image` (18.11), or the `gallery_image` object of the create (18.12). Only
    /// photos go on the wire (the server refuses a video or gif in `items`).
    func wireBody(items: [GalleryItem], includesQueue: Bool, focused: Bool = false, notify: Bool = false) -> [String: Any] {
        let sent = items.isEmpty ? self.items : photoOnly(in: items).items
        var body: [String: Any] = ["items": sent, "layout": layout.rawValue]
        if includesQueue {
            body["queue"] = true
            if focused { body["priority"] = "focused" }
            if notify { body["notify"] = true }
        }
        return body
    }
}

/// `202 {status: "pending", job, queued, queue_ahead}` of a slideshow or gallery-image make.
public struct RenderAccepted: Sendable, Equatable {
    public var job: String
    /// The make waits in the server's line (`queue_ahead` says how many run before it).
    public var queued: Bool
    public var queueAhead: Int?

    public init(job: String, queued: Bool = false, queueAhead: Int? = nil) {
        self.job = job
        self.queued = queued
        self.queueAhead = queueAhead
    }
}

/// `phase` of a make's progress (18.5, 18.11): `queued`, `uploading` (inputs into the helper), `composing` (`done` =
/// stills done), `encoding` (`done` = seconds encoded).
public enum MakePhase: String, Sendable, Codable { case queued, uploading, composing, encoding }

/// What a finished make answers (18.5, 18.10, 18.11): the made file's library row and its numbers.
public struct MadeResult: Sendable, Equatable {
    public var job: String
    /// The library row of the made file (`item_id`); the app downloads and tabs it by this.
    public var itemID: String?
    /// The public link, when the post is public (`url?`).
    public var url: URL?
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    /// A slideshow's length.
    public var seconds: Double?
    /// `format` of a slideshow (18.10); nil for a gallery image.
    public var format: SlideshowPlan.Format?
    /// A gallery image: the photos (0-based positions in the request) cropped, and drawn larger than their own pixels.
    public var cropped: [Int]
    public var upscaled: [Int]
    /// `replaced` (R8): the library rows the server deleted because this make replaces them.
    public var replaced: [String]

    public init(
        job: String, itemID: String? = nil, url: URL? = nil, bytes: Int64? = nil, width: Int? = nil, height: Int? = nil,
        seconds: Double? = nil, format: SlideshowPlan.Format? = nil, cropped: [Int] = [], upscaled: [Int] = [], replaced: [String] = []
    ) {
        self.job = job
        self.itemID = itemID
        self.url = url
        self.bytes = bytes
        self.width = width
        self.height = height
        self.seconds = seconds
        self.format = format
        self.cropped = cropped
        self.upscaled = upscaled
        self.replaced = replaced
    }
}

/// `GET /studio/<sid>/render/<job>` of a make.
public enum MakeStatus: Sendable, Equatable {
    case pending(phase: MakePhase?, done: Int?, total: Int?, queueAhead: Int?)
    case success(MadeResult)
    case failed(code: String)
}

/// What `PATCH /library/items/<id>/visibility` with `"scope": "post"` answers (18.4): the files as they are now, and the
/// ones that did not switch (a partial answer is returned, not thrown: the call is idempotent, so a retry finishes it).
public struct VisibilityResult: Sendable, Equatable {
    public var files: [LibraryFile]
    public var cacheCleared: Bool?
    /// Ids of the files still in their old state (`502 error.library.partial`); empty when everything switched.
    public var remaining: [String]

    public init(files: [LibraryFile], cacheCleared: Bool? = nil, remaining: [String] = []) {
        self.files = files
        self.cacheCleared = cacheCleared
        self.remaining = remaining
    }
}
