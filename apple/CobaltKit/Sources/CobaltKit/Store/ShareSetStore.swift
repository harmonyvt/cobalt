import Foundation
import Observation

/// The gallery share links the owner has made (APP-API-CONTRACT 24): `GET /share/sets` for the links tab, `POST` from
/// the library's select bar, `DELETE` to revoke. Reads the app model's current client on every call, so a server or key
/// change is picked up (`reset()` forgets what the old server listed).
@MainActor @Observable
public final class ShareSetStore {
    public enum State: Equatable, Sendable {
        case idle
        /// A `refresh()` is running. `sets` still holds what was listed before, if anything.
        case loading
        case loaded
        /// The last `refresh()` failed, with a message to show. `sets` still holds what was listed before.
        case failed(String)
    }

    /// The live sets, newest first.
    public private(set) var sets: [ShareSet] = []
    public private(set) var state: State = .idle

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`: an answer from the old server arriving later is dropped.
    @ObservationIgnored private var generation = 0

    init(context: PipelineContext) {
        self.ctx = context
    }

    /// Lists the sets again (`GET /share/sets`). A refresh that is already running is not doubled.
    public func refresh() async {
        guard state != .loading else { return }
        let started = generation
        state = .loading
        do {
            let listed = try await ctx.client.shareSets()
            guard started == generation else { return }
            sets = listed.sorted { $0.createdAt > $1.createdAt }
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(Self.message(for: error))
        }
    }

    /// Makes a link (`POST /share/sets`) and puts it first. Throws `ShareSetError` (`.notPublic(ids)` names the files
    /// that are private now) or whatever the transport threw; nothing is inserted then.
    @discardableResult
    public func create(items: [String], title: String?) async throws -> ShareSet {
        let started = generation
        let made = try await ctx.client.createShareSet(items: items, title: title)
        if started == generation {
            sets.removeAll { $0.id == made.id }
            sets.insert(made, at: 0)
        }
        return made
    }

    /// Revokes a link (`DELETE /share/sets/<id>`) and drops its row. A set the server no longer knows (`.notFound`) is
    /// gone already, so its row goes too; any other error leaves the row and is thrown.
    public func revoke(_ id: String) async throws {
        let started = generation
        do {
            try await ctx.client.revokeShareSet(id: id)
        } catch ShareSetError.notFound {
            // already gone
        }
        if started == generation { sets.removeAll { $0.id == id } }
    }

    /// Another server or key: nothing from the old one is kept.
    func reset() {
        generation += 1
        sets = []
        state = .idle
    }

    /// A short line for the failed state (the UI may word it its own way from the error kind).
    static func message(for error: Error) -> String {
        switch error {
        case ShareSetError.unavailable: return "The server can't make links right now."
        case ShareSetError.notFound, ShareSetError.badRequest, ShareSetError.notPublic: return "The server refused the request."
        case CobaltError.network: return "Can't reach the server."
        case CobaltError.noAPIKey: return "No API key."
        case CobaltError.api(let code, _) where code.hasPrefix("error.api.auth.key."): return "The API key was refused."
        case is CancellationError: return "Cancelled."
        default: return "Something went wrong."
        }
    }
}
