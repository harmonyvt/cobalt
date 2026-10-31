import Foundation
import Synchronization

// Accounts in previews (APP-API-CONTRACT 42): the server of `.happy`, `.signedOut`, `.firstLaunch` and `.moveOver` has
// `features.accounts`, five signed-in devices and four keys for tools (two old pastes), like the accounts mockup.
// `.signedOut` refuses the stored token and `.firstLaunch` has none until a `PreviewWebSignIn` sheet signs in; the
// exchange then answers a fresh token and every call works.

extension PreviewScenario {
    var hasAccounts: Bool {
        switch self {
        case .happy, .signedOut, .firstLaunch, .moveOver: return true
        default: return false
        }
    }

    /// Scenarios whose token is refused until the preview signs in.
    var startsSignedOut: Bool { self == .signedOut || self == .firstLaunch }
}

extension PreviewData {
    /// The Access email of the previews.
    static let accountEmail = "harmony@capybaraharmony.com"

    /// This device first (current), then the mockup's other four.
    static func accountSessions(now: Date) -> [AccountSession] {
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        let day = 86_400.0
        #if os(macOS)
        let this = ("mac studio", AccountPlatform.mac, "harmony's iphone", AccountPlatform.ios)
        #else
        let this = ("harmony's iphone", AccountPlatform.ios, "mac studio", AccountPlatform.mac)
        #endif
        return [
            AccountSession(id: "5e551000-0000-4000-8000-000000000001", device: this.0, platform: this.1.rawValue,
                           createdAt: ago(30 * day), lastUsedAt: now, expiresAt: now.addingTimeInterval(90 * day), country: "AU", current: true),
            AccountSession(id: "5e551000-0000-4000-8000-000000000002", device: this.2, platform: this.3.rawValue,
                           createdAt: ago(28 * day), lastUsedAt: ago(2 * 3_600), expiresAt: ago(2 * 3_600).addingTimeInterval(90 * day), country: "AU"),
            AccountSession(id: "5e551000-0000-4000-8000-000000000003", device: "safari on mac", platform: "web",
                           createdAt: ago(20 * day), lastUsedAt: ago(day), expiresAt: ago(day).addingTimeInterval(90 * day), country: "AU"),
            AccountSession(id: "5e551000-0000-4000-8000-000000000004", device: "ipad", platform: "ipados",
                           createdAt: ago(40 * day), lastUsedAt: ago(6 * day), expiresAt: ago(6 * day).addingTimeInterval(90 * day), country: "AU"),
            AccountSession(id: "5e551000-0000-4000-8000-000000000005", device: "chrome on windows", platform: "web",
                           createdAt: ago(60 * day), lastUsedAt: ago(41 * day), expiresAt: ago(41 * day).addingTimeInterval(90 * day), country: "HK"),
        ]
    }

    static func accountKeys(now: Date) -> [AccountKey] {
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        let day = 86_400.0
        return [
            AccountKey(id: "6b3e1000-0000-4000-8000-000000000001", name: "claude code mcp", prefix: "3f9a1c2e",
                       createdAt: ago(50 * day), lastUsedAt: ago(3 * 3_600)),
            AccountKey(id: "6b3e1000-0000-4000-8000-000000000002", name: "shortcuts", prefix: "a71b09dd",
                       createdAt: ago(45 * day), lastUsedAt: ago(3 * day)),
            AccountKey(id: "6b3e1000-0000-4000-8000-000000000003", name: "iphone", prefix: "c02e77f1",
                       createdAt: ago(90 * day), lastUsedAt: ago(5 * 60), oldPaste: true),
            AccountKey(id: "6b3e1000-0000-4000-8000-000000000004", name: "mac", prefix: "9b13e4a0",
                       createdAt: ago(80 * day), lastUsedAt: ago(14 * day), oldPaste: true),
        ]
    }
}

/// What the preview "server" holds for accounts.
final class PreviewAccountState: Sendable {
    private struct State {
        var seeded = false
        var signedIn = true
        var sessions: [AccountSession] = []
        var keys: [AccountKey] = []
        /// The `old_key` the last exchange carried (tests).
        var lastOldKey: String?
        var exchanges = 0
    }

    private let state = Mutex(State())

