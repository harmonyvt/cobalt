import Foundation

// Hidden posts and auto-hide rules (APP-API-CONTRACT 37) on the real client, keyed. The requests come from the generated
// endpoints (method, path, key); the replies are decoded by the wire types in `Models/Hidden.swift`, because the
// generated ones have no `counts.hidden` and read the rule's kind as a bare string. The server's refusals
// (`error.hidden.bad_rule`, `error.hidden.too_many`, `error.hidden.not_found`, `error.library.bad_request`) stay
// `CobaltError.api(code:httpStatus:)`, so a screen can word them.

/// `GET /library`, as the app reads it: the posts, the library's counts without the hidden ones, `counts.hidden`.
struct LibraryPageWire: Decodable {
    struct Counts: Decodable { var posts: Int?; var files: Int?; var hidden: Int? }
    struct Usage: Decodable { var publicBytes: Int?; var privateBytes: Int? }
    var posts: [Lossy<LibraryPost>]
    var counts: Counts?
    var usage: Usage?
    var next: String?

    var page: LibraryPage {
        let list = posts.compactMap(\.value)
        return LibraryPage(
            posts: list, postCount: counts?.posts ?? list.count,
            fileCount: counts?.files ?? list.reduce(0) { $0 + $1.files.count },
            publicBytes: Int64(usage?.publicBytes ?? 0), privateBytes: Int64(usage?.privateBytes ?? 0),
            next: next, hiddenCount: max(0, counts?.hidden ?? 0))
    }
}

extension HTTPCobaltClient {
    /// The endpoint's reply decoded as `T` (not as the endpoint's generated type). Errors as `send(_ endpoint:)` throws them.
    func send<R: Decodable & Sendable, T: Decodable>(
        _ endpoint: APIEndpoint<R>, as type: T.Type, query: [(String, String)] = [], body: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let req = try makeRequest(endpoint, query: query, timeout: timeout)
        let (data, http) = try await send(req, body: body.flatMap(Self.jsonBody))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(T.self, from: data) }
        catch {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }

    /// One page of `GET /library` (`hidden`: `?hidden=1`, only the hidden posts).
    func libraryPage(cursor: String?, limit: Int, version: Int?, hidden: Bool) async throws -> LibraryPage {
        var query = [("limit", String(max(1, min(50, limit))))]
        if let cursor { query.append(("cursor", cursor)) }
        if let version { query.append(("v", String(version))) }
        if hidden { query.append(("hidden", "1")) }
        return try await send(Endpoints.libraryIndex(), as: LibraryPageWire.self, query: query).page
    }

    /// `GET /library?hidden=1&v=3`: the hidden album's pages. `v=3` always: a server that hides posts (0025) came after
    /// the galleries, and the album then lists a hidden gallery's items like the library lists any.
    public func hiddenLibrary(cursor: String?, limit: Int) async throws -> LibraryPage {
        try await libraryPage(cursor: cursor, limit: limit, version: 3, hidden: true)
    }

    /// `POST /library/status {ids, status}`: 200 with `posts` and `failed`; `400 error.library.bad_request` for a bad body.
    public func setStatus(ids: [String], status: PostStatus) async throws -> StatusChange {
        let wire = try await send(
            Endpoints.libraryStatusRoute(), as: HiddenWire.Status.self,
            body: ["ids": ids, "status": status.rawValue], timeout: 120)
        return wire.value
    }

    public func hiddenRules() async throws -> HiddenRules {
        try await send(Endpoints.hiddenRulesList(), as: HiddenWire.List.self, timeout: 20).value
    }

    /// `POST /hidden/rules {kind, value, apply?}` → 201 `{rule, applied}`.
    public func createHiddenRule(kind: HiddenRuleKind, value: String, apply: Bool) async throws -> (rule: HideRule, applied: Int) {
        var body: [String: Any] = ["kind": kind.rawValue, "value": value]
        if apply { body["apply"] = true }
        return try Self.saved(await send(Endpoints.hiddenRulesCreate(), as: HiddenWire.Saved.self, body: body, timeout: 120))
    }

    /// `POST /hidden/rules/preview {kind, value}` → `{matches, sample}`.
    public func previewHiddenRule(kind: HiddenRuleKind, value: String) async throws -> HiddenRulePreview {
        let wire = try await send(
            Endpoints.hiddenRulesPreview(), as: HiddenWire.Preview.self,
            body: ["kind": kind.rawValue, "value": value], timeout: 30)
        return HiddenRulePreview(matches: wire.matches, sample: wire.sample ?? [])
    }

    /// `PATCH /hidden/rules/<id> {enabled?, value?, apply?}`; `404 error.hidden.not_found`, `400 error.hidden.bad_rule`.
    public func updateHiddenRule(id: String, enabled: Bool?, value: String?, apply: Bool) async throws -> (rule: HideRule, applied: Int) {
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let value { body["value"] = value }
        if apply { body["apply"] = true }
        return try Self.saved(await send(Endpoints.hiddenRulesUpdate(id: id), as: HiddenWire.Saved.self, body: body, timeout: 120))
    }

    /// `DELETE /hidden/rules/<id>`; `404 error.hidden.not_found`.
    public func deleteHiddenRule(id: String) async throws {
        _ = try await send(Endpoints.hiddenRulesDelete(id: id), timeout: 20)
    }

    private static func saved(_ wire: HiddenWire.Saved) throws -> (rule: HideRule, applied: Int) {
        guard let rule = wire.rule.rule else { throw CobaltError.invalidResponse(httpStatus: 200) }
        return (rule, wire.applied ?? 0)
    }
}
