#if DEBUG
import ActivityKit
import CobaltKit
import Foundation

/// Simulator evidence for the quick card in the REAL extension (debug builds only). Off unless the
/// host file `/tmp/cobalt-sq/share-debug.json` exists (the simulator reads the Mac's /tmp):
///
///   {"scenario": "coldStart"}       run the full sheet over `PreviewClient` (no server, no key needed)
///   {"quick": true}                 with a scenario: the quick card instead (it is not presented otherwise)
///   {"probeActivity": true}         also call `Activity.request` from the extension and log the answer
///
/// Log lines carry `[sharequick]` (`xcrun simctl spawn <device> log stream --predicate 'eventMessage CONTAINS "[sharequick]"'`).
@MainActor
enum ShareDebug {
    private struct Flags: Decodable {
        var scenario: String?
        var probeActivity: Bool?
        /// Show the (no longer presented) quick card instead of the full sheet.
        var quick: Bool?
    }

    private static let flags: Flags? = {
        guard let data = FileManager.default.contents(atPath: "/tmp/cobalt-sq/share-debug.json") else { return nil }
        return try? JSONDecoder().decode(Flags.self, from: data)
    }()

    static func log(_ message: String) {
        NSLog("[sharequick] %@", message)
    }

    /// The sheet over `PreviewClient` when a scenario is set; nil means "build the live one".
    static func model(
        inputItems: [NSExtensionItem], openApp: @escaping @MainActor (URL) async -> Bool,
        complete: @escaping @MainActor () -> Void
    ) async -> ShareModel? {
        guard let raw = flags?.scenario, let scenario = PreviewScenario(rawValue: raw) else { return nil }
        let quick = flags?.quick ?? false
        log("debug scenario \(raw) quick=\(quick) items=\(inputItems.count)")
        let model = ShareModel.debugPreview(scenario, quick: quick, openApp: openApp, complete: complete)
        if let url = URL(string: scenario.pasteText) { model.pipeline.start(link: url) }
        return model
    }

    /// Asks ActivityKit for a Live Activity from inside the share extension and logs what it says
    /// (CONTRACT-SHARE-QUICK.md decision 1: the documented answer is that only the app can).
    static func probeLiveActivity() {
        guard flags?.probeActivity == true else { return }
        let info = ActivityAuthorizationInfo()
        log("probe: areActivitiesEnabled=\(info.areActivitiesEnabled)")
        let attributes = CobaltActivityAttributes(LiveRunAttributes(
            run: UUID(), input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "share"))
        let state = LiveContentState(stage: .fetching, rail: 0, since: Date().timeIntervalSince1970)
        do {
            let activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
            log("probe: Activity.request SUCCEEDED id=\(activity.id)")
        } catch {
            log("probe: Activity.request FAILED \(String(reflecting: error))")
        }
    }
}
#endif
