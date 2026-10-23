import Foundation
import Testing
@testable import CobaltKit

struct AlertsPromptTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func risesOnlyWithAWorkingKeyAndSomethingOff() {
        #expect(AlertsPrompt.shouldShow(notifications: .notAsked, liveActivities: true, keyValid: true, snoozedUntil: nil, now: now))
        #expect(AlertsPrompt.shouldShow(notifications: .on, liveActivities: false, keyValid: true, snoozedUntil: nil, now: now))
        #expect(AlertsPrompt.shouldShow(notifications: .off, liveActivities: true, keyValid: true, snoozedUntil: nil, now: now))
        #expect(!AlertsPrompt.shouldShow(notifications: .on, liveActivities: true, keyValid: true, snoozedUntil: nil, now: now))
        #expect(!AlertsPrompt.shouldShow(notifications: .off, liveActivities: false, keyValid: false, snoozedUntil: nil, now: now))
    }

    @Test func notNowKeepsItAwayForAWeek() {
        let until = now.addingTimeInterval(AlertsPrompt.snooze)
        #expect(!AlertsPrompt.shouldShow(notifications: .off, liveActivities: false, keyValid: true, snoozedUntil: until, now: now))
        #expect(AlertsPrompt.shouldShow(
            notifications: .off, liveActivities: false, keyValid: true, snoozedUntil: until, now: until.addingTimeInterval(1)))
    }

    @Test func theButtonAsksFirstThenSendsToSettings() {
        #expect(AlertsPrompt.action(notifications: .notAsked) == .ask)
        #expect(AlertsPrompt.action(notifications: .off) == .openSettings)
        #expect(AlertsPrompt.action(notifications: .on) == .openSettings)
    }
}
