import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// MARK: - helpers

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "live-states", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class Seen: Sendable {
    private let items = Mutex<[URLRequest]>([])
    func add(_ r: URLRequest) { items.withLock { $0.append(r) } }
    var all: [URLRequest] { items.withLock { $0 } }
}

private let liveKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let runID = UUID(uuidString: "5B7B6C2E-1D6A-4C5E-9E0A-0C7A1F0A2B3C")!

private func liveClient(host: String, key: String? = liveKey) -> HTTPCobaltClient {
    HTTPCobaltClient(baseURL: URL(string: "https://\(host)")!, apiKey: { key }, session: StubProtocol.session())
}

private func liveHost() -> String { "live\(UUID().uuidString.prefix(8).lowercased()).test" }

private func ok(_ body: String = "", status: Int = 200) -> (status: Int, headers: [String: String], body: Data) {
    (status, ["content-type": "application/json"], Data(body.utf8))
}

private func registration(start: Bool, token: String? = nil, session: String? = nil) -> LiveRunRegistration {
    LiveRunRegistration(
        run: runID, environment: .sandbox, updateToken: token, session: session, start: start,
        attributes: LiveRunAttributes(run: runID, input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "share"),
        state: LiveContentState.samples["fetching_waking"]!)
}

// MARK: - the shared types and the parity fixture

struct LiveContentStateTests {
    @Test func theFixtureDecodesIntoTheSamplesExactly() throws {
        let decoded = try JSONDecoder().decode([String: LiveContentState].self, from: try fixtureData())
        #expect(Set(decoded.keys) == Set(LiveContentState.samples.keys))
        #expect(decoded.count == 10)
        for (name, state) in decoded {
            #expect(LiveContentState.samples[name] == state, "sample \(name) differs from the fixture")
        }
    }

    @Test func eachSampleEncodesBackToTheFixtureObject() throws {
        // Plain JSONEncoder, no key strategy: the keys are the Swift property names, absent
        // optionals are omitted (never null), `waking` and `packing` always present.
        let fixture = try jsonObject(try fixtureData())
        for (name, state) in LiveContentState.samples {
            let encoded = try jsonObject(try JSONEncoder().encode(state))
            let expected = try #require(fixture[name] as? [String: Any])
            #expect(NSDictionary(dictionary: encoded).isEqual(to: expected), "sample \(name) encodes differently")
            #expect(encoded["waking"] is Bool && encoded["packing"] is Bool)
            #expect(!encoded.values.contains { $0 is NSNull })
        }
    }

    @Test func absentOptionalsAreOmittedAndTimesAreUnixSeconds() throws {
        let s = LiveContentState(stage: .fetching, rail: 0, since: 1_790_000_000)
        let object = try jsonObject(try JSONEncoder().encode(s))
        #expect(Set(object.keys) == ["stage", "rail", "since", "waking", "packing"])
        #expect(object["since"] as? Double == 1_790_000_000)
        #expect(object["stage"] as? String == "fetching")
    }

    @Test func decodingToleratesAMissingWakingOrPackingAndRejectsAnUnknownStage() throws {
        let lean = Data(#"{"stage":"saving","rail":1,"since":5,"bytes":10}"#.utf8)
        let s = try JSONDecoder().decode(LiveContentState.self, from: lean)
        #expect(s.stage == .saving && !s.waking && !s.packing && s.bytes == 10 && s.total == nil)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(LiveContentState.self, from: Data(#"{"stage":"nope","rail":1,"since":5}"#.utf8))
        }
    }

