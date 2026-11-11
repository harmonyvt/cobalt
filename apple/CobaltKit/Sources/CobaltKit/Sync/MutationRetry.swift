import Foundation

/// What `TitleQueue` already does for one field, shared with the outbox: a 400 or a 404 will not
/// change by asking again, and a lost connection waits. `TitleQueue.isFinal` stays this function.
enum MutationRetry {
    /// Past this a queued edit is dropped. The same week `TitleQueue` keeps a title.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// 1s, 2s, 4s, … capped at five minutes. `tries` is how many sends have already failed.
    static func backoff(tries: Int) -> TimeInterval {
        let shift = min(max(tries - 1, 0), 9)
        return min(300, pow(2, Double(shift)))
    }

    /// The server's answer will not change by asking again: the item is gone (404) or the title is not
    /// one it takes (400). Identical to the check `TitleQueue` used before this was shared.
    static func isFinal(_ error: Error) -> Bool {
        if let failure = error as? PipelineFailure, case .server(let code) = failure {
            return code == "error.library.not_found" || code == "error.library.bad_title"
        }
        if let e = error as? CobaltError {
            switch e {
            case .api(_, let status), .invalidResponse(let status): return status == 404 || status == 400
            default: return false
            }
        }
        return false
    }

    /// What the outbox does with a failed send.
    /// `rekey`: the server holds another body under this `Idempotency-Key`. Asking again under the
    /// same key gets the same answer, and the edit itself was never judged, so it is neither a retry
    /// nor a refusal: it goes out again under a new key.
    enum Outcome: Equatable, Sendable { case succeeded, refused, retry, rekey }

    static let keyConflictCode = "error.idempotency.conflict"

    static func attempt(_ error: Error, kind: SyncOp.Kind) -> Outcome {
        if isKeyConflict(error) { return .rekey }
        if kind == .delete, isMissing(error) { return .succeeded }   // already gone: the delete stands
        if isBusy(error) || isAuth(error) || isNetwork(error) { return .retry }
        if isFinal(error) { return .refused }
        if let status = httpStatus(error), status == 409 || status == 422 || status == 400 { return .refused }
        if error is SyncError {
            if case .refused = error as? SyncError { return .refused }
            return .retry
        }
        return .retry
    }

    private static func isKeyConflict(_ error: Error) -> Bool {
        if let e = error as? SyncError, e == .keyConflict { return true }
        if let e = error as? CobaltError, case .api(let code, _) = e { return code == keyConflictCode }
        if let failure = error as? PipelineFailure, case .server(let code) = failure { return code == keyConflictCode }
        return false
    }

    private static func isMissing(_ error: Error) -> Bool {
        if let failure = error as? PipelineFailure {
            if failure == .expired { return true }
            if case .server(let code) = failure, code == "error.library.not_found" { return true }
        }
        if let e = error as? CobaltError {
            switch e {
            case .api(let code, let status): return status == 404 || code == "error.library.not_found"
            case .invalidResponse(let status): return status == 404
            default: return false
            }
        }
        return false
    }

    private static func isBusy(_ error: Error) -> Bool {
        if let failure = error as? PipelineFailure, failure == .serverBusy { return true }
        if let e = error as? CobaltError, case .api(let code, _) = e {
            return code == "error.library.busy" || code == "error.studio.busy"
        }
        return false
    }

    private static func isAuth(_ error: Error) -> Bool {
        if let failure = error as? PipelineFailure, failure == .keyInvalid || failure == .keyMissing { return true }
        if let e = error as? CobaltError {
            switch e {
            case .noAPIKey: return true
            case .api(_, let status): return status == 401 || status == 403
            default: return false
            }
        }
        return false
    }

    private static func isNetwork(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let failure = error as? PipelineFailure, failure == .unreachable { return true }
        if let e = error as? CobaltError, case .network = e { return true }
        return false
    }

    private static func httpStatus(_ error: Error) -> Int? {
        if let e = error as? CobaltError {
            switch e {
            case .api(_, let status), .invalidResponse(let status): return status
            default: return nil
            }
        }
        return nil
    }
}
