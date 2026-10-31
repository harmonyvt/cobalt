import Foundation
import Testing
@testable import CobaltKit

// Accounts (APP-API-CONTRACT 42): the PKCE pair, the sign-in page and its return, the 42.5 wire shapes, the real client's
// requests and refusals, and the app's three states (first launch, move-over, signed out) over the preview server.

struct AccountAuthTests {
    @Test func challengeMatchesTheRFC7636Vector() {
        #expect(AccountAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIs43Base64urlCharactersAndFresh() {
        let a = AccountAuth.makeVerifier()
        let b = AccountAuth.makeVerifier()
        #expect(a.count == 43 && b.count == 43)
        #expect(a != b)
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.allSatisfy(alphabet.contains))
        #expect(AccountAuth.challenge(for: a).count == 43)
    }

    @Test func base64urlHasNoPaddingOrUnsafeCharacters() {
        #expect(AccountAuth.base64url(Data([0xfb, 0xff])) == "-_8")
        #expect(AccountAuth.base64url(Data([0x00])) == "AA")
    }

    @Test func startURLCarriesTheThreeValuesEncoded() throws {
        let url = try #require(AccountAuth.startURL(platform: "ios", device: "harmony's iphone+1", challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
        #expect(url.scheme == "https")
        #expect(url.host() == "cobalt.capybaraharmony.com")
        #expect(url.path() == "/api/auth/app")
        #expect(url.query(percentEncoded: true)?.contains("device=harmony%27s%20iphone%2B1") == true)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "platform" }?.value == "ios")
        #expect(items.first { $0.name == "device" }?.value == "harmony's iphone+1")
        #expect(items.first { $0.name == "challenge" }?.value == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func callbackGivesItsCodeAndNothingElseDoes() {
        let code = "Zm9vYmFyYmF6cXV4MDEyMzQ1Njc4OWFiY2RlZmdoaWo"
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://signed-in?code=\(code)")!) == code)
        #expect(AccountAuth.code(from: URL(string: "COBALT-APPLE://Signed-In?code=\(code)")!) == code)
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://signed-in?state=1&code=\(code)")!) == code)
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://signed-in")!) == nil)
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://signed-in?code=")!) == nil)
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://signed-in?code=short")!) == nil)
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://signed-in?code=\(code)%20x")!) == nil)
        #expect(AccountAuth.code(from: URL(string: "cobalt-apple://job?code=\(code)")!) == nil)
        #expect(AccountAuth.code(from: URL(string: "https://signed-in?code=\(code)")!) == nil)
        #expect(AccountAuth.isCallback(URL(string: "cobalt-apple://signed-in?code=x")!))
        #expect(!AccountAuth.isCallback(URL(string: "cobalt-apple://library")!))
    }

    @Test func deviceNamesAreCleaned() {
        #expect(AccountDevice.clean("  Harmony’s iPhone\n", fallback: "iphone") == "harmony’s iphone")
        #expect(AccountDevice.clean(nil, fallback: "mac") == "mac")
        #expect(AccountDevice.clean(" \u{7} ", fallback: "ipad") == "ipad")
        let long = AccountDevice.clean(String(repeating: "a", count: 60), fallback: "mac")
        #expect(long.utf16.count == 40)
    }
}

