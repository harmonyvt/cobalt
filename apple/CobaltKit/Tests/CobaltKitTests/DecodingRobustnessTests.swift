import Foundation
import Testing
@testable import CobaltKit

/// Server rows this app does not understand must not take their neighbours down with them.
struct DecodingRobustnessTests {
    @Test func aRenderWithoutAUrlIsSkippedNotFatal() throws {
        let json = """
        {"status":"ready","id":"AbCdEfGhIjKlMnOpQrStUv","link":"https://x.com/i/status/1","service":"twitter","title":"t",
         "duration":5.46,"width":480,"height":568,"bytes":256000,"step":null,"step_bytes":null,"step_total":null,"waking":false,
         "created_at":1790000000000,"expires_at":1790600000000,"error":null,
         "renders":[{"id":"r1","url":null,"start":0,"length":5.4,"width":480,"quality":"med","bytes":1,"created_at":1790000001000},
                    {"id":"r2","url":"https://media.capybaraharmony.com/AbCdEfGhIj.webp","start":0,"length":5.4,"width":480,"quality":"med","bytes":841000,"created_at":1790000002000}]}
        """
        let session = try CobaltJSON.decoder().decode(StudioSession.self, from: Data(json.utf8))
        #expect(session.status == .ready && session.renders.map(\.id) == ["r2"])
        #expect(session.step == nil && session.waking == false && session.errorCode == nil)
    }

    @Test func aStepThisBuildDoesNotKnowIsNotSaid() throws {
        let json = #"{"status":"saving","id":"AbCdEfGhIjKlMnOpQrStUv","step":"transcoding","step_bytes":5,"step_total":10,"waking":true,"created_at":1790000000000,"expires_at":1790600000000,"renders":[]}"#
        let session = try CobaltJSON.decoder().decode(StudioSession.self, from: Data(json.utf8))
        #expect(session.step == nil && session.stepBytes == 5 && session.stepTotal == 10 && session.waking == true)
    }

    @Test func aBrokenFileOrPostLeavesTheRestOfTheLibraryPage() async throws {
        let server = try await LoopbackServer.start { _ in
            .json("""
            {"status":"success","counts":{"posts":3,"files":3},"usage":{"public_bytes":1,"private_bytes":2},"next":null,
             "posts":[
              {"id":"good","service":"x","link":null,"title":"t","duration":null,"width":null,"height":null,"created_at":1790000000000,"session":null,
               "files":[{"id":"f1","kind":"public","source":"studio","name":"a.webp","url":"https://m/AbCdEfGhIj.webp","content_type":"image/webp","bytes":1,"width":1,"height":1,"duration":1,"created_at":1790000000000,"media_name":"AbCdEfGhIj.webp","deletable":true},
                        {"id":"f2","kind":"somethingnew","source":"studio","name":"b","created_at":1790000000000}]},
              {"id":"broken","created_at":"not a number","files":[]},
              {"id":"also-good","created_at":1789000000000,"files":[]}
             ]}
            """)
        }
        defer { server.stop() }
        let page = try await HTTPCobaltClient(baseURL: server.base, apiKey: { "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21" }).library(cursor: nil, limit: 20)
        #expect(page.posts.map(\.id) == ["good", "also-good"])
        #expect(page.posts[0].files.map(\.id) == ["f1"])                          // the unknown kind is dropped, not fatal
        #expect(page.postCount == 3 && page.fileCount == 3)                         // totals are the server's, not ours
    }
}
