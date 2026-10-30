import Foundation

// How agents reach the capystore MCP (APP-API-CONTRACT 35.5): the public URL with a client key in the header, a private
// link with the key inside it (for claude.ai's connectors), or neither. `GET /mcp/settings` says which, and how the live
// private link has been used; the link itself only comes back once, from the call that made it (`McpChange.linkURL`).

/// One answer of `GET /mcp/settings`.
public struct McpSettings: Sendable, Equatable, Decodable {
    public enum Mode: String, Sendable, Equatable, CaseIterable, Decodable {
        /// No agent can connect.
        case off
        /// `POST /mcp` with a client key in the header.
        case `public`
        /// Only the private link; the public URL answers 404.
        case `private`
    }

    /// The live private link, without its secret.
    public struct Link: Sendable, Equatable, Decodable {
        /// The link with its secret cut to `…<tail>`.
        public var hint: String
        public var tail: String
        public var madeAt: Date
        public var lastUsedAt: Date?
        /// The client's own name from its last `initialize` (e.g. "claude-ai").
        public var usedBy: String?
        public var callsToday: Int

        public init(hint: String, tail: String, madeAt: Date, lastUsedAt: Date? = nil, usedBy: String? = nil, callsToday: Int = 0) {
            self.hint = hint
            self.tail = tail
            self.madeAt = madeAt
            self.lastUsedAt = lastUsedAt
            self.usedBy = usedBy
            self.callsToday = callsToday
        }
    }

    public var mode: Mode
    public var publicUrl: String
    public var link: Link?

    public init(mode: Mode, publicUrl: String, link: Link? = nil) {
        self.mode = mode
        self.publicUrl = publicUrl
        self.link = link
    }

    static func decode(_ data: Data) throws -> McpSettings {
        try CobaltJSON.decoder().decode(McpSettings.self, from: data)
    }
}

/// The answer of `POST /mcp/settings` and `POST /mcp/settings/rotate`.
public struct McpChange: Sendable, Equatable, Decodable {
    public var settings: McpSettings
    /// The new private link, answered only here, once.
    public var linkUrl: String?

    public init(settings: McpSettings, linkUrl: String? = nil) {
        self.settings = settings
        self.linkUrl = linkUrl
    }

    static func decode(_ data: Data) throws -> McpChange {
        try CobaltJSON.decoder().decode(McpChange.self, from: data)
    }
}
