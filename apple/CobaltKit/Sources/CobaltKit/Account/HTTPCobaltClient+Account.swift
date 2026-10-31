import Foundation

// Accounts (APP-API-CONTRACT 42.5) on the real client. Built with the literal paths (not generated endpoint helpers), so it
// compiles before `Endpoints.swift` is regenerated; the routes move to the generated ones like the other calls.
extension HTTPCobaltClient {
    /// `POST /auth/exchange` (open: the stored key never rides in the header; a pasted one goes in the body as `old_key`).
    public func exchangeSignIn(code: String, verifier: String, oldKey: String?) async throws -> AuthExchange {
        let req = try makeRequest("POST", "/auth/exchange", keyed: false, timeout: 30)
        var body: [String: Any] = ["code": code, "verifier": verifier]
        if let oldKey, !oldKey.isEmpty { body["old_key"] = oldKey }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: false) }
        guard let answer = try? AuthExchange.decode(data), !answer.key.isEmpty else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return answer
    }

    /// `GET /auth/me`.
    public func accountMe() async throws -> AccountMe {
        let (data, http) = try await send(makeRequest("GET", "/auth/me", keyed: true, timeout: 20))
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: false) }
        do { return try AccountMe.decode(data) } catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `GET /auth/sessions`.
    public func accountSessions() async throws -> [AccountSession] {
        let (data, http) = try await send(makeRequest("GET", "/auth/sessions", keyed: true, timeout: 20))
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: false) }
        do { return try AccountSession.decodeList(data) } catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `DELETE /auth/sessions/<id>` → `{status}`; unknown or already revoked is `AccountError.notFound`.
    public func deleteAccountSession(id: String) async throws {
        let req = try makeRequest("DELETE", "/auth/sessions/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: true) }
    }

    /// `POST /auth/signout` → `{signed_out}`.
    public func signOutSession() async throws -> Bool {
        let (data, http) = try await send(makeRequest("POST", "/auth/signout", keyed: true, timeout: 20))
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: false) }
        struct Wire: Decodable { var signedOut: Bool? }
        return (try? CobaltJSON.decoder().decode(Wire.self, from: data))?.signedOut ?? false
    }

    /// `POST /auth/signout-others` → `{count}`.
    public func signOutOtherSessions() async throws -> Int {
        let (data, http) = try await send(makeRequest("POST", "/auth/signout-others", keyed: true, timeout: 20))
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: false) }
        struct Wire: Decodable { var count: Int? }
        return (try? CobaltJSON.decoder().decode(Wire.self, from: data))?.count ?? 0
    }

    /// `GET /auth/keys`.
    public func accountKeys() async throws -> [AccountKey] {
        let (data, http) = try await send(makeRequest("GET", "/auth/keys", keyed: true, timeout: 20))
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: false) }
        do { return try AccountKey.decodeList(data) } catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `DELETE /auth/keys/<id>` → `{status}`; anything but a live key is `AccountError.notFound`.
    public func deleteAccountKey(id: String) async throws {
        let req = try makeRequest("DELETE", "/auth/keys/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw accountError(data, status: http.statusCode, deleting: true) }
    }

    /// The accounts routes' refusals as `AccountError`; anything else (a revoked token, a 5xx) stays `CobaltError`.
    func accountError(_ data: Data, status: Int, deleting: Bool) -> Error {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
        }
        let code = (try? JSONDecoder().decode(Body.self, from: data))?.error?.code
        switch code {
        case "error.api.auth.code.invalid": return AccountError.codeInvalid
        case "error.api.auth.session.not_found": return AccountError.notFound
        // `DELETE /auth/keys/<id>` for an unknown key; on any other route this code is the caller's own key being unknown
        case "error.api.auth.key.not_found" where deleting: return AccountError.notFound
        case let code? where code.hasPrefix("error.api.auth."): return apiError(data, status: status)
        default:
            if deleting && status == 404 { return AccountError.notFound }
            return apiError(data, status: status)
        }
    }
}

// The defaults for clients that predate accounts (fakes in tests): the server cannot.
extension CobaltClient {
    public func exchangeSignIn(code: String, verifier: String, oldKey: String?) async throws -> AuthExchange {
        throw PipelineFailure.unsupported
    }
    public func accountMe() async throws -> AccountMe { throw PipelineFailure.unsupported }
    public func accountSessions() async throws -> [AccountSession] { throw PipelineFailure.unsupported }
    public func deleteAccountSession(id: String) async throws { throw PipelineFailure.unsupported }
    public func signOutSession() async throws -> Bool { throw PipelineFailure.unsupported }
    public func signOutOtherSessions() async throws -> Int { throw PipelineFailure.unsupported }
    public func accountKeys() async throws -> [AccountKey] { throw PipelineFailure.unsupported }
    public func deleteAccountKey(id: String) async throws { throw PipelineFailure.unsupported }
}
