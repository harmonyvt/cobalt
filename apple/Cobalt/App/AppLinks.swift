import CobaltKit
import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Where every `cobalt-apple://` link ends up: `job/<uuid>[?session=<sid>]` and `session/<sid>` (a
/// notification tap, the Live Activity's tap, the share sheet's "open in cobalt", the Hark
/// notification once the server sends its link: `AppModel.openRunLink`, CONTRACT-SHARE-QUICK.md),
/// `open`, `library`, and `copy?url=<https link>` (the Live Activity's "copy link": an activity cannot
/// write to the pasteboard itself, so the link goes to the pasteboard, only if it is a web link, and
/// the app opens on the save tab). Everything but `copy` is the model's.
@MainActor
func handleAppLink(_ url: URL, model: AppModel) {
    #if DEBUG
    DebugHooks.log("handleAppLink \(url.absoluteString)")
    defer { DebugHooks.log("handleAppLink done: \(DebugHooks.describe(model))") }
    #endif
    if url.scheme?.lowercased() == "cobalt-apple", url.host(percentEncoded: false)?.lowercased() == "copy",
       let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
           .first(where: { $0.name == "url" })?.value,
       let target = URL(string: link), ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
        Pasteboard.copy(link)
        model.selectedTab = .save
        #if os(iOS)
        if model.settings.haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        #endif
        return
    }
    #if DEBUG
    if QuickShareDebug.handle(url, model: model) { return }
    #endif
    if model.openRunLink(url) {
        #if DEBUG
        NSLog("[sharequick] app run link %@ -> following run=%@ state=%@", url.absoluteString,
              model.pipeline.state == .idle ? "none" : "yes", String(describing: model.pipeline.state).prefix(40).description)
        #endif
        return
    }
    model.open(url)
}

#if DEBUG
/// Simulator evidence for the quick card's app half (CONTRACT-SHARE-QUICK.md section 7), debug builds
/// only. `xcrun simctl openurl <device> 'cobalt-apple://debug/<what>?scenario=coldStart'`:
///
///   preview-server   the live app talks to `PreviewClient` (its stores and Live Activities stay real)
///   takeover         + a share-sheet job as the quick card leaves it, then the foreground pick-up
///   sessionlink      + a run link with only a session (a build without the app group)
@MainActor
enum QuickShareDebug {
    static func handle(_ url: URL, model: AppModel) -> Bool {
        guard url.host(percentEncoded: false)?.lowercased() == "debug" else { return false }
        let what = url.lastPathComponent
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scenario" }?.value
        let scenario = raw.flatMap(PreviewScenario.init(rawValue:)) ?? .coldStart
        model.debugUsePreviewServer(scenario)
        model.selectedTab = .save
        guard let link = URL(string: scenario.pasteText) else { return true }
        NSLog("[sharequick] app debug %@ scenario=%@", what, scenario.rawValue)
        Task {
            switch what {
            case "takeover":
                let job = await model.debugShareHandoff(link: link)
                NSLog("[sharequick] app took over job=%@ session=%@ run=%@ state=%@",
                      job?.id.uuidString ?? "nil", job?.sessionID ?? "nil",
                      model.pipeline.state == .idle ? "none" : "following", String(describing: model.pipeline.state).prefix(40).description)
            case "sessionlink":
                let opened = await model.debugSessionRunLink(link: link)
                NSLog("[sharequick] app opened %@ state=%@", opened?.absoluteString ?? "nil", String(describing: model.pipeline.state).prefix(40).description)
            default:
                break
            }
        }
        return true
    }
}
#endif

/// The notification taps ("cobalt is still making your webp") arrive from the system's delegate,
/// possibly before the window's content exists: a tap that cold-launches the app is delivered during
/// launch, while the scene's `.task` (which knows the model) has not run yet. The inbox keeps such a
/// link and gives it to the handler the moment one is installed.
@MainActor
final class LinkInbox {
    static let shared = LinkInbox()

    private var pending: [URL] = []
    private(set) var handler: (@MainActor (URL) -> Void)?

    /// Installing the handler delivers what arrived before it.
    func install(_ handler: @escaping @MainActor (URL) -> Void) {
        self.handler = handler
        let waiting = pending
        pending = []
        #if DEBUG
        DebugHooks.log("link inbox handler installed, \(waiting.count) waiting")
        #endif
        for url in waiting { handler(url) }
    }

    func deliver(_ url: URL) {
        guard let handler else {
            pending.append(url)
            #if DEBUG
            DebugHooks.log("link inbox: no handler yet, kept \(url.absoluteString)")
            #endif
            return
        }
        handler(url)
    }

}

/// The system notification center's delegate (both platforms) and the platform's app delegate. SwiftUI
/// owns the app lifecycle; the delegate exists for what it has no scene API for: showing a notification
/// while the app is in front, and the tap on one.
final class CobaltAppDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        // `userInfo["url"]` is the link `Notifications.url(forJob:)` put there.
        let raw = response.notification.request.content.userInfo["url"] as? String
        await MainActor.run {
            #if DEBUG
            DebugHooks.log("notification tap url=\(raw ?? "nil")")
            #endif
            if let raw, let url = URL(string: raw) { LinkInbox.shared.deliver(url) }
        }
    }
}

#if os(iOS)
extension CobaltAppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
}
#else
extension CobaltAppDelegate: NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window: a tap that launches the app is delivered right after this.
        UNUserNotificationCenter.current().delegate = self
    }
}
#endif
