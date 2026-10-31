import Foundation
import Observation

/// Settings › account (APP-API-CONTRACT 42.5, 42.6): who is signed in, the signed-in devices and the keys for tools.
/// `AppModel.account`. Idle until `refresh()`; a server change, a sign-out and a new sign-in empty it.
@MainActor @Observable
public final class AccountStore {
    public enum Phase: Sendable, Equatable { case idle, loading, ready, failed }

    public internal(set) var phase: Phase = .idle
    public internal(set) var me: AccountMe?
    /// Active sessions, most recently used first (this device's has `current`).
    public internal(set) var sessions: [AccountSession] = []
    /// Keys for tools, newest first.
    public internal(set) var keys: [AccountKey] = []
    /// The Access sheet is open or the exchange is running (`AppModel.signIn(using:)`).
    public internal(set) var signingIn = false

    @ObservationIgnored let ctx: PipelineContext

    init(context: PipelineContext) {
        self.ctx = context
    }

    func reset() {
        phase = .idle; me = nil; sessions = []; keys = []
    }

    /// The Access email that signed this device in, when the server says.
    public var email: String? { me?.caller.email }
    /// This device signs in with a key pasted before accounts (not a session).
    public var callerIsKey: Bool { me?.caller.kind == .key }
    public var otherSessions: [AccountSession] { sessions.filter { !$0.current } }
    public var oldPasteCount: Int { keys.filter(\.oldPaste).count }

    /// `GET /auth/me`, `/auth/sessions` and `/auth/keys` together. Nothing to ask without a token or on a server without
    /// accounts.
    public func refresh() async {
        guard ctx.capabilities.accounts, ctx.settings.hasAPIKey else { reset(); return }
        if phase != .ready { phase = .loading }
        let client = ctx.client
        do {
            async let meAnswer = client.accountMe()
            async let sessionsAnswer = client.accountSessions()
            async let keysAnswer = client.accountKeys()
            let (m, s, k) = try await (meAnswer, sessionsAnswer, keysAnswer)
            me = m
            sessions = s
            keys = k
            phase = .ready
        } catch {
            noteRejection(error)
            if phase != .ready { phase = .failed }
        }
    }

    /// Signs another device out (`DELETE /auth/sessions/<id>`). This device signs out with `AppModel.signOut()`.
    /// Already gone counts as done.
    public func signOut(_ session: AccountSession) async throws {
        do {
            try await ctx.client.deleteAccountSession(id: session.id)
        } catch AccountError.notFound {
            // already signed out somewhere else: drop the row
        } catch {
            noteRejection(error)
            throw AccountError.from(error)
        }
        sessions.removeAll { $0.id == session.id }
        if let m = me { me = AccountMe(caller: m.caller, sessions: max(0, m.sessions - 1), keys: m.keys) }
    }

    /// `POST /auth/signout-others`: every other device. Answers how many.
    @discardableResult
    public func signOutOthers() async throws -> Int {
        let count: Int
        do {
            count = try await ctx.client.signOutOtherSessions()
        } catch {
            noteRejection(error)
            throw AccountError.from(error)
        }
        sessions.removeAll { !$0.current }
        if let m = me { me = AccountMe(caller: m.caller, sessions: sessions.count, keys: m.keys) }
        return count
    }

    /// `DELETE /auth/keys/<id>`. Already gone counts as done.
    public func revoke(_ key: AccountKey) async throws {
        do {
            try await ctx.client.deleteAccountKey(id: key.id)
        } catch AccountError.notFound {
            // revoked elsewhere: drop the row
        } catch {
            noteRejection(error)
            throw AccountError.from(error)
        }
        keys.removeAll { $0.id == key.id }
        if let m = me { me = AccountMe(caller: m.caller, sessions: m.sessions, keys: max(0, m.keys - 1)) }
    }

    /// This device's own token was refused: the app goes to the signed-out state.
    private func noteRejection(_ error: Error) {
        if case .api(let code, let status)? = error as? CobaltError, status == 401, code == "error.api.auth.key.invalid" {
            ctx.keyRejected?()
        }
    }
}
