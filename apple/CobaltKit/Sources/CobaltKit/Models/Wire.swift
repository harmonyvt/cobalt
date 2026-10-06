import Foundation

// MARK: - JSON

enum CobaltJSON {
    /// `convertFromSnakeCase`, and `*_at` fields as milliseconds since the epoch.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try c.decode(Double.self) / 1000)
        }
        return d
    }

    /// Encoder mirroring `decoder()`, used for round-trip tests and caches.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode((date.timeIntervalSince1970 * 1000).rounded())
        }
        return e
    }
}

/// One element of an array that may be malformed: it decodes to nil instead of failing the whole
/// array, so a single odd row never hides a session's other renders or a library page.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - POST /

public enum MediaType: String, Sendable, Codable { case photo, video, gif }

public struct PickerItem: Sendable, Equatable, Identifiable {
    public var id: Int                         // index in cobalt's picker array
    public var type: MediaType
    public var url: URL
    public var thumb: URL?
    public var canWebp: Bool { type != .photo }

    public init(id: Int, type: MediaType, url: URL, thumb: URL? = nil) {
        self.id = id
        self.type = type
        self.url = url
        self.thumb = thumb
    }
}

public enum CobaltResult: Sendable, Equatable {    // POST /
    case file(url: URL, filename: String?)     // "tunnel" | "redirect"
    case picker(items: [PickerItem], audio: URL?)
    case localProcessing                       // not supported by the app
}

// MARK: - Studio

public enum SessionStatus: String, Sendable, Codable { case saving, ready, error }
/// `queued` (APP-API-CONTRACT 17.4): the save waits in the server's line; `queue_ahead` says how many run before it.
public enum SaveStep: String, Sendable, Codable { case fetching, reading, storing, queued }

public struct StudioRender: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    public var start: Double
    public var length: Double
    public var width: Int?
    public var quality: String?
    public var bytes: Int64?
    public var createdAt: Date
}

public struct StudioSession: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var status: SessionStatus
    public var link: String?                   // a page URL, or "upload:<item id>"
    public var service: String?
    public var title: String?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var bytes: Int64?
    public var createdAt: Date
    public var expiresAt: Date
    public var errorCode: String?              // from "error": {"code"}
    public var renders: [StudioRender]
    public var step: SaveStep?                 // new; nil = server does not say
    public var stepBytes: Int64?
    public var stepTotal: Int64?
    public var waking: Bool?
    /// `item_id` (APP-API-CONTRACT 16.3): the library row of this session's original; nil from an older server
    /// or while the save has no row yet.
    public var itemID: String?
    /// `visibility`: that row's; nil when the server does not say.
    public var visibility: Visibility?
    /// `queue_ahead` (APP-API-CONTRACT 17.4): while the save waits in the server's line, the jobs that run before
    /// it, **the running one included** (`1` = next; the app says "2nd in line"). Nil otherwise, and from a server
    /// without `features.line`.
    public var queueAhead: Int?
}

extension StudioSession {
    enum CodingKeys: String, CodingKey {
        case id, status, link, service, title, duration, width, height, bytes
        case createdAt, expiresAt, error, renders, step, stepBytes, stepTotal, waking
        case itemID = "itemId"                // `item_id` after convertFromSnakeCase
        case visibility
        case queueAhead                       // `queue_ahead`
    }

