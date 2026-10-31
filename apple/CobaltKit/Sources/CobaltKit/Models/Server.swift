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
        /// `limits.share_set_max` (APP-API-CONTRACT 24): the most files one share link holds. 4 when absent; never below 2.
        public var shareSetMax: Int = 4
        /// `limits.edit_max_seconds` (APP-API-CONTRACT 31.1): the longest edit, in output seconds. 600 when absent.
        public var editMaxSeconds: Double = 600
        /// `limits.edit_max_clips`: main + overlay clips in one edit. 50 when absent.
        public var editMaxClips: Int = 50
        /// `limits.edit_max_projects`: saved edits (projects). 200 when absent.
        public var editMaxProjects: Int = 200
        /// `limits.edit_pitch` (APP-API-CONTRACT 31.16): the server knows a clip's `pitch`. False when absent: the app hides the
        /// pitch control and never sends a non-zero pitch (an older server refuses the key).
        public var editPitch: Bool = false
        /// `limits.status_ids` (APP-API-CONTRACT 37.4): the most ids one `POST /library/status` takes. 200 when absent;
        /// kept within 1...200.
        public var statusIds: Int = 200
        /// `limits.edit_overlay_tracks` (APP-API-CONTRACT 39.1): overlay layers an edit may use (`track` 0..n-1). 1 when
        /// absent: an older server refuses `track`, so everything stays on one layer.
        public var editOverlayTracks: Int = 1

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
    /// `features.queue` (APP-API-CONTRACT 23): `GET /queue` answers one snapshot of the server's work (the line, the
    /// search index's backlog, the posters) for the queue tab. False when absent: the tab then shows only what this
    /// device knows (its jobs, downloads and the photos album) and never asks the server.
    public var queue: Bool = false
    /// `features.search` (APP-API-CONTRACT 21): `GET /library/search` ranks the library by meaning and
    /// `GET /library/search/post` says how one post sits in the index. False when absent: the library's search field
    /// filters the loaded posts by name only, and the detail has no "search index" section.
    public var search: Bool = false
    /// `share_base_url` (APP-API-CONTRACT 22): the server's rich link pages. A public file
    /// `<mediaBaseURL><name>.<ext>` has a page at `<shareBaseURL><name>` that unfurls as a playable video or a
    /// full-size image in Discord, iMessage, X and the rest. Nil when absent: links are the files themselves.
    public var shareBaseURL: URL?
    /// `features.share_sets` (APP-API-CONTRACT 24): `POST/GET/DELETE /share/sets` make, list and revoke gallery links
    /// (2..`limits.shareSetMax` public files under one `<shareBaseURL>g/<id>`). The server sets it exactly while it has a
    /// `share_base_url`, and so does the app: false whenever `shareBaseURL` is nil. False when absent: no select mode in
    /// the library and no links tab.
    public var shareSets: Bool = false
    /// `features.share_collections` (APP-API-CONTRACT 26): named folders of gallery links (`/share/collections`). The
    /// server sets it exactly with `share_sets`, and so does the app: false whenever `shareSets` is false. False when
    /// absent: no collections in the links tab.
    public var shareCollections: Bool = false
    /// `features.share_groups` (APP-API-CONTRACT 28): named groups of collections, "sets" in the app (`/share/groups`).
    /// The server sets it exactly with `share_collections`, and so does the app: false whenever `shareCollections` is
    /// false. False when absent: no sets in the links tab.
    public var shareGroups: Bool = false
    /// `features.private_links` (APP-API-CONTRACT 36): a file or a gallery link can have a private link with a key in
    /// it (`/share/private`), which turns its public address off; rotating stops the old key at once. The server sets it
    /// exactly with `share_sets`, and so does the app: false whenever `shareSets` is false. False when absent: the
    /// detail keeps the public/private switch and the links tab has no badges.
    public var privateLinks: Bool = false
    /// `features.share_set_edit` (APP-API-CONTRACT 41): a gallery link's files can be added, taken out and moved, and its
    /// title changed, after it was made (`PATCH /share/sets/<id>`). The server sets it exactly with `share_sets`, and so
    /// does the app: false whenever `shareSets` is false. False when absent: a link card opens nothing.
    public var shareSetEdit: Bool = false
    /// `features.chat` (APP-API-CONTRACT 27): threads with Claude about the library (`/chat/threads`). True exactly while
    /// the server has an Anthropic key and the sandbox loader. False when absent: no chat tab.
    public var chat: Bool = false
    /// `features.stage` (APP-API-CONTRACT 30): the stream canvas and the viewer store (`/stage`). True exactly while the
    /// server has its stage host. False when absent: no studio tab.
    public var stage: Bool = false
    /// `features.stage_twitch` (30.1): Twitch channel points (connect, rewards, redemptions). The server sets it exactly
    /// with `stage` and its three Twitch secrets, and so does the app: false whenever `stage` is false. False when
    /// absent: the studio tab then has no Twitch card.
    public var stageTwitch: Bool = false
    /// `features.editor` (APP-API-CONTRACT 31): the timeline editor, `/edits` (projects and renders). True exactly while the
    /// server has its render container and migration 0021. False when absent: no `edit` button and no edits shelf.
    public var editor: Bool = false
    /// `features.edit_live_push` (APP-API-CONTRACT 32): `PUT /live/edits/<rid>` takes an editor render's activity token and
    /// the server keeps that Live Activity current with the app closed. False when absent: the app updates it while open.
    public var editLivePush: Bool = false
    /// `features.chat_live_push` (APP-API-CONTRACT 27.9): with a chat push-to-start token (`PUT /live/chat-start-token`) the
    /// server starts and updates a chat reply's Live Activity on this device when the message was sent from another one (the
    /// Mac, a Mac Shortcut). False when absent: only replies sent from this device get an activity.
    public var chatLivePush: Bool = false
    /// `features.still_webp` (APP-API-CONTRACT 18.14): a photo can be made into an animated webp of itself (2 frames of the
    /// same picture, so Discord offers "favourite"), a slideshow webp of one photo. The server sets it only with
    /// `gallery_make`, and so does the app. False when absent: photos have no "animated webp" button.
    public var stillWebp: Bool = false
    /// `features.about` (APP-API-CONTRACT 34): `GET /library/about` says what a post is about (a sentence, tags, the words its
    /// vector reads closest to) and `PATCH /library/about` edits the tags; the chat can rank a collection. True exactly
    /// while search is on and the server has an Anthropic key. The app also needs `search`. False when absent: the
    /// detail keeps the plain "search index" section.
    public var about: Bool = false
    /// `features.about_sound` (34): the descriptions also hear the post's sound (Workers AI transcript). False when absent.
    public var aboutSound: Bool = false
    /// `features.transcripts` (APP-API-CONTRACT 47): `GET /library/transcript` gives a video's subtitles with word times, and
    /// search hits say where the query was said (`said`). The app also needs `about_sound`. False when absent: no CC button.
    public var transcripts: Bool = false
    /// `features.hidden` (APP-API-CONTRACT 37): posts can be hidden (`POST /library/status`, `GET /library?hidden=1`) and
    /// auto-hide rules exist (`/hidden/rules`). True once the server's migration 0025 is applied. False when absent: no
    /// hidden chip, no status menu, no rules in settings.
    public var hidden: Bool = false
    /// `features.cutout` (APP-API-CONTRACT 39.3): `POST /library/items/<id>/cutout` exists: a picture's background can be
    /// taken out into a new private PNG (the app's own cutout is uploaded there). False when absent: no cutout button.
    public var cutout: Bool = false
    /// `features.cutout_auto` (39.3): the server can also make the cutout itself (Cloudflare Images): `auto` and any
    /// picture type. False when absent: the app makes every cutout on the device.
    public var cutoutAuto: Bool = false
    /// `features.accounts` (APP-API-CONTRACT 42): devices sign in through Cloudflare Access (`/auth/*`) instead of pasting a
    /// key. False when absent: settings keep the api key paste, and a revoked key is the old alert.
    public var accounts: Bool = false
    /// `features.image_crop` (APP-API-CONTRACT 44.1): `POST /library/items/<id>/crop` exists: a picture can be cropped, turned,
    /// flipped and have its background removed into a new private PNG (the app's own crop is uploaded there; the server's own
    /// crops of non-PNG pictures need `cutoutAuto`). False when absent: no crop sheet.
    public var imageCrop: Bool = false

    /// The link to hand out for a public file: its rich link page when the server has them, else the file's own URL.
    /// Anything that is not one of this server's public files is returned as is.
    public func shareLink(for url: URL) -> URL {
        guard let share = shareBaseURL, let media = mediaBaseURL else { return url }
        let base = media.absoluteString.hasSuffix("/") ? media.absoluteString : media.absoluteString + "/"
        let s = url.absoluteString
        guard s.hasPrefix(base) else { return url }
        let file = s.dropFirst(base.count)
        let parts = file.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, (6...40).contains(parts[0].count), (1...8).contains(parts[1].count),
              (parts[0] + parts[1]).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return url }
        let shareBase = share.absoluteString.hasSuffix("/") ? share.absoluteString : share.absoluteString + "/"
        return URL(string: shareBase + parts[0]) ?? url
    }

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
