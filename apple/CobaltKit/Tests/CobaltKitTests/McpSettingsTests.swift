import Foundation
import Testing
@testable import CobaltKit

// How agents reach the MCP (APP-API-CONTRACT 35.5): the wire shapes of GET /mcp/settings and the two POSTs, and the
// preview server's switch and rotation.

struct McpSettingsWireTests {
    @Test func decodesThePrivateLink() throws {
        let json = #"""
        {"mode":"private","public_url":"https://api.capybaraharmony.com/mcp",
         "link":{"hint":"https://api.capybaraharmony.com/mcp/k/…7Qx2","tail":"7Qx2","made_at":1790000000000,
                 "last_used_at":1790000120000,"used_by":"claude-ai","calls_today":41}}
        """#
        let s = try McpSettings.decode(Data(json.utf8))
        #expect(s.mode == .private)
        #expect(s.link?.tail == "7Qx2")
        #expect(s.link?.usedBy == "claude-ai")
        #expect(s.link?.callsToday == 41)
        #expect(s.link?.madeAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func decodesNoLinkAndAChange() throws {
        let s = try McpSettings.decode(Data(#"{"mode":"public","public_url":"https://api.capybaraharmony.com/mcp","link":null}"#.utf8))
        #expect(s.mode == .public && s.link == nil)
        let c = try McpChange.decode(Data(#"{"settings":{"mode":"private","public_url":"u","link":{"hint":"h","tail":"abcd","made_at":1,"last_used_at":null,"used_by":null,"calls_today":0}},"link_url":"https://api.capybaraharmony.com/mcp/k/abc"}"#.utf8))
        #expect(c.linkUrl == "https://api.capybaraharmony.com/mcp/k/abc")
        #expect(c.settings.link?.lastUsedAt == nil)
    }
}

struct McpPreviewTests {
    @Test func switchesAndRotates() async throws {
        let client = PreviewClient(scenario: .happy, timeScale: 0)
        #expect(try await client.mcpSettings().mode == .private)
        let first = try await client.rotateMcpLink()
        let second = try await client.rotateMcpLink()
        #expect(first.linkUrl != nil && first.linkUrl != second.linkUrl)
        let pub = try await client.setMcpMode(.public)
        #expect(pub.linkUrl == nil && pub.settings.link == nil)
        await #expect(throws: CobaltError.self) { try await client.rotateMcpLink() }
        let back = try await client.setMcpMode(.private)
        #expect(back.linkUrl?.contains("/mcp/k/") == true)
        #expect(try await client.setMcpMode(.private).linkUrl == nil)
    }
}
