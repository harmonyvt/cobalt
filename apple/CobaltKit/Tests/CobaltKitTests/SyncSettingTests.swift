import Foundation
import Testing
@testable import CobaltKit

// settings › "library sync": the stored switch behind `SyncFeature`.
@Suite("sync setting")
struct SyncSettingTests {
    @Test func startsOffAndStoresTheChoiceUnderTheEngineKey() {
        let defaults = UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults, keychain: .memory())

        #expect(!settings.syncEngine)                                        // off by default
        #expect(!SyncFeature.isEnabled(defaults))

        settings.syncEngine = true
        #expect(settings.syncEngine)
        #expect(SyncFeature.isEnabled(defaults))                             // what the next launch reads
        #expect(defaults.bool(forKey: "sync.engine"))

        settings.syncEngine = false
        #expect(!SyncFeature.isEnabled(defaults))
    }
}
