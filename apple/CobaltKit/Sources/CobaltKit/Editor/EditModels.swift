import Foundation

// The editor's server shapes (APP-API-CONTRACT 31.12, apple/CONTRACT-EDITOR.md 3.5): projects, the library files a timeline names,
// renders, and the refusals. Decoded with `CobaltJSON.decoder()` (snake_case keys, milliseconds for `*_at`), tolerantly: a field
// the server leaves out or sends as `null` is nil, a word this build does not know reads as the safe one.

/// What a library file is to the editor.
public enum EditSourceKind: String, Sendable, Codable {
    case video, gif, photo, unsupported

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EditSourceKind(rawValue: raw) ?? .unsupported
    }
}

/// `<source>` of 31.12: one library file a timeline names.
public struct EditSource: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: EditSourceKind
    public var contentType: String?
    public var width: Int?                      // the DISPLAY size (rotation applied)
    public var height: Int?
    public var duration: Double?
    public var bytes: Int64?
    public var posterURL: URL?
    /// False for a deleted or unknown row: the clip shows as missing.
    public var available: Bool

    public init(
        id: String, name: String, kind: EditSourceKind, contentType: String? = nil, width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, bytes: Int64? = nil, posterURL: URL? = nil, available: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.contentType = contentType
        self.width = width
        self.height = height
        self.duration = duration
        self.bytes = bytes
        self.posterURL = posterURL
        self.available = available
    }

    /// The display size, when the server knows both sides.
    public var display: PixelSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return PixelSize(w: width, h: height)
    }

    /// The file name without its extension, for a clip's label.
    public var shortName: String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        return base.isEmpty ? name : base
    }
}

extension EditSource: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, contentType, width, height, duration, bytes, available
        case posterURL = "posterUrl"            // `poster_url`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        kind = (try? c.decodeIfPresent(EditSourceKind.self, forKey: .kind)) ?? .unsupported
        contentType = try? c.decodeIfPresent(String.self, forKey: .contentType)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        bytes = try? c.decodeIfPresent(Int64.self, forKey: .bytes)
        posterURL = try? c.decodeIfPresent(URL.self, forKey: .posterURL)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? true
    }
}

/// `<project>` / `<project summary>` of 31.12 (`timeline` is nil in a summary).
public struct EditProject: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var revision: Int
    public var timeline: EditTimeline?
    public var canvas: EditCanvas
    public var duration: Double
    public var clipCount: Int
    public var coverURL: URL?
    public var createdAt: Date
    public var updatedAt: Date
    /// The newest render of the project.
    public var render: EditRender?

    public init(
        id: String, title: String, revision: Int, timeline: EditTimeline? = nil, canvas: EditCanvas, duration: Double,
        clipCount: Int, coverURL: URL? = nil, createdAt: Date, updatedAt: Date, render: EditRender? = nil
    ) {
        self.id = id
        self.title = title
        self.revision = revision
        self.timeline = timeline
        self.canvas = canvas
        self.duration = duration
        self.clipCount = clipCount
        self.coverURL = coverURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.render = render
    }
}

extension EditProject: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, revision, timeline, canvas, duration, clipCount, createdAt, updatedAt, render
        case coverURL = "coverUrl"              // `cover_url`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        revision = try c.decode(Int.self, forKey: .revision)
        timeline = try? c.decodeIfPresent(EditTimeline.self, forKey: .timeline)
        canvas = try c.decode(EditCanvas.self, forKey: .canvas)
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
        clipCount = (try? c.decodeIfPresent(Int.self, forKey: .clipCount)) ?? 0
        coverURL = try? c.decodeIfPresent(URL.self, forKey: .coverURL)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        render = try? c.decodeIfPresent(EditRender.self, forKey: .render)
    }
}

