import Foundation
import Synchronization
import Testing
@testable import CobaltKit

/// A URLProtocol stub keyed by host, so each test owns its server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, headers: [String: String], body: Data)
    static let handlers = Mutex<[String: Handler]>([:])

    static func install(host: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private final class Recorder: Sendable {
    private let requests = Mutex<[URLRequest]>([])
    func add(_ r: URLRequest) { requests.withLock { $0.append(r) } }
    var all: [URLRequest] { requests.withLock { $0 } }
    var paths: [String] { all.map { ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "") } }
}

private func json(_ s: String, status: Int = 200) -> (status: Int, headers: [String: String], body: Data) {
    (status, ["content-type": "application/json"], Data(s.utf8))
}

private let forkCapabilities = """
{"status":"success","server":"cobalt-cloudflare","cobalt":{"version":"11.7.1"},
 "features":{"studio":true,"upload":true,"library":true,"save_progress":true,"render_progress":true,"finishes_unpolled":true},
 "limits":{"max_webp_seconds":10,"min_webp_seconds":0.5,"webp_widths":[320,480],"webp_qualities":["low","med","high"],
 "render_fps":15,"max_upload_bytes":100000000,"max_source_bytes":209715200,"session_ttl_ms":604800000},
 "media_base_url":"https://media.capybaraharmony.com/","key":"valid","key_name":"iphone"}
"""

private func client(host: String, key: String? = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21") -> HTTPCobaltClient {
    HTTPCobaltClient(baseURL: URL(string: "https://\(host)")!, apiKey: { key }, session: StubProtocol.session())
}

private func uniqueHost() -> String { "t\(UUID().uuidString.prefix(8).lowercased()).test" }

@Suite(.serialized)
struct CapabilityDetectionTests {
    @Test func forkSaysWhatItCanDo() async {
        let host = uniqueHost()
        StubProtocol.install(host: host) { req in
            #expect(req.url?.path == "/capabilities")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Api-Key 7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")
            #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
            return json(forkCapabilities)
        }
        let caps = await client(host: host).capabilities()
        #expect(caps.kind == .fork && caps.cobaltVersion == "11.7.1")
        #expect(caps.studio && caps.upload && caps.library && caps.saveProgress && caps.renderProgress && caps.finishesUnpolled)
        #expect(caps.limits == .fork && caps.limits.sessionTTL == 604_800)
        #expect(caps.mediaBaseURL?.absoluteString == "https://media.capybaraharmony.com/")
        #expect(caps.key == .valid && caps.keyName == "iphone")
    }