    func seed(_ scenario: PreviewScenario, now: Date) {
        state.withLock { s in
            s.seeded = true
            s.signedIn = !scenario.startsSignedOut
            s.sessions = PreviewData.accountSessions(now: now)
            s.keys = PreviewData.accountKeys(now: now)
        }
    }

    var signedIn: Bool { state.withLock { $0.signedIn } }
    var lastOldKey: String? { state.withLock { $0.lastOldKey } }
    var exchanges: Int { state.withLock { $0.exchanges } }

    func exchange(oldKey: String?, now: Date) -> AuthExchange {
        state.withLock { s in
            s.signedIn = true
            s.lastOldKey = oldKey
            s.exchanges += 1
            if let at = s.sessions.firstIndex(where: \.current) {
                s.sessions[at].lastUsedAt = now
                s.sessions[at].createdAt = now
            }
            return AuthExchange(key: UUID().uuidString.lowercased(), session: s.sessions.first(where: \.current))
        }
    }

    func me() -> AccountMe {
        state.withLock { s in
            let current = s.sessions.first(where: \.current)
            return AccountMe(
                caller: .init(kind: .session, id: current?.id ?? "", device: current?.device, platform: current?.platform,
                              email: PreviewData.accountEmail, expiresAt: current?.expiresAt),
                sessions: s.sessions.count, keys: s.keys.count)
        }
    }

    var sessions: [AccountSession] { state.withLock { $0.sessions } }
    var keys: [AccountKey] { state.withLock { $0.keys } }

    func deleteSession(_ id: String) -> Bool {
        state.withLock { s in
            guard let at = s.sessions.firstIndex(where: { $0.id == id }) else { return false }
            if s.sessions[at].current { s.signedIn = false }
            s.sessions.remove(at: at)
            return true
        }
    }

    func signOut() {
        state.withLock { s in s.signedIn = false }
    }

    func signOutOthers() -> Int {
        state.withLock { s in
            let before = s.sessions.count
            s.sessions.removeAll { !$0.current }
            return before - s.sessions.count
        }
    }

    func deleteKey(_ id: String) -> Bool {
        state.withLock { s in
            guard let at = s.keys.firstIndex(where: { $0.id == id }) else { return false }
            s.keys.remove(at: at)
            return true
        }
    }
}

extension PreviewClient {
    /// The refusal a keyed call gets while the preview is signed out (nil when it works).
    func accountRefusal() -> CobaltError? {
        guard scenario.startsSignedOut, !accountState.signedIn else { return nil }
        return scenario == .firstLaunch
            ? CobaltError.api(code: "error.api.auth.key.missing", httpStatus: 401)
            : CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)
    }

    public func exchangeSignIn(code: String, verifier: String, oldKey: String?) async throws -> AuthExchange {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard code.count >= 16, verifier.count == 43 else { throw AccountError.codeInvalid }
        return accountState.exchange(oldKey: oldKey, now: clock.now())
    }

    public func accountMe() async throws -> AccountMe {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.2 * timeScale)
        if let refusal = accountRefusal() { throw refusal }
        return accountState.me()
    }

    public func accountSessions() async throws -> [AccountSession] {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.2 * timeScale)
        if let refusal = accountRefusal() { throw refusal }
        return accountState.sessions
    }

    public func deleteAccountSession(id: String) async throws {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.3 * timeScale)
        if let refusal = accountRefusal() { throw refusal }
        guard accountState.deleteSession(id) else { throw AccountError.notFound }
    }

    public func signOutSession() async throws -> Bool {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.2 * timeScale)
        accountState.signOut()
        return true
    }

    public func signOutOtherSessions() async throws -> Int {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.3 * timeScale)
        if let refusal = accountRefusal() { throw refusal }
        return accountState.signOutOthers()
    }

    public func accountKeys() async throws -> [AccountKey] {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.2 * timeScale)
        if let refusal = accountRefusal() { throw refusal }
        return accountState.keys
    }

    public func deleteAccountKey(id: String) async throws {
        guard scenario.hasAccounts else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.3 * timeScale)
        if let refusal = accountRefusal() { throw refusal }
        guard accountState.deleteKey(id) else { throw AccountError.notFound }
    }
}
