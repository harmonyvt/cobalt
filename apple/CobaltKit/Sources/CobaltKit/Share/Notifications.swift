import Foundation
import UserNotifications

/// Local notifications for the share handoff. The strings live here, not in the app's `Copy.swift`,
/// because the share extension posts them before any UI exists (the one exception to "all copy in UI").
enum Notifications {
    enum Kind: String, Sendable, CaseIterable {
        case stillMaking     // closed the sheet mid-render
        case stillSaving     // closed the sheet mid-save (no notify bridge to tell the owner when it is done)
        case trimInCobalt    // handoff that could not open the app itself
        case webpReady       // a run's webp finished while the app was not active
        case saved           // a run's save finished while the app was not active
        case failed          // a run ended in an error while the app was not active

        var title: String {
            switch self {
            case .stillMaking: return "cobalt is still making your webp"
            case .stillSaving: return "cobalt is still saving your video"
            case .trimInCobalt: return "your clip is saved · tap to trim in cobalt"
            case .webpReady: return "your webp is ready"
            case .saved: return "your video is saved"
            case .failed: return "cobalt couldn't finish that · tap to see why"
            }
        }
    }

    /// The `userInfo["url"]` the app delegate opens on tap. With the run's studio session when it has
    /// one (`?session=<sid>`): a build re-signed without the app group cannot read the share sheet's job
    /// record, and the session is then all the app needs to follow the run (CONTRACT-SHARE-QUICK.md).
    /// `trim`: the run is a "trim in cobalt" handoff (`&trim=1`), for the same reason.
    static func url(forJob id: UUID, session: String? = nil, trim: Bool = false) -> String {
        let plain = "cobalt-apple://job/\(id.uuidString)"
        guard let session, !session.isEmpty else { return plain }
        var parts = URLComponents(string: plain)
        parts?.queryItems = [URLQueryItem(name: "session", value: session)] + (trim ? [URLQueryItem(name: "trim", value: "1")] : [])
        return parts?.string ?? plain
    }

    /// Where "your webp is ready" opens: the library (the finished webp is in the store, the job
    /// record is gone).
    static let libraryURL = "cobalt-apple://library"

    /// The app, on the save tab.
    static let openURL = "cobalt-apple://open"

    /// "your webp is ready" opens the library; everything else opens its run (the app follows the job
    /// when it has it, and otherwise lands on the save tab, which is where `openURL` went).
    static func url(for kind: Kind, jobID: UUID, session: String? = nil) -> String {
        switch kind {
        case .webpReady: return libraryURL
        default: return url(forJob: jobID, session: session, trim: kind == .trimInCobalt)
        }
    }

    /// Content and identifier of the request for `kind` (separate from `post` so it can be tested
    /// without a notification center, which does not exist outside an app bundle).
    static func request(_ kind: Kind, jobID: UUID, session: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.sound = .default
        content.threadIdentifier = "cobalt-jobs"
        content.userInfo = ["url": url(for: kind, jobID: jobID, session: session)]
        // one notification per job and kind: posting it again replaces the first
        return UNNotificationRequest(identifier: identifier(kind, jobID: jobID), content: content, trigger: nil)
    }

    /// The app took the job over: its notifications have nothing left to say. (Never called in
    /// previews or tests: there is no notification center outside an app bundle.)
    static func clear(jobID: UUID) {
        let ids = Kind.allCases.map { identifier($0, jobID: jobID) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func identifier(_ kind: Kind, jobID: UUID) -> String { "job-\(jobID.uuidString)-\(kind.rawValue)" }

    /// Asked in context, never at launch and never on a plain run: when the owner closes a run that
    /// still has work in flight, or the share sheet closes mid-render, which is when "your webp is
    /// ready" / "cobalt is still making your webp" have a reason to exist. Full alerts, not
    /// provisional (owner's call). Only asks while the answer is undetermined; the system shows
    /// its prompt once, and a later call after "don't allow" does nothing.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// `userInfo["url"]` is the `cobalt-apple://job/<uuid>` link the app opens on tap.
    static func post(_ kind: Kind, jobID: UUID, session: String? = nil) async {
        try? await UNUserNotificationCenter.current().add(request(kind, jobID: jobID, session: session))
    }
}

/// The seam the share logic posts through, so it can be tested without a notification center.
protocol NotificationPosting: Sendable {
    func post(_ kind: Notifications.Kind, jobID: UUID) async
    /// With the run's session in the link (the share sheet's notifications). Defaults to `post(_:jobID:)`.
    func post(_ kind: Notifications.Kind, jobID: UUID, session: String?) async
    /// Asks for permission to notify (once the answer is still open). Previews and tests do nothing.
    func requestAuthorization() async
}

extension NotificationPosting {
    func requestAuthorization() async {}
    func post(_ kind: Notifications.Kind, jobID: UUID, session: String?) async { await post(kind, jobID: jobID) }
}

struct SystemNotifier: NotificationPosting {
    func post(_ kind: Notifications.Kind, jobID: UUID) async {
        await Notifications.post(kind, jobID: jobID)
    }

    func post(_ kind: Notifications.Kind, jobID: UUID, session: String?) async {
        await Notifications.post(kind, jobID: jobID, session: session)
    }

    func requestAuthorization() async {
        await Notifications.requestAuthorizationIfNeeded()
    }
}
