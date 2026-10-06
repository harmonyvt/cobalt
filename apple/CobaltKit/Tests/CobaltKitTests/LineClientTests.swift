import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// APP-API-CONTRACT section 17 on the wire: what `HTTPCobaltClient` sends and how it reads the answers, against a
// stubbed server (as built: queued / queue_ahead only when the caller opted in; GET /studio/line returns
// {status, now, running, entries[], max, wait_ms}).

private final class Seen: Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let bodies = Mutex<[Data]>([])
    func add(_ r: URLRequest) {
        requests.withLock { $0.append(r) }
        bodies.withLock { $0.append(StubProtocol.bodyData(of: r)) }
    }
    var all: [URLRequest] { requests.withLock { $0 } }
    var paths: [String] { all.map { ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "") + ($0.url?.query.map { "?" + $0 } ?? "") } }
    func body(_ i: Int) -> [String: Any] {
        let data = bodies.withLock { $0 }[i]
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

private func ok(_ s: String, status: Int = 200) -> (status: Int, headers: [String: String], body: Data) {
    (status, ["content-type": "application/json"], Data(s.utf8))
}

private func lineClient(_ host: String) -> HTTPCobaltClient {
    HTTPCobaltClient(baseURL: URL(string: "https://\(host)")!, apiKey: { "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21" }, session: StubProtocol.session())
}

private func host() -> String { "l\(UUID().uuidString.prefix(8).lowercased()).test" }

@Suite(.serialized)
struct LineClientTests {
    @Test func capabilitiesReadTheLineFeatureAndLimits() async {
        let h = host()
        StubProtocol.install(host: h) { _ in
            ok(#"{"status":"success","server":"cobalt-cloudflare","cobalt":{"version":"11.7.1"},"features":{"studio":true,"line":true,"notify_bridge":true},"limits":{"line_max":50,"line_wait_ms":1800000},"key":"valid","key_name":"iphone"}"#)
        }
        let caps = await lineClient(h).capabilities()
        #expect(caps.line && caps.notifyBridge && caps.limits.lineMax == 50 && caps.limits.lineWait == 1_800)
        // absent = no line, and the defaults
        StubProtocol.install(host: h) { _ in ok(#"{"server":"cobalt-cloudflare","features":{"studio":true},"key":"valid"}"#) }
        let old = await lineClient(h).capabilities()
        #expect(!old.line && old.limits.lineMax == 50 && old.limits.lineWait == 1_800)
    }

    @Test func createStudioWithQueueAndTitleSendsThemAndReadsTheReply() async throws {
        let h = host()
        let seen = Seen()
        StubProtocol.install(host: h) { req in
            seen.add(req)
            return ok(#"{"status":"success","id":"AbCdEfGhIjKlMnOpQrStUv","url":"https://x/studio/s","queued":true,"queue_ahead":2}"#, status: 201)
        }
        let created = try await lineClient(h).createStudio(link: linkA, public: true, queue: true, title: "the good part")
        #expect(created.id == "AbCdEfGhIjKlMnOpQrStUv" && created.queued && created.queueAhead == 2)
        let body = seen.body(0)
        #expect(body["queue"] as? Bool == true && body["title"] as? String == "the good part" && body["public"] as? Bool == true)
        #expect(body["url"] as? String == linkA.absoluteString)
        #expect(seen.all[0].value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test func createStudioWithoutOptInSendsNothingNewAndReadsNoQueueFields() async throws {
        let h = host()
        let seen = Seen()
        StubProtocol.install(host: h) { req in seen.add(req); return ok(#"{"status":"success","id":"sid","url":null}"#, status: 201) }
        let created = try await lineClient(h).createStudio(link: linkA, public: nil)
        #expect(!created.queued && created.queueAhead == nil)
        #expect(seen.body(0).keys.sorted() == ["url"], "an old server sees exactly what it saw before: \(seen.body(0))")
    }

    @Test func aFullLineIsAnApiError() async {
        let h = host()
        StubProtocol.install(host: h) { _ in ok(#"{"status":"error","error":{"code":"error.studio.line_full"}}"#, status: 429) }
        await #expect(throws: CobaltError.api(code: "error.studio.line_full", httpStatus: 429)) {
            _ = try await lineClient(h).createStudio(link: linkA, public: nil, queue: true, title: nil)
        }
        #expect(mapFailure(code: "error.studio.line_full", during: .saving) == .lineFull)
        #expect(mapFailure(code: "error.studio.line_full", during: .rendering) == .lineFull, "also on renders")
        #expect(PipelineFailure.lineFull.keepsTrim, "a refused render keeps its trim")
    }

    @Test func openStudioTakesQueueAsAQueryFlag() async throws {
        let h = host()
        let seen = Seen()
        StubProtocol.install(host: h) { req in seen.add(req); return ok(#"{"status":"success","id":"sid","url":null,"queued":true,"queue_ahead":1}"#, status: 201) }
        let c = lineClient(h)
        let queued = try await c.openStudio(item: "AbCdEfGhIjKlMnOp", queue: true)
        #expect(queued.queued && queued.queueAhead == 1)
        _ = try await c.openStudio(item: "AbCdEfGhIjKlMnOp")
        #expect(seen.paths == ["POST /library/items/AbCdEfGhIjKlMnOp/studio?queue=1", "POST /library/items/AbCdEfGhIjKlMnOp/studio"])
    }

    @Test func uploadCarriesQueueAndTitleInTheQueryAndReadsQueuedFromTheAnswer() async throws {
        let h = host()
        let seen = Seen()
        StubProtocol.install(host: h) { req in
            seen.add(req)
            let item = #"{"id":"AbCdEfGhIjKlMnOp","kind":"private","source":"upload","name":"c.mov","url":null,"content_type":"video/quicktime","bytes":1000,"width":null,"height":null,"duration":null,"link":null,"session_id":null,"created_at":1790000000000}"#
            return ok(#"{"status":"success","id":"sid","url":null,"item":\#(item),"studio_error":null,"queued":true,"queue_ahead":3}"#, status: 201)
        }
        let file = try makeTempFile("c.mov", bytes: 1_000)
        let r = try await lineClient(h).upload(
            file: file, name: "c.mov", contentType: "video/quicktime", public: true, queue: true, title: "a & b / c", progress: { _ in })
        #expect(r.sessionID == "sid" && r.queued && r.queueAhead == 3)
        let query = URLComponents(url: seen.all[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "queue" }?.value == "1" && query.first { $0.name == "public" }?.value == "1")
        #expect(query.first { $0.name == "title" }?.value == "a & b / c", "the title survives the encoding: \(seen.paths)")
        #expect(seen.all[0].url?.absoluteString.contains("title=a%20%26%20b%20%2F%20c") == true)
    }

    @Test func renderSendsQueueAndPriorityOnlyTogether() async throws {
        let h = host()
        let seen = Seen()
        StubProtocol.install(host: h) { req in seen.add(req); return ok(#"{"status":"pending","job":"job1","queued":true,"queue_ahead":2}"#, status: 202) }
        let c = lineClient(h)
        _ = try await c.render(session: "s", RenderRequest(start: 0, length: 5, width: 480, quality: .med, queue: true, priority: "focused"))
        _ = try await c.render(session: "s", RenderRequest(start: 0, length: 5, width: 480, quality: .med, queue: nil, priority: "focused"))
        _ = try await c.render(session: "s", RenderRequest(start: 0, length: 5, width: 480, quality: .med))
        #expect(seen.body(0)["queue"] as? Bool == true && seen.body(0)["priority"] as? String == "focused")
        #expect(seen.body(1)["queue"] == nil && seen.body(1)["priority"] == nil, "`priority` without `queue` is a 400: never sent")
        #expect(seen.body(2)["queue"] == nil && seen.body(2)["priority"] == nil)
    }

    @Test func aQueuedRenderPollIsPendingWithPhaseQueuedAndItsPlace() async throws {
        let h = host()
        StubProtocol.install(host: h) { _ in ok(#"{"status":"pending","job":"job1","phase":"queued","frames_done":null,"frames_total":null,"queue_ahead":2}"#) }
        let status = try await lineClient(h).renderStatus(session: "s", job: "job1", wait: 0)
        #expect(status == .pending(phase: .queued, framesDone: nil, framesTotal: nil, queueAhead: 2))
    }

    @Test func aQueuedSessionDecodesStepQueuedAndQueueAhead() throws {
        let json = #"{"status":"saving","id":"sid","link":"https://x.com/i/status/1","service":"x","step":"queued","step_bytes":null,"step_total":null,"waking":false,"queue_ahead":3,"created_at":1790000000000,"expires_at":1790600000000,"renders":[]}"#
        let s = try CobaltJSON.decoder().decode(StudioSession.self, from: Data(json.utf8))
        #expect(s.status == .saving && s.step == .queued && s.queueAhead == 3)
        // every session body has it; null when not queued, and a step from a newer server is "not said"
        let plain = #"{"status":"saving","id":"sid","step":"fetching","queue_ahead":null,"created_at":1790000000000,"expires_at":1790600000000,"renders":[]}"#
        #expect(try CobaltJSON.decoder().decode(StudioSession.self, from: Data(plain.utf8)).queueAhead == nil)
        let future = #"{"status":"saving","id":"sid","step":"warming","created_at":1790000000000,"expires_at":1790600000000,"renders":[]}"#
        #expect(try CobaltJSON.decoder().decode(StudioSession.self, from: Data(future.utf8)).step == nil)
    }

    @Test func cancelQueuedMapsTheAnswers() async throws {
        let h = host()
        let seen = Seen()
        let mode = Mutex("cancel")
        StubProtocol.install(host: h) { req in
            seen.add(req)
            switch mode.withLock({ $0 }) {
            case "started": return ok(#"{"status":"error","error":{"code":"error.studio.started"}}"#, status: 409)
            case "missing": return ok(#"{"status":"error","error":{"code":"error.studio.not_found"}}"#, status: 404)
            default: return ok(#"{"status":"success","cancelled":true}"#)
            }
        }
        let c = lineClient(h)
        #expect(try await c.cancelQueued(session: "AbCdEfGhIjKlMnOpQrStUv") == .cancelled)
        #expect(try await c.cancelQueued(session: "AbCdEfGhIjKlMnOpQrStUv", job: "job1") == .cancelled)
        mode.withLock { $0 = "started" }
        #expect(try await c.cancelQueued(session: "AbCdEfGhIjKlMnOpQrStUv") == .started)
        mode.withLock { $0 = "missing" }
        await #expect(throws: CobaltError.api(code: "error.studio.not_found", httpStatus: 404)) { _ = try await c.cancelQueued(session: "x") }
        #expect(seen.paths.prefix(2) == ["DELETE /studio/AbCdEfGhIjKlMnOpQrStUv/line", "DELETE /studio/AbCdEfGhIjKlMnOpQrStUv/render/job1"])
        #expect(seen.all[0].value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test func theLineSnapshotDecodesTheAsBuiltShape() async throws {
        let h = host()
        StubProtocol.install(host: h) { _ in
            ok(#"""
            {"status":"success","now":1790000000000,
             "running":{"kind":"save","mine":false,"sid":null,"job":null,"origin":"share","key_name":"iphone"},
             "entries":[
               {"position":3,"kind":"render","mine":false,"sid":null,"job":null,"at":1789999995000,"origin":null,"priority":null,"key_name":"iphone","link":null},
               {"position":2,"kind":"save","mine":true,"sid":"AbCdEfGhIjKlMnOpQrStUv","job":null,"at":1789999990000,"origin":null,"priority":null,"key_name":"mac","link":"https://www.instagram.com/reel/Dd7P496wolG/"},
               {"oops":1}],
             "max":50,"wait_ms":1800000}
            """#)
        }
        let snap = try await lineClient(h).line()
        #expect(snap.running == .init(kind: "save", mine: false, sid: nil, job: nil, origin: "share", keyName: "iphone"))
        #expect(snap.entries.map(\.position) == [2, 3], "sorted by position; a malformed row is dropped")
        #expect(snap.entries[0].mine && snap.entries[0].sid == "AbCdEfGhIjKlMnOpQrStUv" && snap.entries[0].link == linkA.absoluteString)
        #expect(!snap.entries[1].mine && snap.entries[1].keyName == "iphone" && snap.entries[1].kind == "render")
        #expect(snap.max == 50 && snap.waitMs == 1_800_000)
        // free helper
        StubProtocol.install(host: h) { _ in ok(#"{"status":"success","now":1,"running":null,"entries":[],"max":50,"wait_ms":1800000}"#) }
        let free = try await lineClient(h).line()
        #expect(free.running == nil && free.entries.isEmpty)
    }

    @Test func lineNotifyPutsAnEmptyBodyAndDeleteIsIdempotent() async throws {
        let h = host()
        let seen = Seen()
        StubProtocol.install(host: h) { req in
            seen.add(req)
            if req.httpMethod == "DELETE" { return (204, [:], Data()) }
            return ok(#"{"status":"success","bridge":true,"watching":4,"expires_at":1790086400000}"#)
        }
        let c = lineClient(h)
        #expect(try await c.setLineNotify() == 4)
        try await c.cancelLineNotify()
        try await c.cancelLineNotify()
        #expect(seen.paths == ["PUT /studio/line/notify", "DELETE /studio/line/notify", "DELETE /studio/line/notify"])
        #expect(seen.body(0).isEmpty, "empty or {}: anything else is a 400")
        StubProtocol.install(host: h) { _ in ok(#"{"status":"success","bridge":false,"watching":0,"expires_at":null}"#) }
        #expect(try await c.setLineNotify() == 0)
    }

    @Test func oldClientsCompileAndSayTheServerCannot() async {
        struct Old: CobaltClient {
            var baseURL: URL { linkA }
            func capabilities() async -> Capabilities { .unknown }
            func resolve(_ link: URL) async throws -> CobaltResult { .localProcessing }
            func createStudio(link: URL) async throws -> StudioCreated { StudioCreated(id: "x", pageURL: nil) }
            func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult { throw PipelineFailure.unsupported }
            func session(_ id: String, wait: Int) async throws -> StudioSession { throw PipelineFailure.unsupported }
            func sourceURL(session id: String) -> URL { linkA }
            func render(session id: String, _ request: RenderRequest) async throws -> String { "job" }
            func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { .failed(code: "x") }
            func publish(session id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
            func publish(item id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
            func openStudio(item id: String) async throws -> StudioCreated { StudioCreated(id: "item", pageURL: nil) }
            func library(cursor: String?, limit: Int) async throws -> LibraryPage { throw PipelineFailure.unsupported }
            func deleteMedia(name: String) async throws {}
            func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
            func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { LiveRunReply(pushing: false, started: false) }
            func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
            func endLiveRun(_ run: UUID) async throws {}
            func liveSelftest() async throws -> LiveSelftest { LiveSelftest(configured: false) }
            func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL { destination }
        }
        let c = Old()
        #expect((try? await c.createStudio(link: linkA, public: nil, queue: true, title: "t"))?.id == "x", "queue is ignored: it falls back to the plain create")
        #expect((try? await c.openStudio(item: "i", queue: true))?.id == "item")
        await #expect(throws: PipelineFailure.unsupported) { _ = try await c.line() }
        await #expect(throws: PipelineFailure.unsupported) { _ = try await c.cancelQueued(session: "s") }
        #expect((try? await c.setLineNotify()) == 0)
    }
}
