import Foundation
import Synchronization
import Testing
@testable import CobaltKit

/// Records every body it is asked to send and answers from a script (then 202 forever).
final class FakeTelemetryTransport: TelemetryTransport, Sendable {
    private struct State {
        var bodies: [Data] = []
        var script: [Result<TelemetryHTTPResponse, URLError>] = []
    }
    private let state = Mutex(State())

    init(script: [Result<TelemetryHTTPResponse, URLError>] = []) { state.withLock { $0.script = script } }

    var bodies: [Data] { state.withLock { $0.bodies } }
    var calls: Int { state.withLock { $0.bodies.count } }

    func send(_ body: Data) async throws -> TelemetryHTTPResponse {
        let next = state.withLock { s -> Result<TelemetryHTTPResponse, URLError>? in
            s.bodies.append(body)
            return s.script.isEmpty ? nil : s.script.removeFirst()
        }
        switch next {
        case .success(let r): return r
        case .failure(let e): throw e
        case nil: return TelemetryHTTPResponse(status: 202)
        }
    }

    /// The decoded JSON of each body.
    func objects() throws -> [[String: Any]] {
        try bodies.map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }
}

/// A value several closures share (a `Mutex` itself cannot be captured).
final class LockedBox<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ initial: T) { value = Mutex(initial) }
    func withLock<R>(_ body: (inout T) -> R) -> R { value.withLock { body(&$0) } }
}

@Suite("telemetry uploader")
struct TelemetryUploaderTests {
    static let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
    static let info = TelemetryAppInfo(version: "1.2", build: "3", platform: "ios", os: "iOS 26.0", device: "iPhone17,1", process: .app)

    private func runtime(_ process: TelemetryProcess = .app) throws -> TelemetryRuntime {
        TelemetryRuntime(directory: try makeTempDirectory(), process: process, mirrorToOSLog: false)
    }