    @Test func terminalStagesAndTheStageList() {
        for stage in LiveContentState.Stage.allCases {
            let s = LiveContentState(stage: stage, rail: 0, since: 0)
            #expect(s.isTerminal == (stage == .done || stage == .failed))
        }
        #expect(LiveContentState.Stage.allCases.map(\.rawValue) ==
                ["fetching", "uploading", "saving", "reading", "ready", "rendering", "done", "failed"])
        #expect(LiveContentState.samples["done"]?.isTerminal == true)
        #expect(LiveContentState.samples["failed_fetch"]?.isTerminal == true)
        #expect(LiveContentState.samples["decoding"]?.isTerminal == false)
    }

    @Test func attributesCarryTheLowercaseRunAndMirrorOneToOne() throws {
        let a = LiveRunAttributes(run: runID, input: "file", service: "file", ref: "IMG_0412.mov", origin: "app")
        #expect(a.run == "5b7b6c2e-1d6a-4c5e-9e0a-0c7a1f0a2b3c")
        let object = try jsonObject(try JSONEncoder().encode(a))
        #expect(Set(object.keys) == ["run", "input", "service", "ref", "origin"])
        #expect(try JSONDecoder().decode(LiveRunAttributes.self, from: JSONEncoder().encode(a)) == a)
        #if os(iOS) && canImport(ActivityKit)
        let c = CobaltActivityAttributes(a)
        #expect(c.run == a.run && c.input == a.input && c.service == a.service && c.ref == a.ref && c.origin == a.origin)
        #expect(String(describing: CobaltActivityAttributes.self) == "CobaltActivityAttributes")
        #endif
    }
}

// MARK: - LiveEnvironment and the provisioning profile

