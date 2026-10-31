import Foundation
import Testing
@testable import CobaltKit

// Shared chats (APP-API-CONTRACT 46): the `ChatShare` shape, the request bodies, and the store on the preview server
// (share, update, rotate, stop).

private let wireShare = """
{"status":"success","share":{"url":"https://share.capybaraharmony.com/c/AbCdEfGh1234567890ZzYy","thread_id":"ThReAd0123456789",
 "upto_id":"104","upto_at":1790000500000,"messages":4,"behind":2,"files":3,"media":true,"code":false,
 "created_at":1790000600000,"updated_at":1790000700000,"opened":6,"last_opened_at":1790000800000}}
"""

@Suite struct ChatShareDecodingTests {
    @Test func theShareDecodes() throws {
        struct Wire: Decodable { var share: ChatShare? }
        let s = try #require(try CobaltJSON.decoder().decode(Wire.self, from: Data(wireShare.utf8)).share)
        #expect(s.url.absoluteString == "https://share.capybaraharmony.com/c/AbCdEfGh1234567890ZzYy")
        #expect(s.threadID == "ThReAd0123456789" && s.uptoID == "104" && s.messages == 4 && s.behind == 2 && s.files == 3)
        #expect(s.media && !s.code && s.opened == 6)
        #expect(s.lastOpenedAt == Date(timeIntervalSince1970: 1_790_000_800))
        let none = try CobaltJSON.decoder().decode(Wire.self, from: Data(#"{"status":"success","share":null}"#.utf8))
        #expect(none.share == nil)
    }

    @Test func theChangeBodies() {
        #expect(ChatShareChange().body.isEmpty)
        let b = ChatShareChange(media: false, code: true, toLatest: true).body
        #expect(b["media"] as? Bool == false && b["code"] as? Bool == true && b["upto"] as? String == "latest")
    }
}

@MainActor
struct ChatShareStoreTests {
    private func app() -> AppModel { AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock()) }
    private let t1 = PreviewData.chatThreadIDs[0]

    @Test func shareUpdateRotateStop() async throws {
        let app = app()
        await app.chat.load(t1)
        #expect(try await app.chat.loadShare(t1) == nil)
        #expect(app.chat.shares[t1] == .some(nil))

        let made = try await app.chat.share(t1)
        #expect(made.url.absoluteString.hasPrefix("https://share.capybaraharmony.com/c/"))
        #expect(made.media && !made.code && made.messages == 4 && made.behind == 0)
        #expect(app.chat.shareOf(t1) == made)

        let changed = try await app.chat.share(t1, ChatShareChange(code: true))
        #expect(changed.url == made.url && changed.code && changed.media)

        let rotated = try await app.chat.rotateShare(t1)
        #expect(rotated.url != made.url && rotated.code)

        try await app.chat.stopShare(t1)
        #expect(app.chat.shareOf(t1) == nil)
        await #expect(throws: CobaltError.api(code: "error.chat_share.not_found", httpStatus: 404)) { try await app.chat.rotateShare(t1) }
        let client = try #require(app.ctx.client as? PreviewClient)
        #expect(client.chatShareState.calls == ["GET \(t1)", "PUT \(t1)", "PUT \(t1)", "ROTATE \(t1)", "DELETE \(t1)", "ROTATE \(t1)"])
    }

}
