import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

extension AppModel {
    /// The Settings row's value (CONTRACT-LIVE.md 2.2): whether the island follows a run while cobalt
    /// is closed, only while it is open, or not at all.
    public var liveStatus: LiveStatus {
        #if os(iOS) && canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .off }
        if capabilities.livePush, LiveEnvironment.current != nil { return .pushed }
        return .localOnly
        #else
        return .unavailable
        #endif
    }
}
