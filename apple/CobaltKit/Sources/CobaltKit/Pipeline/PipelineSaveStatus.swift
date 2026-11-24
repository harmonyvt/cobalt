import Foundation

// What the server says about a save beyond "fetching / saving": which part of the work it is on, which downloader runs
// it and whether it switched (apple 02-PHASE2 2.2.2, 05-API-WIRE-SCHEMAS section 2). Kept next to `PipelineState`, not
// inside it: `.saving(bytes:total:since:)` is read by the Live Activity, the widgets, the menu bar and the share sheet,
// and they say "saving" for either part.

/// The part of a link save the server is on, as `GET /studio/<sid>` says it (`step`).
public enum SavePhase: Sendable, Equatable {
    /// The server is reading the post from its site (`fetching`, `reading`): "downloading from x.com · 18.1 of 37.6 MB".
    case downloading
    /// The server is writing the file to the library (`storing`): "storing in your library · 72%".
    case storing
    /// Not said: a server without steps, a queued save, a run that has not been answered yet, plain cobalt.
    case unknown
}

/// What the last `GET /studio/<sid>` said about how the save is going. `SaveStatus()` is "nothing said yet".
public struct SaveStatus: Sendable, Equatable {
    public var phase: SavePhase = .unknown
    /// The downloader that runs the save, once the server says so.
    public var engine: SaveEngine?
    /// The downloader that is starting up: only while the server says `waking`.
    public var wakingEngine: SaveEngine?
    /// The save switched downloaders: the one that failed, and the code that made it switch.
    public var fallbackFrom: SaveEngine?
    public var fallbackCode: String?
    /// The server's own word on waking (never the device's 1.5 s guess). False until the server has spoken.
    public var waking = false

    public init() {}

    /// What a reply says. `reading` and `storing` are never waking, whatever the field says.
    init(session s: StudioSession) {
        switch s.step {
        case .fetching, .reading: phase = .downloading
        case .storing: phase = .storing
        case .queued, nil: phase = .unknown
        }
        engine = s.engine
        fallbackFrom = s.fallbackFrom
        fallbackCode = s.fallbackCode
        waking = Self.isWaking(s)
        wakingEngine = waking ? s.wakingEngine : nil
    }

    /// The server's `waking`, read the one way every flow reads it: a save that is reading or storing has long been awake,
    /// and an older server without the field never says it.
    static func isWaking(_ s: StudioSession) -> Bool {
        switch s.step {
        case .reading, .storing: return false
        case .queued: return false
        case .fetching, nil: return s.waking ?? false
        }
    }

    /// The save switched downloaders ("switched to yt-dlp").
    public var switched: Bool { fallbackFrom != nil }
}

/// Where the copy of this run's file on this device stands, apart from the server's copy (apple 02-PHASE2 2.2.4). The
/// library copy is what counts: a failed device copy never fails the run, it says so and offers to try again.
public enum LocalCopyState: Sendable, Equatable {
    /// "keep videos on device" is off, or nothing has been asked yet.
    case notRequested
    /// The original (or the webp) is coming to this device.
    case downloading(TransferProgress)
    case savedOnDevice
    /// It did not arrive. `code` is an `error.app.*` / `http.*` code; `Copy.localCopyFailed` says it in words.
    case failed(code: String)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// What a retry of the device copy has to do again.
enum LocalCopyJob: Equatable {
    case original(session: String, media: MediaInfo)
    case webp(session: String, result: WebpResult)
}
