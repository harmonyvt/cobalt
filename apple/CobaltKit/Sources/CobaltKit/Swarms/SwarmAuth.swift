import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The gate in front of the two calls that spend money or change things: approve and apply (apple/CONTRACT-SWARMS.md 3).
/// `SwarmStore` asks before it sends either; a "no" throws `SwarmError.notConfirmed` and nothing is sent. Previews and
/// tests inject their own.
public protocol OwnerCheck: Sendable {
    /// Asks the person at the device (Face ID, Touch ID or the passcode). `reason` is the line the system sheet shows.
    func confirm(reason: String) async -> Bool
}

/// Face ID, Touch ID, or the device passcode (`.deviceOwnerAuthentication`), asked every time: a fresh `LAContext` per call,
/// so the system never reuses an earlier answer. A device with no passcode at all has nothing to prove, so it passes (the
/// same rule as the hidden album's lock, `HiddenLock`).
public struct LocalOwnerCheck: OwnerCheck {
    public init() {}

    public func confirm(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let code = (error as? LAError)?.code, code == .passcodeNotSet { return true }
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError {
            return error.code == .passcodeNotSet
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
}

/// An `OwnerCheck` with a fixed answer, for previews and tests. `reasons` is every line it was asked, in order.
public final class FixedOwnerCheck: OwnerCheck, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer: Bool
    private var _reasons: [String] = []

    public init(answer: Bool = true) { _answer = answer }

    public var answer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    public var reasons: [String] { lock.withLock { _reasons } }

    public func confirm(reason: String) async -> Bool {
        lock.withLock {
            _reasons.append(reason)
            return _answer
        }
    }
}

/// What a swarm call refused with, plus the one the app itself raises (`notConfirmed`). `from(_:)` classifies anything a
/// call can throw.
public enum SwarmError: Error, Sendable, Equatable {
    /// The owner backed out of Face ID / Touch ID: nothing was sent.
    case notConfirmed
    /// No swarm is shown (the store has nothing to act on).
    case notShown
    /// An action needs the plan's hash and the caller has none.
    case missingHash
    /// The action is a link (check, open), not a call.
    case notACall
    /// `404 error.swarm.not_found`.
    case notFound
    /// `409 error.swarm.not_awaiting`: it was answered already.
    case notAwaiting
    /// `409 error.swarm.hash_mismatch`: the plan changed since the screen loaded.
    case hashMismatch
    /// `410 error.swarm.expired`.
    case expired
    /// `403 error.swarm.owner_only`: this key cannot answer (only the phone's own session can).
    case ownerOnly
    /// `429 error.swarm.busy`: as many swarms as may run at once are running (APP-API-CONTRACT 64).
    case busy
    /// `429 error.swarm.daily_cap`.
    case dailyCap
    /// `409 error.swarm.over_cap`.
    case overCap
    /// `409 error.swarm.count_mismatch`: the apply would change a different number of changes than the button showed.
    case countMismatch
    /// `409 error.swarm.not_running`: a message to a swarm that is not running.
    case notRunning
    /// `409 error.swarm.not_ready`/`503 error.swarm.not_ready`: nothing to apply yet, or the server is not migrated.
    case notReady
    /// `503 error.swarm.off`: swarms are off on this server.
    case off
    /// `400 error.swarm.bad_spec`.
    case badRequest
    /// The server could not be reached.
    case offline
    case other

    /// The error a wire code names; nil for any other code.
    public init?(code: String) {
        switch code {
        case "error.swarm.not_found": self = .notFound
        case "error.swarm.not_awaiting": self = .notAwaiting
        case "error.swarm.hash_mismatch": self = .hashMismatch
        case "error.swarm.expired": self = .expired
        case "error.swarm.owner_only": self = .ownerOnly
        case "error.swarm.busy": self = .busy
        case "error.swarm.daily_cap": self = .dailyCap
        case "error.swarm.over_cap": self = .overCap
        case "error.swarm.count_mismatch": self = .countMismatch
        case "error.swarm.not_running": self = .notRunning
        case "error.swarm.not_ready": self = .notReady
        case "error.swarm.off": self = .off
        case "error.swarm.bad_spec": self = .badRequest
        default: return nil
        }
    }

    /// Any error a swarm call can throw, as a `SwarmError` (a client that predates the routes is `.off`).
    public static func from(_ error: Error) -> SwarmError {
        switch error {
        case let e as SwarmError:
            return e
        case PipelineFailure.unsupported:
            return .off
        case let e as CobaltError:
            switch e {
            case .network: return .offline
            case .api(let code, _): return SwarmError(code: code) ?? .other
            default: return .other
            }
        case let e as URLError:
            return e.code == .cancelled ? .other : .offline
        default:
            return .other
        }
    }

    /// A line in the app's voice for each refusal.
    public var words: String {
        switch self {
        case .notConfirmed: return "nothing was sent"
        case .notShown: return "open a swarm first"
        case .missingHash: return "open the swarm to answer it"
        case .notACall: return "that opens the app"
        case .notFound: return "that swarm is gone"
        case .notAwaiting: return "it was answered already"
        case .hashMismatch: return "the plan changed: look again"
        case .expired: return "it expired: ask again"
        case .ownerOnly: return "only this phone can answer"
        case .busy: return "too many swarms are running at once: wait for one to end"
        case .dailyCap: return "today's swarm budget is spent"
        case .overCap: return "it already spent its cap"
        case .countMismatch: return "the number of changes moved on: look again"
        case .notRunning: return "it is not running"
        case .notReady: return "nothing to apply yet"
        case .off: return "swarms are off on this server"
        case .badRequest: return "that did not look right"
        case .offline: return "could not reach the server"
        case .other: return "something went wrong"
        }
    }
}
