import Foundation

// How agents reach the MCP (APP-API-CONTRACT 35.5) on the real client: the generated endpoints, keyed.
extension HTTPCobaltClient {
    /// `GET /mcp/settings`. Errors as the keyed calls throw them (`404` on a server without the route).
    public func mcpSettings() async throws -> McpSettings {
        let (data, http) = try await send(makeRequest(Endpoints.mcpSettings(), timeout: 20))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try McpSettings.decode(data) } catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `POST /mcp/settings {"mode"}`: `400 error.mcp.mode` is `CobaltError.api`.
    public func setMcpMode(_ mode: McpSettings.Mode) async throws -> McpChange {
        let req = try makeRequest(Endpoints.mcpSettingsSet(), timeout: 20)
        return try await mcpChange(req, body: Self.jsonBody(["mode": mode.rawValue]))
    }

    /// `POST /mcp/settings/rotate`: `409 error.mcp.not_private` is `CobaltError.api`.
    public func rotateMcpLink() async throws -> McpChange {
        try await mcpChange(makeRequest(Endpoints.mcpLinkRotate(), timeout: 20), body: nil)
    }

    private func mcpChange(_ req: URLRequest, body: Data?) async throws -> McpChange {
        let (data, http) = try await send(req, body: body)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try McpChange.decode(data) } catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }
}
