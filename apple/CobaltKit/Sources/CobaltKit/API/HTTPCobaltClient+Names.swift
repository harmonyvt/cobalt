import Foundation

// Search names (APP-API-CONTRACT 48.4) on the real client, keyed. Built with the literal paths (not generated endpoint
// helpers), so this compiles whether or not `Generated/Endpoints.swift` has the names ops yet. The replies are decoded by
// the wire types in `Models/SearchNames.swift`. The server's refusals stay `CobaltError.api(code:httpStatus:)`, except
// `409 error.names.taken`, which is `SearchNameTaken` with the clashing word.

extension HTTPCobaltClient {
    /// One names request: the body as JSON, the answer decoded as `T`; a refusal thrown as above.
    private func namesCall<T: Decodable>(
        _ method: String, _ path: String, query: [(String, String)] = [], body: [String: Any]? = nil, as type: T.Type,
        timeout: TimeInterval = 20
    ) async throws -> T {
        let req = try makeRequest(method, path, query: query, keyed: true, timeout: timeout)
        let (data, http) = try await send(req, body: body.flatMap(Self.jsonBody))
        guard (200..<300).contains(http.statusCode) else { throw namesRefusal(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(T.self, from: data) }
        catch {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }

    /// `error.names.taken` carries the word; everything else is the keyed calls' error.
    private func namesRefusal(_ data: Data, status: Int) -> Error {
        if status == 409, let refusal = try? CobaltJSON.decoder().decode(NamesWire.Refusal.self, from: data),
           refusal.error?.code == "error.names.taken" {
            return SearchNameTaken(word: refusal.word ?? refusal.error?.word)
        }
        return apiError(data, status: status)
    }

    public func searchNames() async throws -> [TaughtName] {
        try await namesCall("GET", "/library/names", as: NamesWire.List.self).value
    }

    /// `POST /library/names` → 201 `{name}`.
    public func createSearchName(_ draft: SearchNameDraft) async throws -> TaughtName {
        try await namesCall("POST", "/library/names", body: draft.body, as: NamesWire.Saved.self, timeout: 30).name.value
    }

    /// `PATCH /library/names/<id>` → `{name}`.
    public func updateSearchName(id: String, _ patch: SearchNamePatch) async throws -> TaughtName {
        try await namesCall(
            "PATCH", "/library/names/\(Self.encode(id))", body: patch.body, as: NamesWire.Saved.self, timeout: 30).name.value
    }

    /// `DELETE /library/names/<id>` → `{status}` (the body is not read).
    public func deleteSearchName(id: String) async throws {
        let req = try makeRequest("DELETE", "/library/names/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw namesRefusal(data, status: http.statusCode) }
    }

    /// `POST /library/names/preview` → `{embedded, carries, indexed, posts}`.
    public func previewSearchName(_ request: SearchNamePreviewRequest) async throws -> SearchNamePreview {
        try await namesCall("POST", "/library/names/preview", body: request.body, as: NamesWire.Preview.self, timeout: 30).value
    }

    /// `GET /library/names/post?key=<post key>` → `{names}`.
    public func searchNames(forPost postKey: String) async throws -> [PostName] {
        try await namesCall("GET", "/library/names/post", query: [("key", postKey)], as: NamesWire.ForPost.self).value
    }
}
