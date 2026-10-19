import Foundation

// Stage, the studio tab (APP-API-CONTRACT 30.10; `features.stage`; keyed). Its own file so `HTTPCobaltClient.swift` only
// grows the capability flags. Every route is keyed, answers `cache-control: no-store`, and refuses with `StageError`.

extension HTTPCobaltClient {
    /// `GET /stage` (keyed): the stage and its four rewards.
    public func stage() async throws -> StageSnapshot {
        let req = try makeRequest("GET", "/stage", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try stageAnswer(StageSnapshot.self, data, http)
    }

    /// `PATCH /stage` (keyed): only the patch's fields are sent, numbers clamped.
    public func updateStage(_ patch: StagePatch) async throws -> StageSettings {
        let req = try makeRequest("PATCH", "/stage", keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(patch.body()))
        return try stageSettingsAnswer(data, http)
    }

    /// `POST /stage/rotate` (keyed, no body).
    public func rotateStage() async throws -> StageSettings {
        let req = try makeRequest("POST", "/stage/rotate", keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        return try stageSettingsAnswer(data, http)
    }

    /// `POST /stage/action` `{type, item_id?}` (keyed).
    public func stageAction(_ action: StageAction) async throws -> StageSettings {
        let req = try makeRequest("POST", "/stage/action", keyed: true, timeout: 30)
        var body: [String: Any] = ["type": action.type]
        if let id = action.itemID { body["item_id"] = id }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try stageSettingsAnswer(data, http)
    }

    /// `GET /stage/pool?offset=&limit=` (keyed): `limit` is held to 1...100.
    public func stagePool(offset: Int, limit: Int) async throws -> StagePoolPage {
        let query = [("offset", String(max(0, offset))), ("limit", String(min(100, max(1, limit))))]
        let req = try makeRequest("GET", "/stage/pool", query: query, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try stageAnswer(StagePoolPage.self, data, http)
    }

    /// `GET /stage/redemptions?limit=&before=` (keyed): newest first; `before` is ms since the epoch.
    public func stageRedemptions(limit: Int, before: Date?) async throws -> [StageRedemption] {
        var query = [("limit", String(min(100, max(1, limit))))]
        if let before { query.append(("before", String(Int((before.timeIntervalSince1970 * 1000).rounded())))) }
        let req = try makeRequest("GET", "/stage/redemptions", query: query, keyed: true, timeout: 15)
        let (data, http) = try await send(req)
        struct Wire: Decodable { var redemptions: [Lossy<StageRedemption>] }
        let wire = try stageAnswer(Wire.self, data, http)
        return wire.redemptions.compactMap(\.value)
    }

    /// `PATCH /stage/rewards/<action>` `{cost?, cooldown_seconds?, enabled?}` (keyed): only what is given is sent, numbers
    /// clamped.
    public func updateStageReward(_ kind: StageRewardKind, cost: Int?, cooldownSeconds: Int?, enabled: Bool?) async throws -> StageReward {
        let req = try makeRequest("PATCH", "/stage/rewards/\(Self.encode(kind.rawValue))", keyed: true, timeout: 30)
        var body: [String: Any] = [:]
        if let cost { body["cost"] = StageRule.clamp(cost, to: StageRule.costRange) }
        if let cooldownSeconds { body["cooldown_seconds"] = StageRule.clamp(cooldownSeconds, to: StageRule.cooldownRange) }
        if let enabled { body["enabled"] = enabled }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        struct Wire: Decodable { var reward: StageReward }
        return try stageAnswer(Wire.self, data, http).reward
    }

    /// `POST /stage/twitch/connect` (keyed, no body): the authorize URL.
    public func connectStageTwitch() async throws -> URL {
        let req = try makeRequest("POST", "/stage/twitch/connect", keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        struct Wire: Decodable { var authorizeUrl: URL }
        return try stageAnswer(Wire.self, data, http).authorizeUrl
    }

    /// `DELETE /stage/twitch` (keyed).
    public func disconnectStageTwitch() async throws -> StageSettings {
        let req = try makeRequest("DELETE", "/stage/twitch", keyed: true, timeout: 45)
        let (data, http) = try await send(req)
        return try stageSettingsAnswer(data, http)
    }

    // MARK: answers

    /// A 2xx whose body decodes as `T`; a refusal as `StageError`; an unreadable answer as `.invalidResponse`.
    private func stageAnswer<T: Decodable>(_ type: T.Type, _ data: Data, _ http: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(http.statusCode) else { throw stageError(data, status: http.statusCode) }
        guard let wire = try? CobaltJSON.decoder().decode(T.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire
    }

    /// `{status, stage}`: the stage as it is now.
    private func stageSettingsAnswer(_ data: Data, _ http: HTTPURLResponse) throws -> StageSettings {
        struct Wire: Decodable { var stage: StageSettings }
        return try stageAnswer(Wire.self, data, http).stage
    }

    /// The stage routes' refusals as `StageError`; any other code stays the generic `CobaltError.api`.
    private func stageError(_ data: Data, status: Int) -> Error {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
        }
        let body = try? CobaltJSON.decoder().decode(Body.self, from: data)
        if let code = body?.error?.code, let known = StageError(code: code) { return known }
        if status == 503 { return StageError.unavailable }
        return apiError(data, status: status)
    }
}
