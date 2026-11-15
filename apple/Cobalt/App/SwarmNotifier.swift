import CobaltKit
import Foundation
import UserNotifications

/// A swarm that waits for its owner, as a notification with approve and decline on it (apple/CONTRACT-SWARMS.md 4).
///
/// - `registerCategory()` (both platforms, at launch) tells the system the "swarm.waiting" category: approve asks the device
///   to be unlocked (`.authenticationRequired`), decline is drawn as destructive.
/// - `start(_:)` (the Mac only) is a light loop: it reads the swarm list at launch and every 60 s while the app runs, and
///   posts one local notification for each swarm that waits for approval and was not told about before (the ids are kept in
///   UserDefaults). On the iPhone the server's Live Activity is the notification, so nothing runs.
/// - `answer(approve:swarm:hash:)` is what a tap on a button does: approve asks Touch ID first (the store's own owner check),
///   then sends exactly what the Live Activity's button sends (`SwarmIntentHost`, the device's own session); decline sends.
///   A plain tap opens `cobalt-apple://swarm/<id>` like any link.
@MainActor
final class SwarmNotifier {
    static let shared = SwarmNotifier()

    private static let seenKey = "swarmNotifier.told"
    private static let seenLimit = 200
    static let interval: Duration = .seconds(60)

    private weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: launch

    /// The category and its two actions. Merged with whatever else is registered.
    static func registerCategory() {
        guard runsInApp else { return }
        let approve = UNNotificationAction(identifier: SwarmNotice.approveAction, title: "approve", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: SwarmNotice.declineAction, title: "decline", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: SwarmNotice.category, actions: [approve, decline], intentIdentifiers: [], options: [])
        Task {
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories().filter { $0.identifier != SwarmNotice.category }
            categories.insert(category)
            center.setNotificationCategories(categories)
        }
    }

    /// The test runner and previews have no notification center (touching it traps).
    private static var runsInApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// The Mac's loop. A model in preview mode never starts it (it would announce the preview swarms).
    func start(_ model: AppModel) {
        self.model = model
        #if os(macOS)
        guard loop == nil, !model.isPreview, Self.runsInApp else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
        #endif
    }

    // MARK: the loop's one pass

    /// Reads the list, posts what is new, takes down what was answered somewhere else.
    func check() async {
        guard let model, model.capabilities.library, Self.runsInApp else { return }
        await model.swarms.loadList()
        let list = model.swarms.list
        var seen = told
        let center = UNUserNotificationCenter.current()

        let answered = SwarmNotice.answered(in: list, seen: seen)
        if !answered.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: answered.map(SwarmNotice.identifier))
            seen.subtract(answered)
        }

        let fresh = SwarmNotice.fresh(in: list, seen: seen, now: Date())
        if !fresh.isEmpty, await allowed(center) {
            for notice in fresh {
                do {
                    try await center.add(Self.request(notice))
                    seen.insert(notice.swarm)
                } catch {
                    // Not remembered: the next pass tries again.
                }
            }
        }
        remember(seen)
    }

    /// Posting needs the owner's yes. The prompt appears once, at the first swarm that waits (the moment it is wanted).
    private func allowed(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    static func request(_ notice: SwarmNotice) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = SwarmNotice.category
        content.threadIdentifier = "cobalt-swarms"
        content.userInfo = notice.userInfo
        // one per swarm: posting it again replaces it
        return UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
    }

    // MARK: remembered ids

    private var told: Set<String> { Set(defaults.stringArray(forKey: Self.seenKey) ?? []) }

    private func remember(_ ids: Set<String>) {
        defaults.set(Array(ids.sorted().suffix(Self.seenLimit)), forKey: Self.seenKey)
    }

    // MARK: the buttons

    /// A tap on approve or decline. Approve asks Touch ID first; the call is the Live Activity button's.
    static func answer(approve: Bool, swarm: String, hash: String) async {
        let shared = SwarmNotifier.shared
        let center = UNUserNotificationCenter.current()
        do {
            if approve {
                let check = shared.model?.swarms.ownerCheck ?? LocalOwnerCheck()
                guard await check.confirm(reason: "approve this swarm") else { return }
                try await SwarmIntentHost.run(.approve, swarm: swarm, hash: hash)
            } else {
                try await SwarmIntentHost.run(.decline, swarm: swarm, hash: nil)
            }
            center.removeDeliveredNotifications(withIdentifiers: [SwarmNotice.identifier(swarm)])
            await shared.model?.swarms.loadList()
        } catch {
            // Said where the owner is looking: a plain notification that opens the swarm.
            let words: String
            switch error {
            case let e as SwarmError: words = e.words
            case let e as SwarmIntentHostError: words = e.words
            default: words = SwarmError.other.words
            }
            let content = UNMutableNotificationContent()
            content.title = approve ? "couldn't approve that swarm" : "couldn't decline that swarm"
            content.body = words
            content.userInfo = ["url": "cobalt-apple://swarm/\(swarm)"]
            try? await center.add(UNNotificationRequest(identifier: "swarm-error-\(swarm)", content: content, trigger: nil))
        }
    }
}
