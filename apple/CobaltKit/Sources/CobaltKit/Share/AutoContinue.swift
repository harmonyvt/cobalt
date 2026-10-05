import Foundation

#if canImport(UIKit)
import UIKit
#endif

// The share sheet's automatic "continue in background" (CONTRACT-SYNC.md decisions 1 to 5). The
// types are public and compile everywhere (the logic lives in `ShareCore`, which the Mac test run
// covers); `ShareModel` (iOS only) forwards them.

/// Where the sheet's countdown is.
public enum AutoContinue: Sendable, Equatable {
    /// The setting is off, or this run never counts: a file share, plain cobalt, a picker post, a
    /// server that does not finish a save unpolled.
    case off
    /// Waiting for the server to hold the save.
    case armed
    /// Running. `seconds` is the wait in force (after the 10 s floor for VoiceOver / Switch Control).
    case counting(endsAt: Date, seconds: Int)
    /// Stopped for good: it never restarts in this sheet.
    case stopped(AutoContinueStop)
    /// The countdown ended and the sheet is closing (`continueInBackground()` or, when the save had
    /// finished, the close path).
    case fired
}

/// What stops it. The save finishing does not (the owner chose "close anyway", CONTRACT-SYNC 10.1).
public enum AutoContinueStop: Sendable, Equatable { case stay, interaction, failed }

/// Whether the owner is using VoiceOver or Switch Control: the countdown then waits at least 10 s
/// (WCAG 2.2.1, timing adjustable).
enum AssistiveTech {
    static let floorSeconds = 10

    @MainActor static var isRunning: Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        return false
        #endif
    }
}
