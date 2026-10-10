import Foundation

public enum ServerKind: String, Sendable, Codable, Equatable {
    case fork, legacyFork, plainCobalt, notCobalt, unreachable
}

public enum KeyState: String, Sendable, Codable, Equatable { case valid, invalid, missing, unknown }

public struct Capabilities: Sendable, Codable, Equatable {
    public struct Limits: Sendable, Codable, Equatable {
        public var maxWebpSeconds: Double      // 10
        public var minWebpSeconds: Double      // 0.5
        public var webpWidths: [Int]           // [320, 480]
        public var renderFPS: Int              // 15
        public var maxUploadBytes: Int64       // 100_000_000
        public var maxSourceBytes: Int64       // 209_715_200
        public var sessionTTL: TimeInterval    // 604_800
        /// `limits.line_max` (APP-API-CONTRACT 17.9): entries the server's line holds, all keys together.
        public var lineMax: Int = 50
        /// `limits.line_wait_ms`, in seconds: how long a queued job may wait before the server ends it.
        public var lineWait: TimeInterval = 1_800

        public static let fork = Limits(
            maxWebpSeconds: 10, minWebpSeconds: 0.5, webpWidths: [320, 480], renderFPS: 15,
            maxUploadBytes: 100_000_000, maxSourceBytes: 209_715_200, sessionTTL: 604_800)
    }

    public var kind: ServerKind
    public var cobaltVersion: String?          // "11.7.1"
    public var studio: Bool                    // render webps, host originals
    public var upload: Bool                    // file circle
    public var library: Bool                   // library tab
    public var saveProgress: Bool              // session `step` fields
    public var renderProgress: Bool            // render `phase`/frame fields
    public var finishesUnpolled: Bool          // server sweep (share-sheet close is safe)
    public var limits: Limits
    public var mediaBaseURL: URL?
    public var key: KeyState
    public var keyName: String?
    /// `features.live_activity_push`: the server sends ActivityKit pushes. False when absent (older
    /// forks, plain cobalt), and the app then updates the activity itself while it is open.
    public var livePush: Bool = false
    /// `features.notify_bridge`: the server tells the owner (through Hark) when a save or render
    /// finishes, after an opt-in (`PUT /studio/<sid>/notify`). The path for a build that cannot
    /// receive APNs pushes. False when absent.
    public var notifyBridge: Bool = false
    /// `features.crop`: `POST /studio/<sid>/render` accepts a spatial `crop`. False when absent: the
    /// field is then never sent (an older server would ignore it and render the whole frame).
    public var crop: Bool = false
    /// `features.source_wait`: `GET /studio/<sid>/source?wait=N` holds the request until the save is
    /// ready (CONTRACT-SYNC.md section 5), so one background download task can wait for it. False
    /// when absent.
    public var sourceWait: Bool = false
    /// `features.delete_post`: `DELETE /library/items/<id>/post` deletes a whole post (CONTRACT-MEDIA 6.1).
    /// False when absent: "delete everything" then falls back to deleting the webps one by one.
    public var deletePost: Bool = false
    /// `features.telemetry`: `POST /telemetry` takes crash reports and logs. False when absent: the app
    /// then sends nothing and keeps its buffer on the device.
    public var telemetry: Bool = false
    /// `features.create_notify`: `POST /studio` takes `notify` (the Hark opt-in, registered with the
    /// session) and `origin: "share"`, and `GET /studio/recent` lists a key's share saves
    /// (APP-API-CONTRACT section 14). False when absent: the share extension's instant save then still
    /// works on the opt-in-less server, but nothing announces it.
    public var createNotify: Bool = false
    /// `features.titles`: `PATCH /library/items/<id>/post` exists and `GET /library` sends `custom_title`
    /// (CONTRACT-LIBRARY2 decision 7). False when absent: no title sheet, rename is local-only.
    public var titles: Bool = false
    /// `features.public_default`: `POST /studio` and `PUT /studio/upload` take `public` (APP-API-CONTRACT 13.2),
    /// so a save can be public from the start. False when absent: the app then never sends it.
    public var publicDefault: Bool = false
    /// `features.visibility`: `PATCH /library/items/<id>/visibility` and `GET /library?v=2` (APP-API-CONTRACT
    /// 16, CONTRACT-VISIBILITY.md). One file per rendition, public or private. False when absent: the app then
    /// keeps its "public share" flow and asks for the old library shape.
    public var visibility: Bool = false
    /// `features.line` (APP-API-CONTRACT 17.9): the server holds one line for every client. A save or render is sent
    /// with `queue: true` and starts when its turn comes, polled or not. False when absent: the app then keeps its
    /// own line on the device (`LineMode.device`) and sends no `queue`.
    public var line: Bool = false
    /// `features.gallery` (APP-API-CONTRACT 18.8): `POST /studio` takes `items`, a gallery is saved whole, and
    /// `GET /library?v=3` lists its items and made files. False when absent: the app keeps today's picker (save to
    /// Photos) for a multi-item post, and the share sheet says the server cannot save photo posts yet.
    public var gallery: Bool = false
    /// `features.gallery_make` (18.13): the slideshow webp, the gallery image, `item` on renders and the share sheet's
    /// chained make exist (needs `gallery`). False when absent: the three makes are hidden and the share sheet draws only
    /// `save all`.
    public var galleryMake: Bool = false
    /// `features.direct_links`: `POST /studio` takes a link straight at a media file (image, video or gif, from any
    /// public host) and the server fetches and saves it as one item. False when absent: the app then downloads such a
    /// link on the device and sends it through the file upload instead.
    public var directLinks: Bool = false

    public static let unknown = Capabilities(
        kind: .unreachable, cobaltVersion: nil, studio: false, upload: false, library: false,
        saveProgress: false, renderProgress: false, finishesUnpolled: false,
        limits: .fork, mediaBaseURL: nil, key: .unknown, keyName: nil, livePush: false, notifyBridge: false, crop: false)
}

public enum CobaltError: Error, Sendable, Equatable {
    case api(code: String, httpStatus: Int)    // {"status":"error","error":{"code"}} and cobalt's own
    case network(URLError.Code)
    case invalidResponse(httpStatus: Int)
    case noAPIKey
    case tooLarge(limit: Int64)
    case cancelled
}