    private func uploader(
        _ rt: TelemetryRuntime, gate: @escaping @Sendable () async -> TelemetryGate,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> TelemetryUploader {
        TelemetryUploader(
            log: rt.log, crashes: rt.crashes, stateURL: rt.uploadStateURL, app: { Self.info }, install: { "install-uuid" },
            gate: gate, now: now)
    }

    private func allowed(_ t: FakeTelemetryTransport) -> @Sendable () async -> TelemetryGate {
        { .allowed(transport: t, secrets: [Self.key]) }
    }

    private func log(_ rt: TelemetryRuntime, _ n: Int, process: TelemetryProcess = .app) {
        for i in 0..<n { rt.log.log(.info, .pipeline, "event \(i)") }
        rt.log.flush()
    }

    private func crash(_ n: Int, payload: Data? = Data(#"{"k":1}"#.utf8)) -> PendingCrash {
        PendingCrash(record: CrashRecord(id: "c\(n)", ts: Int64(n), kind: .crash, summary: "s", events: [], hasPayload: payload != nil), payload: payload)
    }

    private func storedEvents(_ n: Int, process: TelemetryProcess = .app, msg: String = "m") -> [StoredEvent] {
        (0..<n).map { StoredEvent(i: "r.\($0)", p: process, e: TelemetryEvent(ts: Int64($0), level: .info, cat: .app, msg: msg)) }
    }

    // MARK: batching

    @Test func splitsByEventCountCrashCountAndProcess() {
        let events = storedEvents(1_200)
        let crashes = (0..<25).map { crash($0) }
        let batches = TelemetryBatcher.split(events: events, crashes: crashes)
        // crashes first, ten at a time; then events, 500 at a time
        #expect(batches.map { $0.crashes.count } == [10, 10, 5, 0, 0, 0])
        #expect(batches.map { $0.events.count } == [0, 0, 0, 500, 500, 200])
        #expect(batches.flatMap(\.events).map(\.i) == events.map(\.i))      // nothing lost, nothing doubled, in order

        let mixed = storedEvents(3) + storedEvents(2, process: .share).map { var e = $0; e.i = "s.\(e.i)"; return e }
        let split = TelemetryBatcher.split(events: mixed, crashes: [])
        #expect(split.map(\.process) == [.app, .share])                     // a batch names one process
    }

    @Test func splitsByBodySize() {
        let events = storedEvents(300, msg: String(repeating: "x", count: 250))
        let limits = TelemetryBatcher.Limits(events: 500, crashes: 10, bodyBytes: 20_000)
        let batches = TelemetryBatcher.split(events: events, crashes: [], limits: limits)
        #expect(batches.count > 3)
        #expect(batches.flatMap(\.events).count == 300)
        let info = Self.info
        for batch in batches {
            let body = try? TelemetryBody.encode(batch: batch, app: info, install: "i")
            #expect((body?.count ?? .max) <= 20_000)
        }
        // big crash payloads: each is its own request when two do not fit together
        let big = (0..<3).map { crash($0, payload: Data(#"{"p":""#.utf8) + Data(repeating: 0x61, count: 12_000) + Data(#""}"#.utf8)) }
        #expect(TelemetryBatcher.split(events: [], crashes: big, limits: limits).map { $0.crashes.count } == [1, 1, 1])
    }

    @Test func aSingleOversizedCrashStillFormsABatch() {
        let huge = crash(1, payload: Data(#"{"p":""#.utf8) + Data(repeating: 0x61, count: 50_000) + Data(#""}"#.utf8))
        let batch = TelemetryBatcher.next(events: [], crashes: [huge], limits: .init(events: 500, crashes: 10, bodyBytes: 10_000))
        #expect(batch?.crashes.count == 1)
    }

    // MARK: the wire

    @Test func theBodyIsTheContractsShape() async throws {
        let rt = try runtime()
        rt.log.log(.warn, .upload, "upload failed", data: ["code": "error.x", "bytes": 12])
        rt.crashes.add(CrashRecord(id: "ue-1", ts: 9, kind: .uncleanExit, summary: "gone", events: [TelemetryEvent(ts: 1, level: .info, cat: .app, msg: "e")], hasPayload: false), payload: nil)
        let t = FakeTelemetryTransport()
        let result = await uploader(rt, gate: allowed(t)).upload()
        #expect(result == TelemetrySendResult(.done, events: 1, crashes: 1))
        let bodies = try t.objects()
        #expect(bodies.count == 2)                                          // crashes alone, then events
        for body in bodies {
            let app = try #require(body["app"] as? [String: Any])
            #expect(app["version"] as? String == "1.2")
            #expect(app["build"] as? String == "3")
            #expect(app["platform"] as? String == "ios")
            #expect(app["os"] as? String == "iOS 26.0")
            #expect(app["device"] as? String == "iPhone17,1")
            #expect(app["process"] as? String == "app")
            #expect(body["install"] as? String == "install-uuid")
            #expect(body["events"] is [Any])
            #expect(body["crashes"] is [Any])
        }
        let crash = try #require((bodies[0]["crashes"] as? [[String: Any]])?.first)
        #expect(crash["kind"] as? String == "unclean_exit")
        #expect(crash["summary"] as? String == "gone")
        #expect(crash["ts"] as? Int == 9)
        #expect(crash["payload"] is NSNull)
        let event = try #require((bodies[1]["events"] as? [[String: Any]])?.first)
        #expect(event["level"] as? String == "warn")
        #expect(event["cat"] as? String == "upload")
        #expect(event["msg"] as? String == "upload failed")
        #expect((event["data"] as? [String: Any])?["code"] as? String == "error.x")
        #expect((event["data"] as? [String: Any])?["bytes"] as? Int == 12)
        #expect(event["ts"] is Int)
    }

    @Test func eventsFromAnotherProcessGoInTheirOwnBatchLabelledSo() async throws {
        let dir = try makeTempDirectory()
        let appRT = TelemetryRuntime(directory: dir, process: .app, mirrorToOSLog: false)
        let shareLog = TelemetryLog(directory: dir, process: .share, mirrorToOSLog: false)
        appRT.log.log(.info, .app, "from the app")
        shareLog.log(.info, .share, "from the share sheet")
        shareLog.flush()
        let t = FakeTelemetryTransport()
        _ = await uploader(appRT, gate: allowed(t)).upload()
        let processes = try t.objects().map { ($0["app"] as? [String: Any])?["process"] as? String }
        #expect(Set(processes.compactMap { $0 }) == ["app", "share"])
    }

    // MARK: accepted → gone; failure → kept

    @Test func acceptedEventsAndCrashesAreNotSentAgain() async throws {
        let rt = try runtime()
        log(rt, 30)
        rt.crashes.add(CrashRecord(id: "c1", ts: 1, kind: .hang, summary: "h", events: [], hasPayload: false), payload: nil)
        let t = FakeTelemetryTransport()
        let up = uploader(rt, gate: allowed(t))
        let first = await up.upload()
        #expect(first.outcome == .done)
        #expect(first.events == 30)
        #expect(first.crashes == 1)
        #expect(rt.crashes.count == 0)                                      // deleted once accepted
        let calls = t.calls
        let second = await up.upload()
        #expect(second.outcome == .nothingToSend)
        #expect(t.calls == calls)                                           // and not a request more
        let pending = await up.pendingCounts()
        #expect(pending.events == 0)
        // new events after that are sent, the old ones are not
        rt.log.log(.info, .app, "later")
        let third = await up.upload()
        #expect(third.events == 1)
    }

    @Test func theSentMarkSurvivesARelaunch() async throws {
        let rt = try runtime()
        log(rt, 5)
        let t = FakeTelemetryTransport()
        _ = await uploader(rt, gate: allowed(t)).upload()
        let again = await uploader(rt, gate: allowed(t)).upload()            // a new uploader reads the state file
        #expect(again.outcome == .nothingToSend)
    }

    @Test func aFailureKeepsEverythingAndBacksOffExponentially() async throws {
        let rt = try runtime()
        log(rt, 10)
        rt.crashes.add(CrashRecord(id: "c1", ts: 1, kind: .crash, summary: "c", events: [], hasPayload: false), payload: nil)
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let now: @Sendable () -> Date = { clock.withLock { $0 } }
        let t = FakeTelemetryTransport(script: [
            .success(.init(status: 500)), .success(.init(status: 500)), .failure(URLError(.notConnectedToInternet)),
        ])
        let up = uploader(rt, gate: allowed(t), now: now)

        let r1 = await up.upload()
        #expect(r1.outcome == .failed(code: "http.500"))
        #expect(rt.crashes.count == 1)                                      // kept
        let pending = await up.pendingCounts()
        #expect(pending.events >= 10)                                       // plus the note the failure itself logged
        #expect(pending.crashes == 1)
        // inside the 30 s backoff nothing is sent...
        clock.withLock { $0 = $0.addingTimeInterval(10) }
        let blocked = await up.upload()
        #expect(blocked.outcome == .backingOff(until: Date(timeIntervalSince1970: 1_800_000_030)))
        #expect(t.calls == 1)
        // ...after it, the next failure doubles the wait (60 s)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_031) }
        let r2 = await up.upload()
        #expect(r2.outcome == .failed(code: "http.500"))
        #expect((await up.upload()).outcome == .backingOff(until: Date(timeIntervalSince1970: 1_800_000_031 + 60)))
        // a manual send ignores the wait; a network failure is a failure too (120 s now)
        let manual = await up.upload(force: true)
        #expect(manual.outcome == .failed(code: "network"))
        #expect((await up.upload()).outcome == .backingOff(until: Date(timeIntervalSince1970: 1_800_000_031 + 120)))
        // and when the server finally answers, everything goes and the backoff resets
        let ok = await up.upload(force: true)
        #expect(ok.outcome == .done)
        #expect(ok.events >= 10)
        #expect(rt.crashes.count == 0)
        rt.log.log(.info, .app, "after")
        #expect((await up.upload()).outcome == .done)                       // no wait left over
    }

    @Test func backoffDoublesFromThirtySecondsUpToAnHour() {
        #expect([1, 2, 3, 4, 8, 20].map { TelemetryUploader.backoff(afterFailures: $0) } == [30, 60, 120, 240, 3_600, 3_600])
    }

    @Test func aRetryAfterFromTheServerIsHonoured() async throws {
        let rt = try runtime()
        log(rt, 3)
        let t = FakeTelemetryTransport(script: [.success(.init(status: 429, errorCode: "error.telemetry.rate_limited", retryAfter: 600))])
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let up = uploader(rt, gate: allowed(t), now: { clock.withLock { $0 } })
        #expect((await up.upload()).outcome == .failed(code: "error.telemetry.rate_limited"))
        #expect((await up.upload()).outcome == .backingOff(until: Date(timeIntervalSince1970: 1_800_000_600)))
    }

    @Test func aPartialRunKeepsWhatWasAcceptedAndRetriesTheRest() async throws {
        let rt = try runtime()
        log(rt, 1_100)
        // first batch (500) accepted, second refused
        let t = FakeTelemetryTransport(script: [.success(.init(status: 202)), .success(.init(status: 503))])
        let up = uploader(rt, gate: allowed(t))
        let r = await up.upload()
        #expect(r.outcome == .failed(code: "http.503"))
        #expect(r.events == 500)
        #expect((await up.pendingCounts()).events >= 600)
        let rest = await up.upload(force: true)
        #expect(rest.outcome == .done)
        #expect(rest.events >= 600)
    }

    @Test func aRejectedBatchIsDroppedSoItCannotWedgeTheQueue() async throws {
        let rt = try runtime()
        rt.crashes.add(CrashRecord(id: "bad", ts: 1, kind: .crash, summary: "c", events: [], hasPayload: false), payload: nil)
        log(rt, 4)
        let t = FakeTelemetryTransport(script: [.success(.init(status: 400, errorCode: "error.telemetry.invalid"))])
        let r = await uploader(rt, gate: allowed(t)).upload()
        #expect(r.outcome == .done)                                         // the events behind it still went
        #expect(r.events == 4)
        #expect(rt.crashes.count == 0)
    }

    @Test func aTooLargeAnswerShrinksTheBatches() async throws {
        let rt = try runtime()
        for n in 0..<1_200 { rt.log.log(.info, .app, "event \(n) " + String(repeating: "q", count: 200)) }
        rt.log.flush()
        let t = FakeTelemetryTransport(script: [.success(.init(status: 413, errorCode: "error.telemetry.too_large"))])
        let r = await uploader(rt, gate: allowed(t)).upload()
        #expect(r.outcome == .done)
        #expect(r.events == 1_200)
        let sizes = t.bodies.map(\.count)
        #expect(sizes.count > 2)
        #expect(sizes[1] < sizes[0])                                        // smaller after the 413
    }

    // MARK: nothing leaves when it must not

    @Test func serverWithoutTelemetryDisabledOrWithoutAKeyMeansNoNetwork() async throws {
        let rt = try runtime()
        log(rt, 20)
        let t = FakeTelemetryTransport()
        for (gate, expected) in [
            (TelemetryGate.unsupported, TelemetrySendResult.Outcome.unsupported),
            (.disabled, .disabled), (.noKey, .noKey),
        ] {
            let result = await uploader(rt, gate: { gate }).upload(force: true)
            #expect(result.outcome == expected)
        }
        #expect(t.calls == 0)
        // nothing was marked sent either: it all goes once allowed
        let later = await uploader(rt, gate: allowed(t)).upload()
        #expect(later.events == 20)
    }

    @MainActor
    @Test func theServiceReadsTheToggleTheCapabilityAndTheKeyAtUploadTime() async throws {
        let rt = try runtime()
        log(rt, 6)
        let defaults = UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults, keychain: .memory())
        var caps = Capabilities.unknown
        caps.kind = .fork
        let capsBox = LockedBox(caps)
        let t = FakeTelemetryTransport()
        let service = TelemetryService(
            runtime: rt, settings: settings, capabilities: { capsBox.withLock { $0 } },
            makeTransport: { _, _ in t }, app: Self.info, install: { "i" })

        #expect(settings.sendTelemetry)                                      // on by default
        #expect(await service.sendNow().outcome == .unsupported)             // the server does not say it takes logs
        #expect(t.calls == 0)

        capsBox.withLock { $0.telemetry = true }
        #expect(await service.sendNow().outcome == .noKey)                   // no key yet
        try settings.setAPIKey(pasted: Self.key)
        settings.sendTelemetry = false
        #expect(await service.sendNow().outcome == .disabled)                // the owner said no
        #expect(t.calls == 0)

        settings.sendTelemetry = true
        let sent = await service.sendNow()
        #expect(sent.outcome == .done)
        #expect(sent.events >= 6)
        #expect(t.calls >= 1)
        // and the key itself is nowhere in what went out
        #expect(t.bodies.allSatisfy { $0.range(of: Data(Self.key.utf8)) == nil })
    }

    @MainActor
    @Test func theLifecycleMarksRunningUntilTerminateAndUploadsWhenActive() async throws {
        let rt = try runtime()
        log(rt, 3)
        let settings = Settings(defaults: UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!, keychain: .memory())
        try settings.setAPIKey(pasted: Self.key)
        var caps = Capabilities.unknown
        caps.kind = .fork
        caps.telemetry = true
        let t = FakeTelemetryTransport()
        let service = TelemetryService(
            runtime: rt, settings: settings, capabilities: { caps }, makeTransport: { _, _ in t }, app: Self.info, install: { "i" })

        service.becameActive()
        #expect(UncleanExit.leftover(in: rt.directory) != nil)              // running
        for _ in 0..<200 where t.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(t.calls >= 1)                                               // becoming active uploaded
        service.terminating()
        #expect(UncleanExit.leftover(in: rt.directory) == nil)              // a clean end
    }

    // MARK: privacy

    @Test func theKeyNeverLeavesInAPayloadEvenWhenSomethingLoggedIt() async throws {
        let rt = try runtime()
        rt.log.log(.error, .net, "request failed with key \(Self.key)", data: ["header": .string("Api-Key \(Self.key)"), "apiKey": .string(Self.key)])
        rt.log.flush()
        let payloadWithKey = Data(#"{"diagnosticMetaData":{"terminationReason":"\#(Self.key)"}}"#.utf8)
        DiagnosticIngest.ingest(payloadWithKey, kind: .crash, at: TelemetryLog.nowMillis(), into: rt.crashes, log: rt.log)
        let t = FakeTelemetryTransport()
        let result = await uploader(rt, gate: allowed(t)).upload()
        #expect(result.outcome == .done)
        #expect(t.calls >= 2)
        for body in t.bodies { #expect(body.range(of: Data(Self.key.utf8)) == nil) }
        // the line is still there, with the secret blotted out
        let text = t.bodies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(text.contains("request failed with key [redacted]"))
    }

    // MARK: the real transport

    @Test func theHTTPTransportPostsJSONWithTheApiKeyHeader() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","accepted":{"events":1,"crashes":0}}"#, status: 202) }
        defer { server.stop() }
        let transport = HTTPTelemetryTransport(baseURL: server.base, apiKey: Self.key)
        let response = try await transport.send(Data(#"{"app":{},"events":[],"crashes":[]}"#.utf8))
        #expect(response.status == 202)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/telemetry")
        #expect(request.headers["authorization"] == "Api-Key \(Self.key)")
        #expect(request.headers["content-type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"app":{},"events":[],"crashes":[]}"#)
    }

    @Test func theHTTPTransportReadsTheErrorCodeAndRetryAfter() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(status: 429, headers: ["content-type": "application/json", "retry-after": "120"],
                                    body: Data(#"{"status":"error","error":{"code":"error.telemetry.rate_limited"}}"#.utf8))
        }
        defer { server.stop() }
        let response = try await HTTPTelemetryTransport(baseURL: server.base, apiKey: Self.key).send(Data("{}".utf8))
        #expect(response.status == 429)
        #expect(response.errorCode == "error.telemetry.rate_limited")
        #expect(response.retryAfter == 120)
    }

    @Test func theCapabilityIsReadFromTheFeatures() {
        func caps(_ features: String) -> Capabilities? {
            HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{\#(features)}}"#.utf8))
        }
        #expect(caps(#""telemetry":true"#)?.telemetry == true)
        #expect(caps(#""telemetry":false"#)?.telemetry == false)
        #expect(caps(#""studio":true"#)?.telemetry == false)                // an older deploy: absent means no
        #expect(Capabilities.unknown.telemetry == false)
    }
}