struct LiveEnvironmentTests {
    private func profile(_ aps: String?) -> Data {
        var plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>x</string><key>Entitlements</key><dict>
        """
        if let aps { plist += "<key>aps-environment</key><string>\(aps)</string>" }
        plist += "<key>get-task-allow</key><true/></dict></dict></plist>"
        // the real file is a CMS envelope: binary before and after the plist
        return Data([0x30, 0x82, 0x0A, 0xFF]) + Data(plist.utf8) + Data([0x00, 0x13, 0x37])
    }

    @Test func readsTheApsEnvironmentFromAnEmbeddedProfile() {
        #expect(LiveEnvironment.environment(fromProvisioning: profile("development")) == .sandbox)
        #expect(LiveEnvironment.environment(fromProvisioning: profile("production")) == .production)
    }

    @Test func aProfileWithoutPushOrUnreadableBytesIsNil() {
        #expect(LiveEnvironment.environment(fromProvisioning: profile(nil)) == nil)
        #expect(LiveEnvironment.environment(fromProvisioning: profile("staging")) == nil)
        #expect(LiveEnvironment.environment(fromProvisioning: Data("garbage".utf8)) == nil)
        #expect(LiveEnvironment.environment(fromProvisioning: nil) == nil)
    }

    @Test func aMacOrSimulatorBuildHasNoPushEnvironment() {
        #if !os(iOS) || targetEnvironment(simulator)
        #expect(LiveEnvironment.current == nil)
        #endif
    }

    @Test func rawValuesAreWhatTheServerExpects() {
        #expect(LiveEnvironment.sandbox.rawValue == "sandbox" && LiveEnvironment.production.rawValue == "production")
    }
}

// MARK: - capability

struct LiveCapabilityTests {
    private func caps(_ features: String) async -> Capabilities {
        let host = liveHost()
        StubProtocol.install(host: host) { _ in
            ok(#"{"status":"success","server":"cobalt-cloudflare","cobalt":{"version":"11.7.1"},"features":\#(features),"key":"valid","key_name":"iphone"}"#)
        }
        return await liveClient(host: host).capabilities()
    }

    @Test func liveActivityPushIsReadFromFeatures() async {
        #expect(await caps(#"{"studio":true,"live_activity_push":true}"#).livePush)
        #expect(await caps(#"{"studio":true,"live_activity_push":false}"#).livePush == false)
    }

    @Test func aServerWithoutTheFlagMeansLocalUpdates() async {
        #expect(await caps(#"{"studio":true,"library":true}"#).livePush == false)
        #expect(Capabilities.unknown.livePush == false)
        #expect(PreviewData.capabilities(for: .happy).livePush == false)
    }
}

// MARK: - the new routes

@Suite(.serialized)
struct LiveClientTests {
    @Test func startTokenIsPutKeyedWithTheTokenAndEnvironment() async throws {
        let host = liveHost()
        let seen = Seen()
        StubProtocol.install(host: host) { req in seen.add(req); return (204, [:], Data()) }
        let token = String(repeating: "ab", count: 32)
        try await liveClient(host: host).registerLiveStartToken(token, environment: .production)
        let req = try #require(seen.all.first)
        #expect(req.httpMethod == "PUT" && req.url?.path == "/live/start-token")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Api-Key \(liveKey)")
        let body = try jsonObject(StubProtocol.bodyData(of: req))
        #expect(body["token"] as? String == token && body["environment"] as? String == "production")
        #expect(body.count == 2)
    }

    @Test func registeringARunSendsSnakeCaseOutsideAndCamelCaseInside() async throws {
        let host = liveHost()
        let seen = Seen()
        StubProtocol.install(host: host) { req in
            seen.add(req)
            return ok(#"{"status":"success","pushing":true,"started":true}"#)
        }
        let token = String(repeating: "0f", count: 32)
        let reply = try await liveClient(host: host).registerLiveRun(registration(start: true, token: token, session: "AbCdEfGhIjKlMnOpQrStUv"))
        #expect(reply == LiveRunReply(pushing: true, started: true))
        let req = try #require(seen.all.first)
        // the run id goes into the path lowercased
        #expect(req.httpMethod == "PUT" && req.url?.path == "/live/runs/5b7b6c2e-1d6a-4c5e-9e0a-0c7a1f0a2b3c")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Api-Key \(liveKey)")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let raw = StubProtocol.bodyData(of: req)
        #expect(raw.count <= 4096)
        let body = try jsonObject(raw)
        #expect(Set(body.keys) == ["environment", "update_token", "session", "start", "attributes", "state"])
        #expect(body["environment"] as? String == "sandbox" && body["update_token"] as? String == token)
        #expect(body["session"] as? String == "AbCdEfGhIjKlMnOpQrStUv" && body["start"] as? Bool == true)
        let attributes = try #require(body["attributes"] as? [String: Any])
        #expect(attributes["run"] as? String == "5b7b6c2e-1d6a-4c5e-9e0a-0c7a1f0a2b3c" && attributes["origin"] as? String == "share")
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["stage"] as? String == "fetching" && state["waking"] as? Bool == true)
        #expect(state["since"] as? Double == 1_790_000_000)
    }

    @Test func unknownTokenAndSessionAreExplicitNulls() async throws {
        let host = liveHost()
        let seen = Seen()
        StubProtocol.install(host: host) { req in seen.add(req); return ok(#"{"status":"success","pushing":false,"started":false,"reason":"no_start_token"}"#) }
        let reply = try await liveClient(host: host).registerLiveRun(registration(start: true))
        #expect(reply == LiveRunReply(pushing: false, started: false, reason: "no_start_token"))
        let body = try jsonObject(StubProtocol.bodyData(of: try #require(seen.all.first)))
        #expect(body["update_token"] is NSNull && body["session"] is NSNull)
    }

    @Test func relayPostsTheStateInsideAnEnvelopeAndAccepts202() async throws {
        let host = liveHost()
        let seen = Seen()
        StubProtocol.install(host: host) { req in seen.add(req); return ok(#"{"status":"success"}"#, status: 202) }
        try await liveClient(host: host).relayLiveState(run: runID, LiveContentState.samples["uploading"]!)
        let req = try #require(seen.all.first)
        #expect(req.httpMethod == "POST" && req.url?.path == "/live/runs/5b7b6c2e-1d6a-4c5e-9e0a-0c7a1f0a2b3c/state")
        let body = try jsonObject(StubProtocol.bodyData(of: req))
        #expect(Set(body.keys) == ["state"])
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["bytes"] as? Int == 1_200_000 && state["title"] as? String == "IMG_0412.mov")
    }

    @Test func endingARunIsADeleteWithNoBody() async throws {
        let host = liveHost()
        let seen = Seen()
        StubProtocol.install(host: host) { req in seen.add(req); return (204, [:], Data()) }
        try await liveClient(host: host).endLiveRun(runID)
        let req = try #require(seen.all.first)
        #expect(req.httpMethod == "DELETE" && req.url?.path == "/live/runs/5b7b6c2e-1d6a-4c5e-9e0a-0c7a1f0a2b3c")
        #expect(StubProtocol.bodyData(of: req).isEmpty)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Api-Key \(liveKey)")
    }

    @Test func theKeyIsRequiredAndErrorsKeepTheirCodes() async throws {
        // no key: nothing is sent
        let host = liveHost()
        let seen = Seen()
        StubProtocol.install(host: host) { req in seen.add(req); return (204, [:], Data()) }
        await #expect(throws: CobaltError.noAPIKey) { try await liveClient(host: host, key: nil).endLiveRun(runID) }
        await #expect(throws: CobaltError.noAPIKey) {
            try await liveClient(host: host, key: nil).registerLiveStartToken("00", environment: .sandbox)
        }
        #expect(seen.all.isEmpty)

        // the server's error code survives
        let other = liveHost()
        StubProtocol.install(host: other) { _ in ok(#"{"status":"error","error":{"code":"error.live.not_found"}}"#, status: 404) }
        await #expect(throws: CobaltError.api(code: "error.live.not_found", httpStatus: 404)) {
            try await liveClient(host: other).relayLiveState(run: runID, LiveContentState.samples["ready"]!)
        }
        await #expect(throws: CobaltError.api(code: "error.live.server_stage", httpStatus: 409)) {
            let stub = liveHost()
            StubProtocol.install(host: stub) { _ in ok(#"{"status":"error","error":{"code":"error.live.server_stage"}}"#, status: 409) }
            try await liveClient(host: stub).relayLiveState(run: runID, LiveContentState.samples["saving_storing"]!)
        }
    }

    @Test func theSelftestReadsTheServersAnswer() async throws {
        let host = liveHost()
        StubProtocol.install(host: host) { req in
            #expect(req.httpMethod == "GET" && req.url?.path == "/live/selftest")
            return ok(#"{"status":"success","configured":true,"transport":"worker","host":"api.sandbox.push.apple.com","jwt":"ok","apns_status":400,"apns_reason":"BadDeviceToken"}"#)
        }
        let result = try await liveClient(host: host).liveSelftest()
        #expect(result.isHealthy && result.transport == "worker" && result.apnsStatus == 400 && result.jwt == "ok")

        let off = liveHost()
        StubProtocol.install(host: off) { _ in ok(#"{"status":"success","configured":false}"#) }
        let notConfigured = try await liveClient(host: off).liveSelftest()
        #expect(!notConfigured.configured && !notConfigured.isHealthy)
    }

    @Test func previewClientNeverPushes() async throws {
        let client = PreviewClient()
        let reply = try await client.registerLiveRun(registration(start: false))
        #expect(reply == LiveRunReply(pushing: false, started: false))
        try await client.registerLiveStartToken("00", environment: .sandbox)
        try await client.relayLiveState(run: runID, LiveContentState.samples["ready"]!)
        try await client.endLiveRun(runID)
        #expect(try await client.liveSelftest().configured == false)
    }
}

// MARK: - the Settings row's source

@MainActor
struct LiveStatusTests {
    @Test func macReportsUnavailableAndAnUnsignedDeviceBuildIsLocal() {
        let model = AppModel.preview(.happy)
        #if os(iOS) && canImport(ActivityKit)
        #expect([LiveStatus.localOnly, .off].contains(model.liveStatus))
        #else
        #expect(model.liveStatus == .unavailable)
        #endif
    }
}
