import Foundation

/// The local notification for a swarm that waits for its owner (apple/CONTRACT-SWARMS.md 4): "claude code asks: rename 1,000
/// emotes · about 50¢", with approve and decline on it. The Mac posts it from the app (`SwarmNotifier`); the words, the ids and
/// what to remember live here so `swift test` covers them. The notification center itself is the app's.
public struct SwarmNotice: Hashable, Sendable {
    /// The `UNNotificationCategory` identifier, and its two actions.
    public static let category = "swarm.waiting"
    public static let approveAction = "swarm.approve"
    public static let declineAction = "swarm.decline"

    public var swarm: String
    /// The plan's hash: what the approve action sends.
    public var hash: String
    public var title: String
    public var body: String
    /// `cobalt-apple://swarm/<id>`: a plain tap opens it.
    public var url: String

    /// One notification per swarm: posting again replaces it, answering it elsewhere removes it.
    public var identifier: String { Self.identifier(swarm) }
    public static func identifier(_ swarm: String) -> String { "swarm-\(swarm)" }

    /// `userInfo`: the link, the swarm and the hash (the delegate reads these back).
    public var userInfo: [String: String] { ["url": url, "swarm": swarm, "hash": hash] }

    /// Only a swarm that waits for its plan to be approved has one.
    public init?(swarm s: Swarm) {
        guard s.status == .awaitingApproval, !s.specHash.isEmpty else { return nil }
        swarm = s.id
        hash = s.specHash
        title = "a swarm is waiting for you"
        var line = "\(s.planner ?? "an agent") asks: \(s.name)"
        if let estimate = s.estimateUSD { line += " · about \(SwarmWords.money(estimate.high))" }
        body = line
        url = "cobalt-apple://swarm/\(s.id)"
    }

    /// The swarms in `list` that wait for approval and were not told about before (`seen` is what was remembered), oldest
    /// first. A plan that has already expired is not worth a notification.
    public static func fresh(in list: [Swarm], seen: Set<String>, now: Date) -> [SwarmNotice] {
        list
            .filter { $0.status == .awaitingApproval && !seen.contains($0.id) && ($0.expiresAt.map { $0 > now } ?? true) }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { SwarmNotice(swarm: $0) }
    }

    /// The ids that should be forgotten and whose delivered notification should go: told about, but no longer waiting.
    public static func answered(in list: [Swarm], seen: Set<String>) -> Set<String> {
        let waiting = Set(list.filter { $0.status == .awaitingApproval }.map(\.id))
        let listed = Set(list.map(\.id))
        return seen.intersection(listed).subtracting(waiting)
    }

    /// What the delegate needs back from a notification's `userInfo`.
    public static func decode(userInfo: [AnyHashable: Any]) -> (swarm: String, hash: String)? {
        guard let swarm = userInfo["swarm"] as? String, !swarm.isEmpty, let hash = userInfo["hash"] as? String, !hash.isEmpty else {
            return nil
        }
        return (swarm, hash)
    }
}