    struct ErrorBody: Codable, Equatable { var code: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(SessionStatus.self, forKey: .status)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        service = try c.decodeIfPresent(String.self, forKey: .service)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        errorCode = (try? c.decodeIfPresent(ErrorBody.self, forKey: .error))??.code
        renders = (try c.decodeIfPresent([Lossy<StudioRender>].self, forKey: .renders) ?? []).compactMap(\.value)
        // A newer server may add steps this build does not know: treat them as "not said".
        step = (try? c.decodeIfPresent(SaveStep.self, forKey: .step)) ?? nil
        stepBytes = try c.decodeIfPresent(Int64.self, forKey: .stepBytes)
        stepTotal = try c.decodeIfPresent(Int64.self, forKey: .stepTotal)
        waking = try c.decodeIfPresent(Bool.self, forKey: .waking)
        itemID = (try? c.decodeIfPresent(String.self, forKey: .itemID)) ?? nil
        visibility = (try? c.decodeIfPresent(Visibility.self, forKey: .visibility)) ?? nil
        queueAhead = (try? c.decodeIfPresent(Int.self, forKey: .queueAhead)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(service, forKey: .service)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        if let errorCode { try c.encode(ErrorBody(code: errorCode), forKey: .error) }
        try c.encode(renders, forKey: .renders)
        try c.encodeIfPresent(step, forKey: .step)
        try c.encodeIfPresent(stepBytes, forKey: .stepBytes)
        try c.encodeIfPresent(stepTotal, forKey: .stepTotal)
        try c.encodeIfPresent(waking, forKey: .waking)
        try c.encodeIfPresent(itemID, forKey: .itemID)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        try c.encodeIfPresent(queueAhead, forKey: .queueAhead)
    }
}

public struct StudioCreated: Sendable, Equatable {
    public var id: String
    public var pageURL: URL?
    /// `queued` / `queue_ahead` (APP-API-CONTRACT 17.3): present only when the caller sent `queue`. A save that
    /// started at once, an old server and a caller that did not ask all read `false` / nil.
    public var queued: Bool = false
    public var queueAhead: Int?
}

public struct UploadResult: Sendable, Equatable {
    public var sessionID: String?              // nil for images, or when studioError is set
    public var item: LibraryFile
    public var studioErrorCode: String?
    /// The adopted session waits in the server's line (`?queue=1`, APP-API-CONTRACT 17.3) and its place.
    public var queued: Bool = false
    public var queueAhead: Int?
}

public enum WebpQuality: String, Sendable, Codable, CaseIterable { case low, med, high }

public struct RenderRequest: Sendable, Equatable {
    public var start: Double
    public var length: Double
    public var width: Int
    public var quality: WebpQuality
    /// `"notify": true` on `POST /studio/<sid>/render`: the notify bridge pushes "rendered" / "failed"
    /// for this render without a separate `PUT .../notify` (APP-API-CONTRACT 9). False by default,
    /// and only ever sent when the server says `features.notify_bridge`.
    public var notify: Bool = false
    /// `crop` on `POST /studio/<sid>/render` (CONTRACT-ORBIT 2d): nil (or the whole frame) sends nothing.
    public var crop: CropRect?
    /// `"queue": true` (APP-API-CONTRACT 17.3): wait in the server's line instead of `429 error.webp.busy`.
    /// Nil sends nothing (a server without `features.line`).
    public var queue: Bool?
    /// `"priority": "focused"`: a render the owner asked for from the screen goes ahead of every waiting save.
    /// Only valid with `queue`.
    public var priority: String?

    public init(
        start: Double, length: Double, width: Int, quality: WebpQuality, notify: Bool = false, crop: CropRect? = nil,
        queue: Bool? = nil, priority: String? = nil
    ) {
        self.start = start
        self.length = length
        self.width = width
        self.quality = quality
        self.notify = notify
        self.crop = crop
        self.queue = queue
        self.priority = priority
    }
}

/// What the notify bridge may tell the owner about (`PUT /studio/<sid>/notify`, APP-API-CONTRACT 9).
public enum NotifyEvent: String, Sendable, Codable, CaseIterable { case saved, rendered, failed }

/// "Tell me when this session's work is done", so the app need not be running to say so.
public struct NotifyOptIn: Sendable, Equatable {
    public static let maxLabelLength = 60
    public var on: [NotifyEvent]
    /// What the notification calls the work (the clip's name); at most 60 characters.
    public var label: String

    public init(on: [NotifyEvent], label: String) {
        self.on = on
        self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLabelLength))
    }
}

/// `queued` (APP-API-CONTRACT 17.4): the render waits in the server's line.
public enum RenderPhase: String, Sendable, Codable { case fetching, decode, pack, queued }

public struct WebpResult: Sendable, Codable, Equatable {
    public var job: String
    public var url: URL
    public var bytes: Int64
    public var width: Int
    public var height: Int
    public var seconds: Double
}