    @Test func forkWithMissingFeatureKeysAndNoKey() async {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            return json(#"{"server":"cobalt-cloudflare","cobalt":null,"features":{"studio":true},"key":"missing","key_name":null}"#)
        }
        let caps = await client(host: host, key: nil).capabilities()
        #expect(caps.kind == .fork && caps.cobaltVersion == nil && caps.studio)
        #expect(!caps.upload && !caps.library && !caps.saveProgress && !caps.renderProgress)
        #expect(caps.limits == .fork)                                // missing limits = the contract's defaults
        #expect(caps.key == .missing && caps.keyName == nil)
        #expect(rec.all.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func plainCobaltRedirectsTheProbeAndAnswersRoot() async {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            if req.url?.path == "/capabilities" { return (302, ["location": "/"], Data()) }
            if req.url?.path == "/" { return json(#"{"cobalt":{"version":"11.7.1","url":"https://x/","startTime":"1"},"git":{"branch":"main"}}"#) }
            return (404, [:], Data())
        }
        let caps = await client(host: host).capabilities()
        #expect(caps.kind == .plainCobalt && caps.cobaltVersion == "11.7.1")
        #expect(!caps.studio && !caps.upload && !caps.library && !caps.saveProgress && !caps.renderProgress)
        #expect(caps.limits.maxUploadBytes == 0 && caps.key == .unknown)
        #expect(rec.paths == ["GET /capabilities", "GET /"])
    }

    @Test func legacyForkHidesRootButKnowsStudio() async {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            if req.url?.path == "/studio/0000000000000000000000" { return json(#"{"status":"error","error":{"code":"error.studio.not_found"}}"#, status: 404) }
            return (404, [:], Data())                                  // the bare gate 404
        }
        let caps = await client(host: host).capabilities()
        #expect(caps.kind == .legacyFork && caps.studio)
        #expect(!caps.upload && !caps.library && !caps.saveProgress && !caps.renderProgress && caps.limits.maxUploadBytes == 0)
        #expect(rec.paths == ["GET /capabilities", "GET /", "GET /studio/0000000000000000000000"])
    }

    @Test func somethingElseIsNotCobalt() async {
        let host = uniqueHost()
        StubProtocol.install(host: host) { req in
            req.url?.path == "/" ? (200, ["content-type": "text/html"], Data("<html>hi</html>".utf8)) : (404, [:], Data())
        }
        #expect(await client(host: host).capabilities().kind == .notCobalt)

        let host2 = uniqueHost()
        StubProtocol.install(host: host2) { _ in (404, [:], Data("nope".utf8)) }
        #expect(await client(host: host2).capabilities().kind == .notCobalt)   // 404 everywhere, studio probe not JSON
    }

    @Test func unreachableWhenTheNetworkFails() async {
        let host = uniqueHost()
        StubProtocol.install(host: host) { _ in throw URLError(.notConnectedToInternet) }
        let caps = await client(host: host).capabilities()
        #expect(caps.kind == .unreachable && caps == .unknown)
        #expect(await client(host: "nobody-\(uniqueHost())").capabilities().kind == .unreachable)
    }
}

@Suite(.serialized)
struct HTTPClientTests {
    @Test func resolveSendsOnlyTheUrlAndTheKey() async throws {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            let body = String(decoding: StubProtocol.bodyData(of: req), as: UTF8.self)
            #expect(body == #"{"url":"https:\/\/www.instagram.com\/reel\/Dd7P496wolG\/"}"# || body == #"{"url":"https://www.instagram.com/reel/Dd7P496wolG/"}"#)
            return json(#"{"status":"tunnel","url":"https://\#(host)/tunnel?id=abc","filename":"x.mp4"}"#)
        }
        let result = try await client(host: host).resolve(URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!)
        #expect(result == .file(url: URL(string: "https://\(host)/tunnel?id=abc")!, filename: "x.mp4"))
        #expect(rec.all[0].httpMethod == "POST" && rec.all[0].url?.path == "/")
        #expect(rec.all[0].value(forHTTPHeaderField: "Authorization") == "Api-Key 7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")
        #expect(rec.all[0].value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(rec.all[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func missingKeyThrowsBeforeAnyRequest() async {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in rec.add(req); return json("{}") }
        let c = client(host: host, key: nil)
        await #expect(throws: CobaltError.noAPIKey) { try await c.createStudio(link: URL(string: "https://x.com/i/status/1")!) }
        await #expect(throws: CobaltError.noAPIKey) { try await c.library(cursor: nil, limit: 20) }
        await #expect(throws: CobaltError.noAPIKey) { try await c.deleteMedia(name: "AbCdEfGhIj.webp") }
        await #expect(throws: CobaltError.noAPIKey) { try await c.publish(session: "s") }
        #expect(rec.all.isEmpty)
        // unkeyed routes still work without a key
        _ = try? await c.session("abc", wait: 0)
        #expect(rec.all.count == 1 && rec.all[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// Plain cobalt on an open instance needs no key, so `POST /` goes out without one and the
    /// server decides (a fork answers 401, which the pipeline maps to `.keyMissing`).
    @Test func resolveWithoutAKeySendsNoAuthorizationAndLetsTheServerDecide() async throws {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            return json(#"{"status":"tunnel","url":"https://\#(host)/tunnel?id=abc","filename":"x.mp4"}"#)
        }
        let c = client(host: host, key: nil)
        let result = try await c.resolve(URL(string: "https://x.com/i/status/1")!)
        #expect(result == .file(url: URL(string: "https://\(host)/tunnel?id=abc")!, filename: "x.mp4"))
        #expect(rec.all.count == 1 && rec.all[0].value(forHTTPHeaderField: "Authorization") == nil)

        StubProtocol.install(host: host) { _ in
            json(#"{"status":"error","error":{"code":"error.api.auth.key.missing"}}"#, status: 401)
        }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.missing", httpStatus: 401)) {
            try await c.resolve(URL(string: "https://x.com/i/status/1")!)
        }
        #expect(mapFailure(code: "error.api.auth.key.missing", during: .saving) == .keyMissing)
    }

    @Test func pickerAndErrorAndLocalProcessing() async throws {
        let host = uniqueHost()
        StubProtocol.install(host: host) { req in
            let body = String(decoding: StubProtocol.bodyData(of: req), as: UTF8.self)
            if body.contains("picker") {
                return json(#"{"status":"picker","audio":"https://a.b/audio.mp3","picker":[{"type":"video","url":"https://a.b/v.mp4","thumb":"https://a.b/t.jpg"},{"type":"photo","url":"https://a.b/p.jpg"}]}"#)
            }
            if body.contains("private") {
                return json(#"{"status":"error","error":{"code":"error.api.fetch.empty","context":{"service":"instagram"}}}"#, status: 400)
            }
            return json(#"{"status":"local-processing","type":"merge"}"#)
        }
        let c = client(host: host)
        guard case .picker(let items, let audio) = try await c.resolve(URL(string: "https://x.com/picker")!) else {
            Issue.record("expected a picker"); return
        }
        #expect(items.map(\.id) == [0, 1] && items.map(\.type) == [.video, .photo] && items[0].thumb != nil && items[1].thumb == nil)
        #expect(audio?.absoluteString == "https://a.b/audio.mp3")
        await #expect(throws: CobaltError.api(code: "error.api.fetch.empty", httpStatus: 400)) { try await c.resolve(URL(string: "https://x.com/private")!) }
        #expect(try await c.resolve(URL(string: "https://x.com/other")!) == .localProcessing)
    }

    @Test func sessionsAndRenderStatuses() async throws {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            let path = req.url?.path ?? ""
            switch path {
            case "/studio/saving1": return json(#"{"status":"saving","id":"saving1","created_at":1790000000000,"expires_at":1790604800000,"step":"fetching","waking":true,"renders":[]}"#)
            case "/studio/gone": return json(#"{"status":"error","error":{"code":"error.studio.expired"}}"#, status: 410)
            case "/studio/s/render": return json(#"{"status":"pending","job":"job1"}"#, status: 202)
            case "/studio/s/render/job1":
                let wait = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "wait" }?.value
                switch wait {
                case "0": return json(#"{"status":"pending","job":"job1"}"#)
                case "1": return json(#"{"status":"pending","job":"job1","phase":"decode","frames_done":42,"frames_total":150}"#)
                case "2": return json(#"{"status":"pending","job":"job1","phase":"pack","frames_done":150,"frames_total":150}"#)
                case "3": return json(#"{"status":"pending","job":"job1","phase":null,"frames_done":null,"frames_total":null}"#)
                case "4": return json(#"{"status":"success","job":"job1","url":"https://media.capybaraharmony.com/AbCdEfGhIj.webp","bytes":4500000,"width":480,"height":854,"seconds":10.1}"#)
                default: return json(#"{"status":"error","error":{"code":"error.webp.job_lost"}}"#)
                }
            default: return (404, [:], Data())
            }
        }
        let c = client(host: host)
        let saving = try await c.session("saving1", wait: 3)
        #expect(saving.step == .fetching && saving.waking == true)
        #expect(rec.all.last?.url?.query == "wait=3")
        await #expect(throws: CobaltError.api(code: "error.studio.expired", httpStatus: 410)) { try await c.session("gone", wait: 0) }

        let job = try await c.render(session: "s", RenderRequest(start: 2, length: 10, width: 480, quality: .med))
        #expect(job == "job1")
        let sent = try JSONSerialization.jsonObject(with: StubProtocol.bodyData(of: rec.all.last!)) as? [String: Any]
        #expect(sent?["start"] as? Double == 2 && sent?["length"] as? Double == 10 && sent?["width"] as? Int == 480 && sent?["quality"] as? String == "med")
        #expect(rec.all.last?.value(forHTTPHeaderField: "Authorization") == nil)       // render needs no key

        #expect(try await c.renderStatus(session: "s", job: "job1", wait: 0) == .pending(phase: nil, framesDone: nil, framesTotal: nil))
        #expect(try await c.renderStatus(session: "s", job: "job1", wait: 1) == .pending(phase: .decode, framesDone: 42, framesTotal: 150))
        #expect(try await c.renderStatus(session: "s", job: "job1", wait: 2) == .pending(phase: .pack, framesDone: 150, framesTotal: 150))
        #expect(try await c.renderStatus(session: "s", job: "job1", wait: 3) == .pending(phase: nil, framesDone: nil, framesTotal: nil))
        guard case .success(let r) = try await c.renderStatus(session: "s", job: "job1", wait: 4) else { Issue.record("expected success"); return }
        #expect(r.width == 480 && r.height == 854 && r.seconds == 10.1 && r.job == "job1")
        #expect(try await c.renderStatus(session: "s", job: "job1", wait: 9) == .failed(code: "error.webp.job_lost"))
    }

    @Test func libraryPageAndMutations() async throws {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            switch (req.httpMethod ?? "GET", req.url?.path ?? "") {
            case ("GET", "/library"):
                return json(#"{"status":"success","posts":[{"id":"p","created_at":1790000000000,"files":[]}],"counts":{"posts":15,"files":24},"usage":{"public_bytes":10,"private_bytes":20},"next":"CUR"}"#)
            case ("POST", "/library/items/AbCdEfGhIjKlMnOp/publish"):
                return json(#"{"status":"success","url":"https://media.capybaraharmony.com/AbCdEfGhIj.mp4","bytes":8300000,"content_type":"video/mp4","item_id":"new1"}"#, status: 201)
            case ("POST", "/library/items/AbCdEfGhIjKlMnOp/studio"):
                return json(#"{"status":"success","id":"sid","url":"https://cobalt.example/studio/sid"}"#)
            case ("DELETE", "/media/AbCdEfGhIj.webp"):
                return json(#"{"status":"success"}"#)
            default:
                return json(#"{"status":"error","error":{"code":"error.library.not_found"}}"#, status: 404)
            }
        }
        let c = client(host: host)
        let page = try await c.library(cursor: "PREV", limit: 20)
        #expect(page.posts.count == 1 && page.postCount == 15 && page.fileCount == 24 && page.next == "CUR")
        #expect(page.publicBytes == 10 && page.privateBytes == 20)
        let q = URLComponents(url: rec.all[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(q?.first { $0.name == "limit" }?.value == "20" && q?.first { $0.name == "cursor" }?.value == "PREV")

        let hosted = try await c.publish(item: "AbCdEfGhIjKlMnOp")
        #expect(hosted.url.pathExtension == "mp4" && hosted.bytes == 8_300_000 && hosted.itemID == "new1")
        #expect(try await c.openStudio(item: "AbCdEfGhIjKlMnOp").id == "sid")
        try await c.deleteMedia(name: "AbCdEfGhIj.webp")
        await #expect(throws: CobaltError.api(code: "error.library.not_found", httpStatus: 404)) { try await c.deleteMedia(name: "ZZZZZZZZZZ.webp") }
    }

    @Test func uploadParsesTheItemAndTheStudioError() async throws {
        let host = uniqueHost()
        let rec = Recorder()
        StubProtocol.install(host: host) { req in
            rec.add(req)
            let item = #"{"id":"AbCdEfGhIjKlMnOp","kind":"private","source":"upload","name":"IMG_0412.mov","url":null,"content_type":"video/quicktime","bytes":1000,"width":null,"height":null,"duration":null,"link":null,"session_id":null,"created_at":1790000000000}"#
            if req.url?.query?.contains("busy") == true {
                return json(#"{"status":"success","id":null,"url":null,"item":\#(item),"studio_error":{"code":"error.studio.busy"}}"#, status: 201)
            }
            return json(#"{"status":"success","id":"sid","url":"https://cobalt.example/studio/sid","item":\#(item),"studio_error":null}"#, status: 201)
        }
        let file = try makeTempFile("IMG_0412.mov", bytes: 1_000)
        let c = client(host: host)
        let ok = try await c.upload(file: file, name: "IMG_0412.mov", contentType: "video/quicktime", progress: { _ in })
        #expect(ok.sessionID == "sid" && ok.studioErrorCode == nil && ok.item.id == "AbCdEfGhIjKlMnOp" && ok.item.source == .upload)
        #expect(rec.all[0].httpMethod == "PUT" && rec.all[0].url?.path == "/studio/upload")
        #expect(rec.all[0].url?.query == "name=IMG_0412.mov")
        #expect(rec.all[0].value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
        #expect(rec.all[0].value(forHTTPHeaderField: "Authorization") != nil)
        let busy = try await c.upload(file: file, name: "busy.mov", contentType: "video/quicktime", progress: { _ in })
        #expect(busy.sessionID == nil && busy.studioErrorCode == "error.studio.busy")
    }

    @Test func downloadsNeverLeakTheKeyOffHost() async throws {
        let host = uniqueHost()
        let other = uniqueHost()
        let rec = Recorder()
        let otherRec = Recorder()
        StubProtocol.install(host: host) { req in rec.add(req); return (200, ["content-type": "video/mp4"], Data(repeating: 1, count: 64)) }
        StubProtocol.install(host: other) { req in otherRec.add(req); return (200, ["content-type": "video/mp4"], Data(repeating: 2, count: 32)) }
        let c = client(host: host)
        let dir = try makeTempDirectory()

        let tunnel = try await c.download(.open(URL(string: "https://\(other)/tunnel?id=1")!), to: dir.appendingPathComponent("a.mp4"), progress: { _ in })
        #expect(try Data(contentsOf: tunnel).count == 32)
        #expect(otherRec.all[0].value(forHTTPHeaderField: "Authorization") == nil)

        // even a public file on the API's own host is fetched without the key
        _ = try await c.download(.open(URL(string: "https://\(host)/tunnel?id=2")!), to: dir.appendingPathComponent("b.mp4"), progress: { _ in })
        #expect(rec.all[0].value(forHTTPHeaderField: "Authorization") == nil)

        _ = try await c.download(.studioSource(session: "sid"), to: dir.appendingPathComponent("c.mp4"), progress: { _ in })
        #expect(rec.all[1].url?.path == "/studio/sid/source" && rec.all[1].value(forHTTPHeaderField: "Authorization") == nil)

        let item = try await c.download(.libraryItem(id: "AbCdEfGhIjKlMnOp"), to: dir.appendingPathComponent("d.mp4"), progress: { _ in })
        #expect(rec.all[2].url?.path == "/library/items/AbCdEfGhIjKlMnOp/file" && rec.all[2].value(forHTTPHeaderField: "Authorization") != nil)
        #expect(try Data(contentsOf: item).count == 64)
        #expect(c.sourceURL(session: "sid").absoluteString == "https://\(host)/studio/sid/source")
    }

    @Test func httpErrorsBecomeApiErrors() async {
        let host = uniqueHost()
        StubProtocol.install(host: host) { req in
            switch req.url?.path {
            case "/studio": return json(#"{"status":"error","error":{"code":"error.studio.busy"}}"#, status: 429)
            default: return (502, [:], Data("bad gateway".utf8))
            }
        }
        let c = client(host: host)
        await #expect(throws: CobaltError.api(code: "error.studio.busy", httpStatus: 429)) { try await c.createStudio(link: URL(string: "https://x.com/i/status/1")!) }
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 502)) { try await c.library(cursor: nil, limit: 5) }
        StubProtocol.install(host: host) { _ in throw URLError(.timedOut) }
        await #expect(throws: CobaltError.network(.timedOut)) { try await c.session("abc", wait: 0) }
    }
}
