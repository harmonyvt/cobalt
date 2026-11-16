import Foundation

// Swarms (APP-API-CONTRACT 59.6, 61.3, 61.4). Every route is keyed with the device's normal auth (its session, sent exactly
// like any other call), answers `cache-control: no-store`, and refuses with `SwarmError`. The answers are read with
// `SwarmWire.decoder()` (see SwarmModels.swift for why not `CobaltJSON`).

extension HTTPCobaltClient {
    /// `GET /swarms` (keyed): `{ swarms }`, newest first. An odd row is dropped, not the list.
    public func swarms() async throws -> [Swarm] {
        let req = try makeRequest("GET", "/swarms", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try swarmAnswer(SwarmListWire.self, data, http).swarms
    }

    /// `GET /swarms/<id>` (keyed).
    public func swarm(id: String) async throws -> Swarm {
        let req = try makeRequest("GET", "/swarms/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try swarmAnswer(Swarm.self, data, http)
    }

    /// `GET /swarms/<id>/agents/<n>` (keyed): n from 1.
    public func swarmAgent(id: String, agent: Int) async throws -> SwarmAgent {
        let req = try makeRequest("GET", "/swarms/\(Self.encode(id))/agents/\(max(1, agent))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try swarmAnswer(SwarmAgent.self, data, http)
    }

    /// `GET /swarms/<id>/changes?offset=&limit=` (keyed): `limit` is held to 1...200.
    public func swarmChanges(id: String, offset: Int, limit: Int) async throws -> SwarmChangePage {
        let query = [("offset", String(max(0, offset))), ("limit", String(min(200, max(1, limit))))]
        let req = try makeRequest("GET", "/swarms/\(Self.encode(id))/changes", query: query, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try swarmAnswer(SwarmChangePage.self, data, http)
    }

    /// `GET /swarms/<id>/messages` (keyed), `?agent=` when given.
    public func swarmMessages(id: String, agent: Int?) async throws -> [SwarmMessage] {
        let query = agent.map { [("agent", String($0))] } ?? []
        let req = try makeRequest("GET", "/swarms/\(Self.encode(id))/messages", query: query, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try swarmAnswer(SwarmMessagesWire.self, data, http).messages
    }

    /// `POST /swarms/<id>/approve` `{spec_hash}` (keyed; this device's session).
    public func approveSwarm(id: String, hash: String) async throws -> Swarm {
        try await swarmPost(id, "approve", body: ["spec_hash": hash])
    }

    /// `POST /swarms/<id>/decline` (keyed, no body).
    public func declineSwarm(id: String) async throws -> Swarm {
        try await swarmPost(id, "decline", body: nil)
    }

    /// `POST /swarms/<id>/stop` (keyed, no body).
    public func stopSwarm(id: String) async throws -> Swarm {
        try await swarmPost(id, "stop", body: nil)
    }

    /// `POST /swarms/<id>/retry` (keyed, no body).
    public func retrySwarm(id: String) async throws -> Swarm {
        try await swarmPost(id, "retry", body: nil)
    }

    /// `POST /swarms/<id>/changes` `{changes: [{n, keep?, after?}]}` (keyed): 1...500 at a time.
    public func decideSwarm(id: String, changes: [SwarmDecision]) async throws -> SwarmDecided {
        guard !changes.isEmpty else { throw SwarmError.badRequest }
        let req = try makeRequest("POST", "/swarms/\(Self.encode(id))/changes", keyed: true, timeout: 30)
        let body = Self.jsonBody(["changes": changes.prefix(500).map(\.wire)])
        let (data, http) = try await send(req, body: body)
        return try swarmAnswer(SwarmDecided.self, data, http)
    }

    /// `POST /swarms/<id>/apply` `{spec_hash, skip_clashes?, count?}` (keyed). `skip_clashes` is sent only when true, `count`
    /// only when given.
    public func applySwarm(id: String, hash: String, skipClashes: Bool, count: Int?) async throws -> Swarm {
        try await swarmPost(id, "apply", body: Self.applyBody(hash: hash, skipClashes: skipClashes, count: count))
    }

    /// The apply request's JSON object (split out so a test can read exactly what is sent).
    static func applyBody(hash: String, skipClashes: Bool, count: Int?) -> [String: Any] {
        var body: [String: Any] = ["spec_hash": hash]
        if skipClashes { body["skip_clashes"] = true }
        if let count { body["count"] = max(0, count) }
        return body
    }

    /// `POST /swarms/<id>/messages` `{to, text}` (keyed): `to` is an agent number or "all".
    public func sendSwarm(id: String, to: SwarmRecipient, text: String) async throws -> SwarmSent {
        let req = try makeRequest("POST", "/swarms/\(Self.encode(id))/messages", keyed: true, timeout: 20)
        let (data, http) = try await send(req, body: Self.jsonBody(["to": to.wire, "text": text]))
        return try swarmAnswer(SwarmSent.self, data, http)
    }

    /// `GET /swarms/<id>/board` (keyed): `q`, `agent`, `status`, `group` and `sort` only when given; `limit` held to 1...200.
    /// The rows' fields keep the order the server wrote them (`SwarmBoard.decode`).
    public func swarmBoard(
        id: String, query: String?, agent: Int?, status: String?, group: String?, sort: BoardSort, offset: Int, limit: Int
    ) async throws -> SwarmBoard {
        var q: [(String, String)] = []
        if let query, !query.isEmpty { q.append(("q", query)) }
        if let agent { q.append(("agent", String(agent))) }
        if let status, !status.isEmpty { q.append(("status", status)) }
        if let group, !group.isEmpty { q.append(("group", group)) }
        q.append(("sort", sort.rawValue))
        q.append(("offset", String(max(0, offset))))
        q.append(("limit", String(min(200, max(1, limit)))))
        let req = try makeRequest("GET", "/swarms/\(Self.encode(id))/board", query: q, keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw swarmRefusal(data, status: http.statusCode) }
        guard let board = try? SwarmBoard.decode(data) else { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
        return board
    }

    // MARK: answers

    private func swarmPost(_ id: String, _ action: String, body: [String: Any]?) async throws -> Swarm {
        let req = try makeRequest("POST", "/swarms/\(Self.encode(id))/\(action)", keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: body.flatMap { Self.jsonBody($0) })
        return try swarmAnswer(Swarm.self, data, http)
    }

    /// A 2xx whose body decodes as `T`; a refusal as `SwarmError` (any other code stays the generic `CobaltError.api`); an
    /// unreadable answer as `.invalidResponse`.
    private func swarmAnswer<T: Decodable>(_ type: T.Type, _ data: Data, _ http: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(http.statusCode) else { throw swarmRefusal(data, status: http.statusCode) }
        guard let wire = try? SwarmWire.decoder().decode(T.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire
    }

    private func swarmRefusal(_ data: Data, status: Int) -> Error {
        let error = apiError(data, status: status)
        if case .api(let code, _) = error, let known = SwarmError(code: code) { return known }
        return error
    }
}