public enum RenderStatus: Sendable, Equatable {
    case pending(phase: RenderPhase?, framesDone: Int?, framesTotal: Int?, queueAhead: Int? = nil)
    case success(WebpResult)
    case failed(code: String)                  // {"status":"error"} with HTTP 200 = the job ended
}

public struct HostedFile: Sendable, Equatable {
    public var url: URL
    public var bytes: Int64?
    public var contentType: String?
    public var itemID: String?
}

// MARK: - The server's line (APP-API-CONTRACT section 17)

/// What `DELETE /studio/<sid>/line` and `DELETE /studio/<sid>/render/<job>` answer: the queued job is gone, or its
/// turn came first (`409 error.studio.started`: the server finishes what it started).
public enum QueueCancel: Sendable, Equatable { case cancelled, started }

/// `GET /studio/line` (keyed): who runs and who waits, as the server holds it. `sid`, `job` and `link` are only
/// there for the caller's own work (`mine`); `keyName` is the key's name (nil for an unknown key).
public struct ServerLineSnapshot: Sendable, Equatable {
    public struct Running: Sendable, Equatable {
        public var kind: String                // "save" | "render" | "webp" | "poster"
        public var mine: Bool
        public var sid: String?
        public var job: String?
        public var origin: String?             // "share" for the share sheet
        public var keyName: String?

        public init(kind: String, mine: Bool = false, sid: String? = nil, job: String? = nil, origin: String? = nil, keyName: String? = nil) {
            self.kind = kind; self.mine = mine; self.sid = sid; self.job = job; self.origin = origin; self.keyName = keyName
        }
    }

    public struct Entry: Sendable, Equatable {
        public var position: Int               // the running job counts as 1st
        public var kind: String                // "save" | "render"
        public var mine: Bool
        public var sid: String?
        public var job: String?
        public var origin: String?
        public var priority: String?
        public var keyName: String?
        public var link: String?

        public init(
            position: Int, kind: String = "save", mine: Bool = false, sid: String? = nil, job: String? = nil,
            origin: String? = nil, priority: String? = nil, keyName: String? = nil, link: String? = nil
        ) {
            self.position = position; self.kind = kind; self.mine = mine; self.sid = sid; self.job = job
            self.origin = origin; self.priority = priority; self.keyName = keyName; self.link = link
        }
    }

    public var running: Running?               // nil = the helper is free
    public var entries: [Entry]
    public var max: Int
    public var waitMs: Int

    public init(running: Running? = nil, entries: [Entry] = [], max: Int = 50, waitMs: Int = 1_800_000) {
        self.running = running; self.entries = entries; self.max = max; self.waitMs = waitMs
    }
}

extension ServerLineSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey { case running, entries, max, waitMs }
    private struct WireRunning: Decodable {
        var kind: String?; var mine: Bool?; var sid: String?; var job: String?; var origin: String?; var keyName: String?
    }
    private struct WireEntry: Decodable {
        var position: Int; var kind: String?; var mine: Bool?; var sid: String?; var job: String?
        var origin: String?; var priority: String?; var keyName: String?; var link: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let r = (try? c.decodeIfPresent(WireRunning.self, forKey: .running)) ?? nil
        running = r.map { Running(kind: $0.kind ?? "save", mine: $0.mine ?? false, sid: $0.sid, job: $0.job, origin: $0.origin, keyName: $0.keyName) }
        let wire = (try c.decodeIfPresent([Lossy<WireEntry>].self, forKey: .entries) ?? []).compactMap(\.value)
        entries = wire.map {
            Entry(
                position: $0.position, kind: $0.kind ?? "save", mine: $0.mine ?? false, sid: $0.sid, job: $0.job,
                origin: $0.origin, priority: $0.priority, keyName: $0.keyName, link: $0.link)
        }.sorted { $0.position < $1.position }
        max = (try? c.decodeIfPresent(Int.self, forKey: .max)) ?? 50
        waitMs = (try? c.decodeIfPresent(Int.self, forKey: .waitMs)) ?? 1_800_000
    }
}