/// `<render>` of 31.12: one revision of a project being made into an MP4.
public struct EditRender: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case queued, preparing, rendering, finishing, done, error, cancelled }
    /// What the render makes (APP-API-CONTRACT 45.3): an editor project's video, or a chat thread replayed as a video.
    public enum Kind: String, Sendable { case edit, chat }

    public var id: String
    /// `edit` for an editor project; `chat` for a chat video, whose `projectID` is `"chat:<thread id>"` (never a project).
    public var kind: Kind
    /// The chat thread a `chat` render replays; nil for editor renders.
    public var threadID: String?
    public var projectID: String
    public var revision: Int
    public var title: String
    public var status: Status
    /// Queued renders created before this one (0 = next); nil unless queued.
    public var queueAhead: Int?
    /// 0...1 (preparing `0.1 x sent / input`, rendering `0.1 + 0.85 x done / total`, finishing 0.95, done 1); nil otherwise.
    public var progress: Double?
    public var secondsDone: Double?
    public var secondsTotal: Double
    /// `error.edit.render_failed`, `error.edit.timeout`, ... (31.12 "Render outcomes").
    public var error: String?
    /// The library item the finished render became.
    public var itemID: String?
    public var posterURL: URL?
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var cancelRequested: Bool
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String, projectID: String, revision: Int, title: String, status: Status, queueAhead: Int? = nil,
        progress: Double? = nil, secondsDone: Double? = nil, secondsTotal: Double, error: String? = nil, itemID: String? = nil,
        posterURL: URL? = nil, bytes: Int64? = nil, width: Int? = nil, height: Int? = nil, duration: Double? = nil,
        cancelRequested: Bool = false, createdAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil,
        kind: Kind = .edit, threadID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.projectID = projectID
        self.revision = revision
        self.title = title
        self.status = status
        self.queueAhead = queueAhead
        self.progress = progress
        self.secondsDone = secondsDone
        self.secondsTotal = secondsTotal
        self.error = error
        self.itemID = itemID
        self.posterURL = posterURL
        self.bytes = bytes
        self.width = width
        self.height = height
        self.duration = duration
        self.cancelRequested = cancelRequested
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Queued, preparing, rendering or finishing: the server is still on it.
    public var isActive: Bool {
        switch status {
        case .queued, .preparing, .rendering, .finishing: return true
        case .done, .error, .cancelled: return false
        }
    }

    /// Ended (done, error or cancelled).
    public var isEnded: Bool { !isActive }

    /// A chat video (45.3): there is no editor project to open, only its library post once it is done.
    public var isChat: Bool { kind == .chat || Self.isChatProjectID(projectID) }

    /// The `project_id` the server gives a chat render (`"chat:<thread id>"`), which no editor project ever has.
    public static func isChatProjectID(_ id: String) -> Bool { id.hasPrefix("chat:") }

    /// The newest moment the render is known to have reached: when it ended, else when it started, else when it was asked for.
    public var lastMoment: Date { finishedAt ?? startedAt ?? createdAt }

    /// How far along the states a render is (queued 0 ... ended 4), for choosing the fresher of two copies of it.
    var stageRank: Int {
        switch status {
        case .queued: return 0
        case .preparing: return 1
        case .rendering: return 2
        case .finishing: return 3
        case .done, .error, .cancelled: return 4
        }
    }

    /// This copy of a render is at least as fresh as `other` (the same render id): an ended one beats a running one, a
    /// later state beats an earlier one, more progress beats less. A tie is "yes": the caller's own copy wins.
    func isFresher(than other: EditRender) -> Bool {
        if stageRank != other.stageRank { return stageRank > other.stageRank }
        return (progress ?? 0) >= (other.progress ?? 0)
    }
}

extension EditRender.Status: Decodable {}

extension EditRender: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, revision, title, status, queueAhead, progress, secondsDone, secondsTotal, error, bytes, width, height, duration
        case cancelRequested, createdAt, startedAt, finishedAt, kind
        case threadID = "threadId"              // `thread_id`
        case projectID = "projectId"            // `project_id`
        case itemID = "itemId"                  // `item_id`
        case posterURL = "posterUrl"            // `poster_url`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectID = (try? c.decodeIfPresent(String.self, forKey: .projectID)) ?? ""
        // absent (an older server) or unknown: an editor render, unless the project id says it is a chat's
        let rawKind = try? c.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(Kind.init(rawValue:)) ?? (Self.isChatProjectID(projectID) ? .chat : .edit)
        threadID = try? c.decodeIfPresent(String.self, forKey: .threadID)
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        status = try c.decode(Status.self, forKey: .status)
        queueAhead = try? c.decodeIfPresent(Int.self, forKey: .queueAhead)
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
        secondsDone = try? c.decodeIfPresent(Double.self, forKey: .secondsDone)
        secondsTotal = (try? c.decodeIfPresent(Double.self, forKey: .secondsTotal)) ?? 0
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        itemID = try? c.decodeIfPresent(String.self, forKey: .itemID)
        posterURL = try? c.decodeIfPresent(URL.self, forKey: .posterURL)
        bytes = try? c.decodeIfPresent(Int64.self, forKey: .bytes)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        cancelRequested = (try? c.decodeIfPresent(Bool.self, forKey: .cancelRequested)) ?? false
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

