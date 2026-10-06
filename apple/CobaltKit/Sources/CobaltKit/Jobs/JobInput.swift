import Foundation

// The public vocabulary of the job queue (CONTRACT-PARALLEL.md section 3.2). Pinned between lanes: UI, Live and
// Shortcuts code against these names.

/// What one job is made from.
public enum JobInput: Sendable, Equatable {
    case link(URL)
    case file(URL, photosAssetID: String?)
    /// Follow a session someone else started (the share sheet), or this app's own after a relaunch.
    case shared(SharedJob)
}

/// What a caller may ask of a save. Applies to every input of one `add`, except `title`, which is for one-input adds.
public struct JobOptions: Sendable, Equatable, Codable {
    /// Sent with the create (APP-API-CONTRACT 17.3 `title`): the post's custom title. One-input adds only.
    public var title: String?
    /// nil = the app's "make new saves public" setting (`PipelineFlows.publicFlag`).
    public var makePublic: Bool?

    public init(title: String? = nil, makePublic: Bool? = nil) {
        self.title = title
        self.makePublic = makePublic
    }
}

/// Where a job came from: tells the queue whether it may take the focus and how to count it.
public enum JobVia: String, Sendable, Codable { case paste, drop, circle, review, relaunch, share, shortcut }

/// What `JobQueue.accepted(_:timeout:)` says about a job: the server has it, it failed first, or it is still local.
public enum JobAcceptance: Sendable, Equatable {
    /// The server answered the create (`201`/`202`): from here it owns the job. `postKey` is the session id for a link
    /// and the upload's item id for a file (equal to `GET /library`'s post `id`). `ahead` is `queue_ahead` when queued.
    /// An image upload has no session: both ids are its item id.
    case onServer(session: String, postKey: String, queued: Bool, ahead: Int?)
    case failed(PipelineFailure)
    /// Timed out before the create was answered (still uploading, or checking a link, or the server has no line).
    case stillLocal
}

public enum LineMode: Sendable, Equatable {
    /// The server holds the line (`features.line`): the app mirrors it.
    case server
    /// The server has no line: the app keeps its own, first come first served on this device.
    case device
}

/// Counts for the tray header, the Dock and the Live Activity. `waiting` is part of `live`: a job queued on the server
/// (or in the device line) is live and waiting, so "running" is `live - waiting`.
public struct JobSummary: Sendable, Equatable {
    public var live: Int
    public var waiting: Int
    public var finished: Int
    public var failed: Int

    public init(live: Int = 0, waiting: Int = 0, finished: Int = 0, failed: Int = 0) {
        self.live = live
        self.waiting = waiting
        self.finished = finished
        self.failed = failed
    }
}

/// Why a job is waiting (nil on `Pipeline.line` when it is not).
public enum LinePosition: Sendable, Equatable {
    /// 2 = "2nd in line" (the job running on the server is 1st). `behind`: who is directly ahead when it is not this
    /// app's own work: "a share from your iphone" / "a save from your mac" / "a save that isn't in this list".
    case inLine(Int, behind: String?)
    /// Device line only: a `429` for something that is not in this line (a save from another device).
    case serverBusy(since: Date, label: String?)
}

@MainActor
public struct Job: Identifiable {
    /// The pipeline's `liveRunID` when the job began (Live Activity, `SharedJob`, server run), stable for the job's life.
    public let id: UUID
    public let pipeline: Pipeline
    public let origin: Origin
    public let addedAt: Date
    public let via: JobVia
    /// Set when the job reaches a state that needs nothing more from the server (saved, webp ready, failed); nil while
    /// it is live. The tray keeps a finished job for five seconds beside the live ones.
    public internal(set) var finishedAt: Date?

    public enum Origin: Sendable { case app, share, relaunch, shortcut }

    public var state: PipelineState { pipeline.state }

    /// In flight (checking … packing), queued on the server included.
    public var isLive: Bool {
        switch pipeline.state {
        case .fetching, .uploading, .saving, .reading, .rendering: return true
        default: return false
        }
    }

    public var isFailed: Bool {
        if case .failed = pipeline.state { return true }
        return false
    }

    /// Saved (a planet), a webp made, an image hosted: nothing left for the server to do.
    public var isFinished: Bool {
        switch pipeline.state {
        case .ready, .done, .savedLocally, .image: return true
        default: return false
        }
    }

    /// A multi-item post waiting for the owner to pick.
    public var isPicker: Bool {
        if case .picker = pipeline.state { return true }
        return false
    }

    /// Queued on the server, or in the device line.
    public var isWaiting: Bool { isLive && pipeline.line != nil }

    /// Counts for the tray: live, waiting and finished are decided here, from the pipeline.
    var summaryCategory: Category {
        if isFailed { return .failed }
        if isLive { return pipeline.line != nil ? .waiting : .running }
        if isFinished { return .finished }
        return .other
    }

    enum Category { case running, waiting, finished, failed, other }
}
