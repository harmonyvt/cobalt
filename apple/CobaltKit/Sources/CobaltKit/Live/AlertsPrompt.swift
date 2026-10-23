import Foundation

/// The "turn on notifications and live activities" sheet (iOS): when it rises and what its button does. Pure, so
/// the rule is tested here; the app reads the system's answers (UNUserNotificationCenter, ActivityAuthorizationInfo)
/// and keeps the snooze in UserDefaults.
public enum AlertsPrompt {
    /// The system's notification permission, as far as the sheet cares.
    public enum Notifications: Sendable, Equatable {
        case notAsked     // .notDetermined: the system prompt can still be shown
        case off          // .denied: only the Settings app can turn it on
        case on           // .authorized, .provisional, .ephemeral
    }

    /// What the sheet's one button does.
    public enum Action: Sendable, Equatable {
        /// Show the system prompt (then, if live activities are still off, open Settings).
        case ask
        /// Open the app's page in the Settings app, where both switches are.
        case openSettings
    }

    /// "not now" keeps the sheet away this long.
    public static let snooze: TimeInterval = 7 * 24 * 3600

    /// The sheet rises while the key works (with no key nothing runs, so nothing would show), something is off and
    /// it is not snoozed.
    public static func shouldShow(
        notifications: Notifications, liveActivities: Bool, keyValid: Bool, snoozedUntil: Date?, now: Date
    ) -> Bool {
        guard keyValid, !allOn(notifications: notifications, liveActivities: liveActivities) else { return false }
        if let snoozedUntil, snoozedUntil > now { return false }
        return true
    }

    public static func allOn(notifications: Notifications, liveActivities: Bool) -> Bool {
        notifications == .on && liveActivities
    }

    public static func action(notifications: Notifications) -> Action {
        notifications == .notAsked ? .ask : .openSettings
    }
}
