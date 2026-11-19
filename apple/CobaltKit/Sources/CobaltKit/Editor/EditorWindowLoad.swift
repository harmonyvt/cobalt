import Foundation

// What the editor window (Mac) or full-screen cover (iPhone, iPad) shows while a project is not on screen, and when that
// window or cover should go away (apple/CONTRACT-EDITOR.md 4.2, 4.7). The screen owns the task; this is only the decisions,
// so a closed edit, a blank id, and a load that never answers each end somewhere other than the opening skeleton.

/// Where an open stands. `opening`'s date is when it started, so a load that never answers can expire.
public enum EditorOpenPhase: Equatable, Sendable {
    case idle
    case opening(String, Date)
    case failed(String, EditError)
}

/// How an open finished. `cancelled` is a load the owner left, or one the store refused (`unsaved`).
public enum EditorOpenResult: Equatable, Sendable {
    case opened
    case notFound
    case cancelled
    case failed(EditError)
}

/// What the window or cover draws. `dismiss` means there is nothing to show: close, and if the scene is still up say so
/// with a close button. It is never the opening skeleton.
public enum EditorWindowPresentation: Equatable, Sendable {
    case editor
    case loading
    case failed(EditError)
    case dismiss
}

/// One open at a time. A newer `begin` or a `dismiss` makes an older `finish` a no-op, so a load that returns after the
/// owner closed the window cannot put the opening skeleton back.
public struct EditorOpenAttempt: Equatable, Sendable {
    public private(set) var attempt = 0
    public private(set) var phase: EditorOpenPhase = .idle

    public init() {}

    public enum Start: Equatable, Sendable {
        /// `attempt` owns this open of `projectID` (already trimmed).
        case started(Int, String)
        /// The id was empty. `phase` is the failure; nothing should be fetched.
        case rejected(Int)
    }

    /// Starts an open. A blank id fails immediately (`missing`) and does not enter `opening`.
    public mutating func begin(_ projectID: String, now: Date) -> Start {
        attempt += 1
        let id = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            phase = .failed("", .other("missing"))
            return .rejected(attempt)
        }
        phase = .opening(id, now)
        return .started(attempt, id)
    }

    /// Records `result` when `mine` is still the open on screen. A stale attempt leaves `phase` alone and returns false.
    @discardableResult
    public mutating func finish(_ mine: Int, projectID: String, result: EditorOpenResult) -> Bool {
        guard mine == attempt else { return false }
        phase = EditorWindowLoad.phase(after: result, projectID: projectID)
        return true
    }

    /// The owner left the opening screen. The in-flight open no longer owns the window.
    public mutating func dismiss() {
        attempt += 1
        phase = .idle
    }

    /// Moves an `opening` that has run out of time to `failed`. Anything else stays.
    public mutating func timeout(now: Date, limit: TimeInterval = EditorWindowLoad.timeout) {
        phase = EditorWindowLoad.expiring(phase, now: now, limit: limit)
    }
}

public enum EditorWindowLoad {
    /// How long `opening` may spin before it becomes a failure the owner can close.
    public static let timeout: TimeInterval = 20

    /// The screen to show. A session always wins, so a late failure cannot cover an editor that did open.
    public static func presentation(
        hasSession: Bool, phase: EditorOpenPhase, now: Date, limit: TimeInterval = timeout
    ) -> EditorWindowPresentation {
        if hasSession { return .editor }
        switch expiring(phase, now: now, limit: limit) {
        case .idle:
            return .dismiss
        case .opening(let id, _):
            if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed(.other("missing")) }
            return .loading
        case .failed(_, let error):
            return .failed(error)
        }
    }

    /// `opening` past `limit` becomes `timed out` (or `missing` when the id is blank). Other phases stay.
    public static func expiring(_ phase: EditorOpenPhase, now: Date, limit: TimeInterval = timeout) -> EditorOpenPhase {
        guard case .opening(let id, let since) = phase else { return phase }
        guard now.timeIntervalSince(since) >= limit else { return phase }
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed(id, .other("missing")) }
        return .failed(id, .other("timed out"))
    }

    public static func phase(after result: EditorOpenResult, projectID: String) -> EditorOpenPhase {
        switch result {
        case .opened, .notFound, .cancelled:
            return .idle
        case .failed(let error):
            return .failed(projectID, error)
        }
    }

    /// The store's error, as an open's result. `notFound` closes onto the screen underneath; a cancel or an unsaved
    /// editor does not become a "couldn't open" card.
    public static func result(of error: EditError) -> EditorOpenResult {
        switch error {
        case .notFound:
            return .notFound
        case .other("unsaved"), .other("cancelled"):
            return .cancelled
        default:
            return .failed(error)
        }
    }

    /// A load that finished after the owner moved on published a session anyway. Drop it, unless this attempt still owns
    /// the screen or a newer open is about to take that session over.
    public static func shouldDropAbandonedSession(
        stillOwns: Bool, phase: EditorOpenPhase, openedProjectID: String, sessionProjectID: String?
    ) -> Bool {
        guard !stillOwns else { return false }
        guard let sessionProjectID, sessionProjectID == openedProjectID else { return false }
        if case .opening(let id, _) = phase, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }
}
