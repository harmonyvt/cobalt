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
public enum SaveStep: String, Sendable, Codable { case fetching, reading, storing }

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
}

extension StudioSession {
    enum CodingKeys: String, CodingKey {
        case id, status, link, service, title, duration, width, height, bytes
        case createdAt, expiresAt, error, renders, step, stepBytes, stepTotal, waking
        case itemID = "itemId"                // `item_id` after convertFromSnakeCase
        case visibility
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
    }
}

public struct StudioCreated: Sendable, Equatable {
    public var id: String
    public var pageURL: URL?
}

public struct UploadResult: Sendable, Equatable {
    public var sessionID: String?              // nil for images, or when studioError is set
    public var item: LibraryFile
    public var studioErrorCode: String?
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

    public init(start: Double, length: Double, width: Int, quality: WebpQuality, notify: Bool = false, crop: CropRect? = nil) {
        self.start = start
        self.length = length
        self.width = width
        self.quality = quality
        self.notify = notify
        self.crop = crop
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

public enum RenderPhase: String, Sendable, Codable { case fetching, decode, pack }

public struct WebpResult: Sendable, Codable, Equatable {
    public var job: String
    public var url: URL
    public var bytes: Int64
    public var width: Int
    public var height: Int
    public var seconds: Double
}

public enum RenderStatus: Sendable, Equatable {
    case pending(phase: RenderPhase?, framesDone: Int?, framesTotal: Int?)
    case success(WebpResult)
    case failed(code: String)                  // {"status":"error"} with HTTP 200 = the job ended
}

public struct HostedFile: Sendable, Equatable {
    public var url: URL
    public var bytes: Int64?
    public var contentType: String?
    public var itemID: String?
}
