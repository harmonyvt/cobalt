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
