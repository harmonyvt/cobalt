import Foundation

// 7TV accounts (APP-API-CONTRACT 57.4; keyed, no-store). Its own file so `HTTPCobaltClient.swift` stays as it is. Every route
// answers `{status: "success", …}` or `{status: "error", error: {code}, message?}`; refusals are `SevenTvError` with 7TV's
// message where the server passed one on.

extension HTTPCobaltClient: SevenTvClient {
    public func sevenTvStatus() async throws -> SevenTvStatus {
        let req = try makeRequest("GET", SevenTvRoute.status, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvStatus.self, data, http)
    }

    public func linkSevenTv(token: String) async throws -> SevenTvStatus {
        let req = try makeRequest("POST", SevenTvRoute.link, keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(["token": token]))
        return try sevenTvAnswer(SevenTvStatus.self, data, http)
    }

    public func unlinkSevenTv() async throws -> SevenTvStatus {
        let req = try makeRequest("DELETE", SevenTvRoute.status, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvStatus.self, data, http)
    }

    public func sevenTvSets(channelID: String) async throws -> SevenTvChannelSets {
        let req = try makeRequest("GET", SevenTvRoute.channelSets(channelID), keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvChannelSets.self, data, http)
    }

    public func sevenTvSet(id: String, query: String?, page: Int) async throws -> SevenTvSetPage {
        let req = try makeRequest(
            "GET", SevenTvRoute.set(id), query: SevenTvRoute.setQuery(query: query, page: page), keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvSetPage.self, data, http)
    }

    public func createSevenTvSet(ownerID: String, name: String) async throws -> SevenTvSetInfo {
        let req = try makeRequest("POST", SevenTvRoute.sets, keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(["owner_id": ownerID, "name": name]))
        return try sevenTvAnswer(SetWire.self, data, http).set
    }

    public func renameSevenTvSet(id: String, name: String) async throws -> SevenTvSetInfo {
        let req = try makeRequest("PATCH", SevenTvRoute.set(id), keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(["name": name]))
        return try sevenTvAnswer(SetWire.self, data, http).set
    }

    public func addSevenTvEmote(setID: String, emoteID: String, alias: String?, overrideConflicts: Bool) async throws -> SevenTvEmoteChange {
        let req = try makeRequest("POST", SevenTvRoute.emotes(setID), keyed: true, timeout: 30)
        let body = SevenTvRoute.addBody(emoteID: emoteID, alias: alias, overrideConflicts: overrideConflicts)
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try sevenTvAnswer(SevenTvEmoteChange.self, data, http)
    }

    public func renameSevenTvEmote(setID: String, emoteID: String, alias: String, from: String?) async throws -> SevenTvEmoteChange {
        let req = try makeRequest("PATCH", SevenTvRoute.emote(setID, emoteID), keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(SevenTvRoute.renameBody(alias: alias, from: from)))
        return try sevenTvAnswer(SevenTvEmoteChange.self, data, http)
    }

    public func removeSevenTvEmote(setID: String, emoteID: String, alias: String?) async throws -> SevenTvEmoteChange {
        var query: [(String, String)] = []
        if let alias, !alias.isEmpty { query.append(("alias", alias)) }
        let req = try makeRequest("DELETE", SevenTvRoute.emote(setID, emoteID), query: query, keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvEmoteChange.self, data, http)
    }

    public func makeSevenTvSetLive(channelID: String, setID: String?) async throws -> SevenTvLiveChange {
        let req = try makeRequest("POST", SevenTvRoute.channelLive(channelID), keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(SevenTvRoute.liveBody(setID: setID)))
        return try sevenTvAnswer(SevenTvLiveChange.self, data, http)
    }

    public func uploadSevenTvEmote(_ draft: SevenTvUploadDraft) async throws -> SevenTvUploadResult {
        // The Worker reads the file from R2, may fit it in the container first (57.10: up to 150 s), then sends it to 7TV.
        let req = try makeRequest("POST", SevenTvRoute.uploads, keyed: true, timeout: 240)
        let (data, http) = try await send(req, body: Self.jsonBody(SevenTvRoute.uploadBody(draft)))
        return try sevenTvAnswer(SevenTvUploadResult.self, data, http)
    }

    public func sevenTvEmote(id: String) async throws -> SevenTvEmoteInfo {
        let req = try makeRequest("GET", SevenTvRoute.emoteInfo(id), keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvEmoteInfo.self, data, http)
    }

    // MARK: answers

    private struct SetWire: Decodable { var set: SevenTvSetInfo }

    /// A 2xx whose body decodes as `T`; a refusal as `SevenTvError`; an unreadable answer as `.invalidResponse`.
    private func sevenTvAnswer<T: Decodable>(_ type: T.Type, _ data: Data, _ http: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(http.statusCode) else { throw sevenTvError(data, status: http.statusCode) }
        guard let wire = try? CobaltJSON.decoder().decode(T.self, from: data) else {
            if let known = SevenTvRefusal.parse(data) { throw known }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire
    }

    /// The routes' refusals as `SevenTvError`; any other code stays the generic `CobaltError.api` (an ended key still
    /// reaches `AuthSignal` through `apiError`).
    private func sevenTvError(_ data: Data, status: Int) -> Error {
        if let known = SevenTvRefusal.parse(data) { return known }
        if status == 502 { return SevenTvError.unavailable }
        return apiError(data, status: status)
    }
}

/// The refusal body: `{status: "error", error: {code, message?}, message?}`.
enum SevenTvRefusal {
    private struct Body: Decodable {
        struct Err: Decodable {
            var code: String?
            var message: String?
        }
        var error: Err?
        var message: String?
    }

    static func parse(_ data: Data) -> SevenTvError? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data), let code = body.error?.code else { return nil }
        return SevenTvError(code: code, message: body.message ?? body.error?.message)
    }
}
