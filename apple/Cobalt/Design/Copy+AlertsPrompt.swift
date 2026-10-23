import Foundation

/// Copy for the sheet that asks for notifications and live activities (`AlertsPromptSheet`). All lowercase.
extension Copy {
    enum AlertsPrompt {
        static let title = "see your saves from anywhere"
        static let body = "turn on notifications and live activities, and capystore shows each download, save and render on the lock screen and in the dynamic island, and tells you when it's done, even with the app closed."
        static let notifications = "notifications"
        static let liveActivities = "live activities"
        static let on = "on"
        static let off = "off"
        static let turnOn = "turn on"
        static let openSettings = "open settings"
        static let notNow = "not now"
        static let settingsHint = "in settings, turn on notifications and live activities for capystore, then come back."
    }
}
