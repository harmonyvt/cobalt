import Foundation
import LocalAuthentication

/// The lock in front of the hidden album (APP-API-CONTRACT 37.7): Face ID, Touch ID or the device passcode, asked each
/// time the album is opened. A thin wrapper over `LAContext` so the screens never touch LocalAuthentication.
///
/// Nothing here remembers a success: the library screen keeps "unlocked" in memory and drops it (see
/// `LibraryController.relockHidden`). Every call builds a fresh `LAContext`, so the system never reuses an earlier
/// answer.
enum HiddenLock {
    typealias Method = Copy.HiddenAlbum.LockMethod

    enum Outcome: Sendable, Equatable {
        /// The owner proved it (or the device has no lock at all, so there is nothing to prove).
        case unlocked
        /// The owner backed out, or the system cancelled the sheet (app moved away): ask again with the button.
        case cancelled
        /// The sheet failed for some other reason.
        case failed
    }

    /// Face ID, Touch ID, or (a device with neither, or a Mac asking for its password) the passcode.
    nonisolated static func method() -> Method {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .passcode
        }
    }

    /// Whether the device can ask at all. A device with no passcode set cannot, and then there is no lock to pass.
    nonisolated static func canAsk() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Asks for the owner (`.deviceOwnerAuthentication`: biometrics, with the passcode as the way out).
    nonisolated static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // no passcode set: the device itself is not locked, so neither is the album
            if let code = (error as? LAError)?.code, code == .passcodeNotSet { return .unlocked }
            return .failed
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .unlocked : .failed
        } catch let error as LAError {
            switch error.code {
            // backing out, the system or the app closing the sheet, or asking while the app is not in front yet: not an
            // error, the button asks again
            case .userCancel, .systemCancel, .appCancel, .notInteractive, .userFallback: return .cancelled
            case .passcodeNotSet: return .unlocked
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}
