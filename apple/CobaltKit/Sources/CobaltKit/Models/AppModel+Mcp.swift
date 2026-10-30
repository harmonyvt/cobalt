import Foundation

// How agents reach the MCP (APP-API-CONTRACT 35.5), for settings > mcp. Nothing is cached: the screen asks when it
// opens, and the private link only lives in the view that showed it.
extension AppModel {
    /// `GET /mcp/settings`. Throws `PipelineFailure.unsupported` without a key, and what the client throws otherwise
    /// (a `404` from a server without the route).
    public func mcpSettings() async throws -> McpSettings {
        guard settings.hasAPIKey else { throw PipelineFailure.unsupported }
        return try await ctx.client.mcpSettings()
    }

    /// `POST /mcp/settings {mode}`.
    public func setMcpMode(_ mode: McpSettings.Mode) async throws -> McpChange {
        try await ctx.client.setMcpMode(mode)
    }

    /// `POST /mcp/settings/rotate`.
    public func rotateMcpLink() async throws -> McpChange {
        try await ctx.client.rotateMcpLink()
    }
}
