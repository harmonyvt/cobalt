import Foundation
import Synchronization

/// What the preview "server" holds for the MCP switch (APP-API-CONTRACT 35.5): it starts on the private link, used by
/// claude.ai two minutes ago, so the settings show every row.
final class PreviewMcpState: Sendable {
    private struct State {
        var mode: McpSettings.Mode = .private
        var link: McpSettings.Link?
        var counter = 0
    }

    private let state = Mutex(State())

    static let secrets = ["Xq7m2RkT9vLp4WnZ8cHs3bYdF1aE7Qx2", "Jf5gA1eN6uQo0iVr7KtM2wPxC9hLr4Tz", "Bz9hC4yE8sDj3LqU6nRa1gTkW2oVb8Mn"]

    func settings(now: Date) -> McpSettings {
        state.withLock { s in
            if s.mode == .private && s.link == nil {
                s.link = Self.link(Self.secrets[0], made: now.addingTimeInterval(-2 * 86_400), used: now.addingTimeInterval(-120), by: "claude-ai", calls: 41)
            }
            return McpSettings(mode: s.mode, publicUrl: "\(PreviewData.base.absoluteString.trimmingSuffix("/"))/mcp", link: s.mode == .private ? s.link : nil)
        }
    }

    func set(_ mode: McpSettings.Mode, now: Date) -> McpChange {
        let before = settings(now: now)
        if before.mode == mode { return McpChange(settings: before) }
        let made: String? = state.withLock { s in
            s.mode = mode
            guard mode == .private else { s.link = nil; return nil }
            s.counter += 1
            let secret = Self.secrets[s.counter % Self.secrets.count]
            s.link = Self.link(secret, made: now)
            return secret
        }
        return McpChange(settings: settings(now: now), linkUrl: made.map(Self.url))
    }

    func rotate(now: Date) -> McpChange? {
        guard settings(now: now).mode == .private else { return nil }
        let secret: String = state.withLock { s in
            s.counter += 1
            let secret = Self.secrets[s.counter % Self.secrets.count]
            s.link = Self.link(secret, made: now)
            return secret
        }
        return McpChange(settings: settings(now: now), linkUrl: Self.url(secret))
    }

    private static func base() -> String { PreviewData.base.absoluteString.trimmingSuffix("/") }
    private static func url(_ secret: String) -> String { "\(base())/mcp/k/\(secret)" }
    private static func link(_ secret: String, made: Date, used: Date? = nil, by: String? = nil, calls: Int = 0) -> McpSettings.Link {
        let tail = String(secret.suffix(4))
        return McpSettings.Link(hint: "\(base())/mcp/k/\u{2026}\(tail)", tail: tail, madeAt: made, lastUsedAt: used, usedBy: by, callsToday: calls)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

extension PreviewClient {
    public func mcpSettings() async throws -> McpSettings {
        try await clock.sleep(seconds: 0.2 * timeScale)
        return mcpState.settings(now: clock.now())
    }

    public func setMcpMode(_ mode: McpSettings.Mode) async throws -> McpChange {
        try await clock.sleep(seconds: 0.3 * timeScale)
        return mcpState.set(mode, now: clock.now())
    }

    public func rotateMcpLink() async throws -> McpChange {
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard let change = mcpState.rotate(now: clock.now()) else {
            throw CobaltError.api(code: "error.mcp.not_private", httpStatus: 409)
        }
        return change
    }
}