// MARK: - Refusals

/// The editor routes' refusals (31.12), and the ways a call can fail before the server answers.
public enum EditError: Error, Sendable, Equatable {
    /// `404 error.edit.off`: the editor is off on this server.
    case off
    /// `404 error.edit.not_found`: an unknown or deleted project or render.
    case notFound
    /// `409 error.edit.conflict`: the revision moved; the server's current project.
    case conflict(EditProject)
    /// `409 error.edit.too_many`: 200 projects.
    case tooMany
    /// `429 error.edit.queue_full`: 20 renders queued or running.
    case queueFull
    /// `409 error.edit.finished`: cancel of a render that already ended.
    case finished
    /// `413 error.edit.too_large`: the inputs are over 6 GiB.
    case tooLarge
    /// A timeline the server refuses (`400`/`409` with a code of 31.12).
    case invalid(EditProblem)
    /// No network (or the device is offline).
    case offline
    /// `503`: D1 failed, migration 0021 missing, or the server is not answering.
    case unavailable
    /// Anything else: the server's code, or a short word for a local failure.
    case other(String)

    /// The error for a server answer: its code, the `path` and `items` it carries, and the current project of a conflict.
    public init(code: String, path: String?, items: [String], project: EditProject?) {
        let path = path ?? ""
        switch code {
        case "error.edit.off": self = .off
        case "error.edit.not_found": self = .notFound
        case "error.edit.conflict":
            if let project { self = .conflict(project) } else { self = .other(code) }
        case "error.edit.too_many": self = .tooMany
        case "error.edit.queue_full": self = .queueFull
        case "error.edit.finished": self = .finished
        case "error.edit.too_large": self = .tooLarge
        case "error.edit.canvas": self = .invalid(.canvas)
        case "error.edit.empty": self = .invalid(.empty)
        case "error.edit.too_many_clips": self = .invalid(.tooManyClips)
        case "error.edit.too_long": self = .invalid(.tooLong)
        case "error.edit.range": self = .invalid(.range(path: path))
        case "error.edit.overlay_overlap": self = .invalid(.overlayOverlap(path: path))
        case "error.edit.overlay_past_end": self = .invalid(.overlayPastEnd(path: path))
        case "error.edit.source_missing": self = .invalid(.sourceMissing(items))
        case "error.edit.not_video": self = .invalid(.notVideo(items))
        case "error.edit.unsupported_source": self = .invalid(.unsupportedSource(items))
        case "error.edit.past_source_end": self = .invalid(.pastSourceEnd(path: path))
        case "error.api.generic": self = .unavailable
        default: self = .other(code)
        }
    }

    /// Any error a call can throw, as an `EditError`.
    public static func from(_ error: Error) -> EditError {
        if let e = error as? EditError { return e }
        if let e = error as? CobaltError {
            switch e {
            case .api(let code, let status):
                let mapped = EditError(code: code, path: nil, items: [], project: nil)
                if case .other = mapped, status == 503 { return .unavailable }
                return mapped
            case .network(let code):
                return code == .cancelled ? .other("cancelled") : .offline
            case .invalidResponse(let status):
                return status == 503 ? .unavailable : .other("invalid response")
            case .noAPIKey: return .other("error.api.auth.key.missing")
            case .tooLarge: return .tooLarge
            case .cancelled: return .other("cancelled")
            }
        }
        if error is PipelineFailure { return .unavailable }
        if error is CancellationError { return .other("cancelled") }
        if error is URLError { return .offline }
        return .other(String(describing: error).prefix(80).description)
    }

    /// The failure a retry may cure (no network, the server not answering); everything else needs the owner or a fix.
    public var isTransient: Bool {
        switch self {
        case .offline, .unavailable: return true
        default: return false
        }
    }
}
