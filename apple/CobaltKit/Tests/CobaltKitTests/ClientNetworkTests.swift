import Foundation
import Synchronization
import Testing
@testable import CobaltKit

/// The HTTP client over real loopback sockets: what a `URLProtocol` stub cannot show (a redirect
/// the client must refuse to follow, bytes actually counted while they move).
@Suite(.serialized)
struct ClientNetworkTests {
    private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

    private func client(_ server: LoopbackServer, key: String? = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21") -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { key })
    }

    // MARK: capability detection, the three steps

    @Test func plainCobaltIs302OnCapabilitiesAndAnswersRoot() async throws {
        let server = try await LoopbackServer.start { request in
            switch request.path {
            case "/capabilities":
                // upstream cobalt: app.get('/*') redirects every unknown GET to '/'
                return .init(status: 302, headers: ["location": "/"])
            case "/":
                return .json(#"{"cobalt":{"version":"11.7.0","url":"http://x/","startTime":"1","services":["youtube"]},"git":{"branch":"main"}}"#)
            default:
                return .init(status: 404)
            }
        }
        defer { server.stop() }
        let caps = await client(server, key: nil).capabilities()
        #expect(caps.kind == .plainCobalt && caps.cobaltVersion == "11.7.0")
        #expect(!caps.studio && !caps.upload && !caps.library && caps.limits.maxUploadBytes == 0 && caps.key == .unknown)
        // the redirect was not followed: exactly the two probes, nothing hit "/" on the 302's behalf
        #expect(server.requests.map(\.path) == ["/capabilities", "/"])
    }

    @Test func legacyForkIs404OnCapabilitiesAndRootButKnowsStudio() async throws {
        let server = try await LoopbackServer.start { request in
            if request.path == "/studio/0000000000000000000000" {
                return .json(#"{"status":"error","error":{"code":"error.studio.not_found"}}"#, status: 404)
            }
            return .init(status: 404)                                  // the bare 404, no body
        }
        defer { server.stop() }
        let caps = await client(server).capabilities()
        #expect(caps.kind == .legacyFork && caps.studio && !caps.upload && !caps.library && !caps.saveProgress)
        #expect(server.requests.map(\.path) == ["/capabilities", "/", "/studio/0000000000000000000000"])
        #expect(server.requests.dropFirst().allSatisfy { $0.headers["authorization"] == nil })   // only /capabilities may carry the key
    }

    @Test func forkAnswersCapabilitiesAndSeesTheKey() async throws {
        let server = try await LoopbackServer.start { request in
            request.path == "/capabilities"
                ? .json(#"{"status":"success","server":"cobalt-cloudflare","cobalt":{"version":"11.7.1"},"features":{"studio":true,"upload":true,"library":true,"save_progress":true,"render_progress":true,"finishes_unpolled":true},"limits":{"max_webp_seconds":10,"min_webp_seconds":0.5,"webp_widths":[320,480],"webp_qualities":["low","med","high"],"render_fps":15,"max_upload_bytes":100000000,"max_source_bytes":209715200,"session_ttl_ms":604800000},"media_base_url":"https://media.capybaraharmony.com/","key":"valid","key_name":"iphone"}"#)
                : .init(status: 404)
        }
        defer { server.stop() }
        let caps = await client(server).capabilities()
        #expect(caps.kind == .fork && caps.key == .valid && caps.keyName == "iphone" && caps.finishesUnpolled)
        #expect(server.requests.count == 1 && server.requests[0].headers["authorization"] == "Api-Key \(key)")
        #expect(server.requests[0].headers["accept"] == "application/json")
    }

    @Test func aServerThatIsNotCobaltAndAClosedPort() async throws {
        let server = try await LoopbackServer.start { _ in .init(status: 200, headers: ["content-type": "text/html"], body: Data("<html>hi</html>".utf8)) }
        let c = client(server)
        let caps = await c.capabilities()
        #expect(caps.kind == .notCobalt)
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await c.capabilities().kind == .unreachable)
    }

    // MARK: bytes in motion

    @Test func uploadReportsProgressAndSendsTheFileAsIs() async throws {
        let payload = Data((0..<8_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = try makeTempDirectory().appendingPathComponent("IMG_0412.mov")
        try payload.write(to: file)
        let received = Mutex<Data>(Data())
        let server = try await LoopbackServer.start(readDelay: 0.02) { request in
            received.withLock { $0 = request.body }
            return .json(#"{"status":"success","id":"sid","url":"https://c/studio/sid","item":{"id":"AbCdEfGhIjKlMnOp","kind":"private","source":"upload","name":"IMG_0412.mov","url":null,"content_type":"video/quicktime","bytes":8000000,"width":null,"height":null,"duration":null,"link":null,"session_id":null,"created_at":1790000000000},"studio_error":null}"#, status: 201)
        }
        defer { server.stop() }

        let seen = Mutex<[TransferProgress]>([])
        let result = try await client(server).upload(
            file: file, name: "IMG 0412 é.mov", contentType: "video/quicktime", progress: { p in seen.withLock { $0.append(p) } })
        #expect(result.sessionID == "sid" && result.item.id == "AbCdEfGhIjKlMnOp")

        let request = try #require(server.requests.first)
        #expect(request.method == "PUT" && request.path == "/studio/upload")
        #expect(request.query == "name=IMG%200412%20%C3%A9.mov")
        #expect(request.headers["content-type"] == "video/quicktime")
        #expect(request.headers["content-length"] == "8000000")
        #expect(request.headers["authorization"] == "Api-Key \(key)")
        #expect(received.withLock { $0 } == payload)

        let progress = seen.withLock { $0 }
        #expect(progress.count >= 2)                                                  // moved in steps
        #expect(progress.map(\.bytes) == progress.map(\.bytes).sorted())              // never backwards
        #expect(progress.last == TransferProgress(bytes: 8_000_000, total: 8_000_000))
    }

    @Test func downloadReportsProgressAndNeverSendsTheKeyToOpenFiles() async throws {
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let server = try await LoopbackServer.start { request in
            request.path.hasPrefix("/library/items/") || request.path.hasPrefix("/tunnel") || request.path.hasPrefix("/studio/")
                ? .init(status: 200, headers: ["content-type": "video/mp4"], body: payload)
                : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        let dir = try makeTempDirectory()

        let seen = Mutex<[TransferProgress]>([])
        let saved = try await c.download(.open(server.base.appendingPathComponent("tunnel")), to: dir.appendingPathComponent("a.mp4")) { p in
            seen.withLock { $0.append(p) }
        }
        #expect(try Data(contentsOf: saved) == payload)
        let progress = seen.withLock { $0 }
        #expect(progress.count >= 2)
        #expect(progress.map(\.bytes) == progress.map(\.bytes).sorted())
        #expect(progress.last == TransferProgress(bytes: 3_000_000, total: 3_000_000))

        _ = try await c.download(.libraryItem(id: "AbCdEfGhIjKlMnOp"), to: dir.appendingPathComponent("b.mp4"), progress: { _ in })
        _ = try await c.download(.studioSource(session: "AbCdEfGhIjKlMnOpQrStUv"), to: dir.appendingPathComponent("c.mp4"), progress: { _ in })
        let byPath = Dictionary(uniqueKeysWithValues: server.requests.map { ($0.path, $0) })
        #expect(byPath["/tunnel"]?.headers["authorization"] == nil)                       // open files: never the key
        #expect(byPath["/library/items/AbCdEfGhIjKlMnOp/file"]?.headers["authorization"] == "Api-Key \(key)")
        #expect(byPath["/studio/AbCdEfGhIjKlMnOpQrStUv/source"]?.headers["authorization"] == nil)

        // an error body is an error, not a file
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 404)) {
            try await c.download(.open(server.base.appendingPathComponent("nope")), to: dir.appendingPathComponent("d.mp4"), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("d.mp4").path))
    }

    // MARK: server answers the contract does not promise

    @Test func uploadWithoutAnItemStillSucceedsAndNamesNoItem() async throws {
        // app-routes.ts sends `item: null` when it stored the file but could not read the row back
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","id":"sid","url":"https://c/studio/sid","item":null,"studio_error":null}"#, status: 201)
        }
        defer { server.stop() }
        let file = try makeTempFile("clip.mp4", bytes: 1_234)
        let result = try await client(server).upload(file: file, name: "clip.mp4", contentType: "video/mp4", progress: { _ in })
        #expect(result.sessionID == "sid" && result.item.id.isEmpty)
        #expect(result.item.name == "clip.mp4" && result.item.bytes == 1_234 && result.item.source == .upload)
    }

    @Test func renderAcceptedWith202AndPendingBodiesWithNullProgress() async throws {
        let server = try await LoopbackServer.start { request in
            switch (request.method, request.path) {
            case ("POST", "/studio/AbCdEfGhIjKlMnOpQrStUv/render"):
                return .json(#"{"status":"pending","job":"job1"}"#, status: 202)
            case ("GET", "/studio/AbCdEfGhIjKlMnOpQrStUv/render/job1"):
                return .json(#"{"status":"pending","job":"job1","phase":null,"frames_done":null,"frames_total":null}"#)
            default:
                return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        let job = try await c.render(session: "AbCdEfGhIjKlMnOpQrStUv", RenderRequest(start: 0, length: 5, width: 480, quality: .med))
        #expect(job == "job1")
        let status = try await c.renderStatus(session: "AbCdEfGhIjKlMnOpQrStUv", job: "job1", wait: 1)
        #expect(status == .pending(phase: nil, framesDone: nil, framesTotal: nil))
        let body = String(decoding: try #require(server.requests.first).body, as: UTF8.self)
        #expect(body.contains("\"width\":480") && body.contains("\"quality\":\"med\"") && body.contains("\"length\":5"))
        // a long poll's own timeout: wait + 15 s
        #expect(server.requests.last?.target.contains("wait=1") == true)
    }

    @Test func libraryPagesFollowTheCursor() async throws {
        let page1 = #"{"status":"success","posts":[{"id":"a","service":"instagram","link":"https://www.instagram.com/reel/Dd7P496wolG/","title":"instagram_Dd7P496wolG","duration":14.77,"width":720,"height":1280,"created_at":1790000000000,"session":{"id":"sid","status":"ready","expires_at":1790600000000,"source_url":"https://api.example/studio/sid/source"},"files":[{"id":"f1","kind":"public","source":"studio","name":"x.webp","url":"https://media.example/AbCdEfGhIj.webp","content_type":"image/webp","bytes":4500000,"width":480,"height":854,"duration":10.1,"created_at":1790000000000,"media_name":"AbCdEfGhIj.webp","deletable":true}]}],"counts":{"posts":2,"files":3},"usage":{"public_bytes":10,"private_bytes":20},"next":"CURSOR"}"#
        let page2 = #"{"status":"success","posts":[{"id":"b","service":null,"link":null,"title":null,"duration":null,"width":null,"height":null,"created_at":1789000000000,"session":null,"files":[]}],"counts":{"posts":2,"files":3},"usage":{"public_bytes":10,"private_bytes":20},"next":null}"#
        let server = try await LoopbackServer.start { request in
            request.path == "/library" ? .json(request.query.contains("cursor=CURSOR") ? page2 : page1) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        let first = try await c.library(cursor: nil, limit: 20)
        #expect(first.posts.map(\.id) == ["a"] && first.next == "CURSOR" && first.postCount == 2 && first.fileCount == 3)
        #expect(first.publicBytes == 10 && first.privateBytes == 20)
        #expect(first.posts[0].session?.sourceURL.absoluteString == "https://api.example/studio/sid/source")
        let second = try await c.library(cursor: first.next, limit: 20)
        #expect(second.posts.map(\.id) == ["b"] && second.next == nil)
        #expect(server.requests.map(\.query) == ["limit=20", "limit=20&cursor=CURSOR"])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key \(key)" })
        // limit is clamped to the server's 1...50
        _ = try await c.library(cursor: nil, limit: 500)
        #expect(server.requests.last?.query == "limit=50")
    }
}
