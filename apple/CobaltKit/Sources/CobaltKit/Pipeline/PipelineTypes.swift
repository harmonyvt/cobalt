import CoreGraphics
import Foundation

public struct MediaInfo: Sendable, Equatable, Codable {
    public var name: String
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var bytes: Int64?
    public var isImage: Bool

    public init(name: String, duration: Double?, width: Int?, height: Int?, bytes: Int64?, isImage: Bool) {
        self.name = name
        self.duration = duration
        self.width = width
        self.height = height
        self.bytes = bytes
        self.isImage = isImage
    }
}

public enum PipelineInput: Sendable, Equatable {
    case link(LinkInfo)
    case file(name: String, bytes: Int64, contentType: String)
}

public struct TrimRange: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var length: Double { end - start }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public enum TrimHandle: Sendable { case start, end, span }

public enum RenderProgress: Sendable, Equatable {
    case decoding(done: Int, total: Int)       // real counts from the server
    case packing(since: Date)                  // open-ended, breathes
    case working(since: Date)                  // server sends no counts (degraded) or not started yet
}

public enum PipelineFailure: Sendable, Equatable, Error {
    case noLink                    // pasteboard had no http(s) link
    case tooLarge(limit: Int64)    // file over the upload limit (checked before uploading)
    case fetchFailed(code: String) // cobalt couldn't fetch (error.api.fetch.*, content.*, link.*)
    case unsupported               // local-processing, or a type the server refuses
    case serverBusy                // error.studio.busy after the pipeline's own retries (60 s)
    case renderBusy                // error.webp.busy (keeps the trim)
    case renderLost                // error.webp.job_lost (keeps the trim)
    case expired                   // error.studio.expired
    case keyMissing, keyInvalid    // error.api.auth.key.*
    case unreachable
    case server(code: String)      // anything else

    /// `.server` codes of "save to photos": the owner refused (or restricted) add-only access to
    /// Photos, and Photos itself refused the file. UI words them ("allow cobalt to add to photos in
    /// settings"); they never show as raw codes.
    public static let photosDeniedCode = "error.app.photos_denied"
    public static let photosFailedCode = "error.app.photos_failed"

    /// This is the Photos permission being refused.
    public var isPhotosDenied: Bool { self == .server(code: Self.photosDeniedCode) }

    /// Marks a `.server` code as one that came up while rendering (`ErrorMap.serverFailure`).
    public static let renderPhasePrefix = "render."

    /// renderBusy, renderLost, and server errors during rendering (not during saving: there is
    /// no trim to keep, and "make it again" would have nothing to make).
    public var keepsTrim: Bool {
        switch self {
        case .renderBusy, .renderLost: return true
        case .server(let code): return code.hasPrefix(PipelineFailure.renderPhasePrefix)
        default: return false
        }
    }
}

public enum PipelineState: Sendable, Equatable {
    case idle
    case fetching(since: Date, waking: Bool)
    case uploading(TransferProgress)
    case saving(bytes: Int64?, total: Int64?, since: Date)   // bytes nil = degraded "saving"
    case reading(developed: Int, of: Int)
    case picker(items: [PickerItem])
    case image(MediaInfo)
    case ready
    case rendering(RenderProgress)
    case done(WebpResult)
    case savedLocally(StoredVideo)             // plain cobalt end state
    case failed(PipelineFailure)
}

public struct Rail: Sendable, Equatable {
    public enum Step: Sendable, Equatable { case fetch, upload, save, read, webp, host }
    public var steps: [Step]                   // fork: 4 cells; plain cobalt: [.fetch, .save, .read]
    public var index: Int                      // highlighted cell
    public var finished: Bool                  // .done: every cell "past"

    public init(steps: [Step], index: Int, finished: Bool) {
        self.steps = steps
        self.index = index
        self.finished = finished
    }
}

public enum PickerAction: Sendable { case save, webp }
public enum ActionStatus: Sendable, Equatable { case idle, working, done, failed(PipelineFailure) }

/// Where "save to photos" is while `photos == .working`: the original is fetched first when the
/// device does not have it (a large file: `downloading` carries the real byte counts), then handed
/// to Photos. `idle` otherwise.
public enum PhotosStep: Sendable, Equatable {
    case idle
    case downloading(TransferProgress)
    case adding
}

public struct Frame: @unchecked Sendable, Equatable {
    public let index: Int
    public let image: CGImage

    init(index: Int, image: CGImage) {
        self.index = index
        self.image = image
    }

    public static func == (lhs: Frame, rhs: Frame) -> Bool {
        lhs.index == rhs.index && lhs.image === rhs.image
    }
}
