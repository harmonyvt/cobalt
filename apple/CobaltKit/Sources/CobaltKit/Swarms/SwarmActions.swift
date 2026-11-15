import Foundation

/// The calls a Live Activity button (or a notification action) makes without opening the app: the App Intents of wave 2 hold
/// the Face ID gate (`authenticationPolicy = .requiresAuthentication`) and then run this. It sends with the client it is
/// given, which is the device's own session, never a client key.
public enum SwarmActionRunner {
    /// approve (`/approve` with the plan's hash), apply (`/apply` with the hash, `skip_clashes: true` and the `count` the button
    /// showed, so a list that moved on is refused with `SwarmError.countMismatch`), decline, stop. The
    /// answer is the swarm as it is now, for `JobLiveState(swarm:now:)`. `check` and `open` are links, not calls
    /// (`SwarmError.notACall`); approve and apply without a hash are refused (`SwarmError.missingHash`), since the hash is what
    /// says "the plan you looked at".
    @discardableResult
    public static func run(
        _ action: SwarmLiveAction, swarm id: String, hash: String?, count: Int? = nil, client: any CobaltClient
    ) async throws -> Swarm {
        switch action {
        case .approve:
            guard let hash, !hash.isEmpty else { throw SwarmError.missingHash }
            return try await client.approveSwarm(id: id, hash: hash)
        case .apply:
            guard let hash, !hash.isEmpty else { throw SwarmError.missingHash }
            return try await client.applySwarm(id: id, hash: hash, skipClashes: true, count: count)
        case .decline:
            return try await client.declineSwarm(id: id)
        case .stop:
            return try await client.stopSwarm(id: id)
        case .check, .open:
            throw SwarmError.notACall
        }
    }
}