struct AccountWireTests {
    @Test func decodesSessions() throws {
        let json = #"""
        {"sessions":[
          {"id":"s1","device":"harmony's iphone","platform":"ios","created_at":1790000000000,"last_used_at":1790000600000,
           "expires_at":1797776600000,"country":"AU","current":true},
          {"id":"s2","device":"safari on mac","platform":"web","created_at":1790000000000,"last_used_at":null,
           "expires_at":null,"country":null,"current":false},
          {"device":"no id, skipped"},
          {"id":"s3","device":"odd","platform":"fridge","created_at":1}
        ]}
        """#
        let list = try AccountSession.decodeList(Data(json.utf8))
        #expect(list.map(\.id) == ["s1", "s2", "s3"])
        #expect(list[0].current && list[0].kind == .ios && list[0].country == "AU")
        #expect(list[0].lastUsedAt == Date(timeIntervalSince1970: 1_790_000_600))
        #expect(!list[1].current && list[1].lastUsedAt == nil && list[1].country == nil && list[1].kind == .web)
        #expect(list[2].kind == .web && !list[2].current)
    }

    @Test func decodesKeysWithTheOldPasteTag() throws {
        let json = #"""
        {"keys":[{"id":"k1","name":"claude code mcp","prefix":"3f9a1c2e","created_at":1,"last_used_at":2,"old_paste":false},
                 {"id":"k2","name":"iphone","prefix":"c02e77f1","created_at":1,"last_used_at":null,"old_paste":true}]}
        """#
        let keys = try AccountKey.decodeList(Data(json.utf8))
        #expect(keys.count == 2)
        #expect(!keys[0].oldPaste && keys[1].oldPaste && keys[1].prefix == "c02e77f1" && keys[1].lastUsedAt == nil)
    }

    @Test func decodesMeAndTheExchange() throws {
        let me = try AccountMe.decode(Data(#"""
        {"caller":{"kind":"session","id":"s1","device":"mac studio","platform":"mac","email":"o@x.test","expires_at":1797776600000},
         "sessions":5,"keys":4}
        """#.utf8))
        #expect(me.caller.kind == .session && me.caller.email == "o@x.test" && me.sessions == 5 && me.keys == 4)
        let key = try AccountMe.decode(Data(#"{"caller":{"kind":"key","id":"k1"},"sessions":0,"keys":2}"#.utf8))
        #expect(key.caller.kind == .key && key.caller.email == nil)

        let exchange = try AuthExchange.decode(Data(#"""
        {"status":"success","key":"0f0e6c1a-6a0b-4c8e-9d1e-2b3c4d5e6f70",
         "session":{"id":"s9","device":"iphone","platform":"ios","created_at":1,"last_used_at":1,"expires_at":2,"country":null,"current":true}}
        """#.utf8))
        #expect(exchange.key == "0f0e6c1a-6a0b-4c8e-9d1e-2b3c4d5e6f70")
        #expect(exchange.session?.id == "s9" && exchange.session?.current == true)
    }

    @Test func errorsMapToAccountError() {
        #expect(AccountError.from(CobaltError.api(code: "error.api.auth.code.invalid", httpStatus: 400)) == .codeInvalid)
        #expect(AccountError.from(CobaltError.api(code: "error.api.auth.session.not_found", httpStatus: 404)) == .notFound)
        #expect(AccountError.from(CobaltError.network(.notConnectedToInternet)) == .offline)
        #expect(AccountError.from(AccountError.cancelled) == .cancelled)
        #expect(AccountError.from(CobaltError.invalidResponse(httpStatus: 500)) == .failed)
    }
}

struct AccountClientTests {
    private let stored = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

    private func client(_ server: LoopbackServer, key: String? = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21") -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { key })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func exchangeIsAnOpenPostWithTheOldKeyInTheBody() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","key":"0f0e6c1a-6a0b-4c8e-9d1e-2b3c4d5e6f70","session":{"id":"s9","device":"iphone","platform":"ios","created_at":1,"current":true}}"#)
        }
        defer { server.stop() }
        let answer = try await client(server).exchangeSignIn(code: "the-code", verifier: "the-verifier", oldKey: stored)
        _ = try await client(server, key: nil).exchangeSignIn(code: "c2", verifier: "v2", oldKey: nil)
        #expect(answer.key == "0f0e6c1a-6a0b-4c8e-9d1e-2b3c4d5e6f70")
        let first = server.requests[0]
        #expect(first.method == "POST" && first.path == "/auth/exchange")
        #expect(first.headers["authorization"] == nil)
        let body = try bodyJSON(first)
        #expect(body["code"] as? String == "the-code" && body["verifier"] as? String == "the-verifier")
        #expect(body["old_key"] as? String == stored)
        #expect(try bodyJSON(server.requests[1])["old_key"] == nil)
    }

    @Test func aSpentCodeIsCodeInvalid() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.api.auth.code.invalid"}}"#, status: 400)
        }
        defer { server.stop() }
        await #expect(throws: AccountError.codeInvalid) {
            try await client(server).exchangeSignIn(code: "c", verifier: "v", oldKey: nil)
        }
    }

    @Test func keyedRoutesSendTheTokenAndDecode() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("GET", "/auth/me"): return .json(#"{"caller":{"kind":"session","id":"s1","email":"o@x.test"},"sessions":2,"keys":1}"#)
            case ("GET", "/auth/sessions"): return .json(#"{"sessions":[{"id":"s1","device":"a","platform":"ios","created_at":1,"current":true}]}"#)
            case ("GET", "/auth/keys"): return .json(#"{"keys":[{"id":"k1","name":"n","prefix":"abcdefgh","created_at":1,"old_paste":true}]}"#)
            case ("POST", "/auth/signout"): return .json(#"{"signed_out":true}"#)
            case ("POST", "/auth/signout-others"): return .json(#"{"count":3}"#)
            case ("DELETE", "/auth/sessions/s2"), ("DELETE", "/auth/keys/k1"): return .json(#"{"status":"success"}"#)
            default: return .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 500)
            }
        }
        defer { server.stop() }
        let c = client(server)
        #expect(try await c.accountMe().caller.email == "o@x.test")
        #expect(try await c.accountSessions().map(\.id) == ["s1"])
        #expect(try await c.accountKeys().first?.oldPaste == true)
        #expect(try await c.signOutSession())
        #expect(try await c.signOutOtherSessions() == 3)
        try await c.deleteAccountSession(id: "s2")
        try await c.deleteAccountKey(id: "k1")
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key \(stored)" })
    }

    @Test func refusalsAreMapped() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.path {
            case "/auth/sessions/gone": return .json(#"{"status":"error","error":{"code":"error.api.auth.session.not_found"}}"#, status: 404)
            case "/auth/keys/gone": return .json(#"{"status":"error","error":{"code":"error.api.auth.key.not_found"}}"#, status: 404)
            case "/auth/keys/nocode": return .json("{}", status: 404)
            case "/auth/sessions": return .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
            default: return .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: AccountError.notFound) { try await c.deleteAccountSession(id: "gone") }
        await #expect(throws: AccountError.notFound) { try await c.deleteAccountKey(id: "gone") }
        await #expect(throws: AccountError.notFound) { try await c.deleteAccountKey(id: "nocode") }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) { try await c.accountSessions() }
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 503)) { try await c.accountKeys() }
    }

    @Test func noTokenThrowsBeforeAnyRequest() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}") }
        defer { server.stop() }
        await #expect(throws: CobaltError.noAPIKey) { try await client(server, key: nil).accountSessions() }
        #expect(server.requests.isEmpty)
    }
}

@MainActor
struct AccountAppTests {
    private let pasted = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

    private func app(_ scenario: PreviewScenario) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    private func preview(_ app: AppModel) throws -> PreviewClient { try #require(app.ctx.client as? PreviewClient) }

    @Test func firstLaunchShowsSignInUntilItWorks() async throws {
        let app = app(.firstLaunch)
        #expect(app.needsFirstSignIn && !app.signInPinned && !app.offersMoveOver)
        try await app.signIn(using: PreviewWebSignIn(seconds: 0))
        #expect(!app.needsFirstSignIn && !app.signInPinned)
        #expect(app.settings.hasAPIKey && app.settings.hasSignedIn && app.settings.keyIsSession)
        #expect(app.capabilities.key == .valid)
        #expect(try preview(app).accountState.lastOldKey == nil)
        // the sheet opened the Access page with a PKCE challenge
        let opened = try #require(PreviewWebSignIn.log.withLock { $0.last })
        #expect(opened.host() == "cobalt.capybaraharmony.com" && opened.path() == "/api/auth/app")
        #expect(opened.query()?.contains("challenge=") == true)
    }

    @Test func aClosedOrBrokenSheetChangesNothing() async throws {
        let app = app(.firstLaunch)
        await #expect(throws: AccountError.cancelled) { try await app.signIn(using: PreviewWebSignIn(outcome: .cancelled, seconds: 0)) }
        await #expect(throws: AccountError.badCallback) { try await app.signIn(using: PreviewWebSignIn(outcome: .broken, seconds: 0)) }
        #expect(app.needsFirstSignIn && !app.settings.hasAPIKey && !app.account.signingIn)
    }

    @Test func moveOverSendsThePastedKeyAndReplacesIt() async throws {
        let app = app(.moveOver)
        #expect(app.offersMoveOver && !app.needsFirstSignIn && !app.signInPinned)
        #expect(app.settings.apiKey() == pasted && !app.settings.keyIsSession)
        try await app.signIn(using: PreviewWebSignIn(seconds: 0))
        #expect(try preview(app).accountState.lastOldKey == pasted)
        #expect(app.settings.apiKey() != pasted && app.settings.keyIsSession)
        #expect(!app.offersMoveOver && app.settings.hasSignedIn && app.settings.moveOverAsked)
    }

    @Test func signedOutKeepsTheScreenAndSigningInClearsThePin() async throws {
        let app = app(.signedOut)
        app.selectedTab = .library
        #expect(app.signInPinned && !app.needsFirstSignIn)
        try await app.signIn(using: PreviewWebSignIn(seconds: 0))
        #expect(!app.signInPinned)
        #expect(app.selectedTab == .library)
        // a session token is never sent back as an old key
        try await app.signIn(using: PreviewWebSignIn(seconds: 0))
        #expect(try preview(app).accountState.lastOldKey == nil)
    }

    @Test func signingOutPinsSignInAgain() async throws {
        let app = app(.happy)
        await app.refreshServer()
        #expect(!app.signInPinned && app.capabilities.accounts)
        await app.signOut()
        #expect(!app.settings.hasAPIKey && app.signInPinned && !app.needsFirstSignIn)
        #expect(app.account.sessions.isEmpty)
    }

    @Test func aServerWithoutAccountsKeepsTheOldFlow() async {
        let app = app(.renditions)
        #expect(!app.capabilities.accounts)
        #expect(!app.needsFirstSignIn && !app.signInPinned && !app.offersMoveOver)
        let revoked = self.app(.revokedKey)
        #expect(!revoked.signInPinned)
    }

    @Test func theStoreListsDevicesAndKeysAndChangesThem() async throws {
        let app = app(.happy)
        let store = app.account
        await store.refresh()
        #expect(store.phase == .ready)
        #expect(store.sessions.count == 5 && store.sessions.first?.current == true)
        #expect(store.keys.count == 4 && store.oldPasteCount == 2)
        #expect(store.email == PreviewData.accountEmail)

        let other = try #require(store.otherSessions.first)
        try await store.signOut(other)
        #expect(store.sessions.count == 4 && !store.sessions.contains { $0.id == other.id })

        try await store.revoke(store.keys[2])
        #expect(store.keys.count == 3 && store.oldPasteCount == 1)

        #expect(try await store.signOutOthers() == 3)
        #expect(store.sessions.count == 1 && store.otherSessions.isEmpty)
    }

    @Test func aRefusedTokenFromTheStoreSignsTheAppOut() async {
        let app = app(.signedOut)
        await app.account.refresh()
        #expect(app.account.phase == .failed)
        #expect(app.capabilities.key == .invalid && app.signInPinned)
    }

    @Test func theCallbackLinkNeverMovesTheScreen() {
        let app = app(.happy)
        app.selectedTab = .library
        app.open(URL(string: "cobalt-apple://signed-in?code=abc")!)
        #expect(app.selectedTab == .library)
    }
}
