import Foundation

// 7TV accounts (APP-API-CONTRACT 57.4; keyed, no-store). Its own file so `HTTPCobaltClient.swift` stays as it is. Every route
// answers `{status: "success", …}` or `{status: "error", error: {code}, message?}`; refusals are `SevenTvError` with 7TV's
// message where the server passed one on.

extension HTTPCobaltClient: SevenTvClient {
    public func sevenTvStatus() async throws -> SevenTvStatus {
        let req = try makeRequest("GET", SevenTvRoute.status, keyed: true, timeout: 20)
        let status = try await sevenTvRead(SevenTvStatus.self, req)
        // no account: nothing of the old one stays on the device
        if !status.linked { answers.clear() }
        return status
    }

    public func linkSevenTv(token: String) async throws -> SevenTvStatus {
        let req = try makeRequest("POST", SevenTvRoute.link, keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(["token": token]))
        let status = try sevenTvAnswer(SevenTvStatus.self, data, http)
        // another account may now stand behind the same routes: nothing of the old one is read back
        answers.clear()
        return status
    }

    public func unlinkSevenTv(logout: Bool) async throws -> SevenTvStatus {
        // the server calls 7TV's logout first when asked, so it gets a little longer
        let req = try makeRequest("DELETE", SevenTvRoute.status, query: SevenTvRoute.unlinkQuery(logout: logout), keyed: true, timeout: logout ? 30 : 20)
        let (data, http) = try await send(req)
        let status = try sevenTvAnswer(SevenTvStatus.self, data, http)
        // unlinked: the account's sets and emotes are not shown again offline (a refused unlink throws above and keeps them;
        // the store reads even a linked answer to a 2xx unlink as unlinked, so this does too)
        answers.clear()
        return status
    }

    public func sevenTvSets(channelID: String) async throws -> SevenTvChannelSets {
        let req = try makeRequest("GET", SevenTvRoute.channelSets(channelID), keyed: true, timeout: 20)
        return try await sevenTvRead(SevenTvChannelSets.self, req)
    }

    public func sevenTvSet(id: String, query: String?, page: Int) async throws -> SevenTvSetPage {
        let req = try makeRequest(
            "GET", SevenTvRoute.set(id), query: SevenTvRoute.setQuery(query: query, page: page), keyed: true, timeout: 20)
        let answer = try await sevenTvRead(SevenTvSetPage.self, req)
        await EmoteCache.shared.prefetch(answer.emotes.compactMap(\.previewURL))
        return answer
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

    public func sevenTvUploads() async throws -> [SevenTvUploadedEmote] {
        let req = try makeRequest("GET", SevenTvRoute.myUploads, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvUploadList.self, data, http).uploads
    }

    public func sevenTvOwned() async throws -> SevenTvOwnedList {
        let req = try makeRequest("GET", SevenTvRoute.owned, keyed: true, timeout: 20)
        let answer = try await sevenTvRead(SevenTvOwnedList.self, req)
        await EmoteCache.shared.prefetch(answer.emotes.compactMap(\.previewURL))
        return answer
    }

    public func sevenTvEmote(id: String) async throws -> SevenTvEmoteInfo {
        let req = try makeRequest("GET", SevenTvRoute.emoteInfo(id), keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        return try sevenTvAnswer(SevenTvEmoteInfo.self, data, http)
    }

    // MARK: answers

    private struct SetWire: Decodable { var set: SevenTvSetInfo }

    /// A read that is kept (`SevenTvAnswerCache`): a 2xx answer is saved, and when the network fails the last saved answer
    /// stands in for it (57.13), for this request only: the same URL signed with the same key. Any other failure throws as
    /// before, and so does a read that was cancelled.
    private func sevenTvRead<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        let scope = SevenTvAnswerCache.scope(of: req)
        do {
            let (data, http) = try await send(req)
            let answer = try sevenTvAnswer(type, data, http)
            answers.save(data, for: req.url, scope: scope)
            return answer
        } catch let e as CobaltError {
            guard case .network(let code) = e, code != .cancelled, !Task.isCancelled,
                let saved = answers.load(for: req.url, scope: scope),
                let answer = try? CobaltJSON.decoder().decode(T.self, from: saved)
            else { throw e }
            return answer
        }
    }

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

/// The refusal body: `{status: "error", error: {code, message?}, message?, conflict?: {emote_id, alias}}`. `conflict` comes
/// with `error.seventv.name_taken`: the emote already holding the name in the set, when the server knew it. Every part is
/// read leniently, so an odd `conflict` never loses the code.
enum SevenTvRefusal {
    private struct Body: Decodable {
        struct Err: Decodable {
            var code: String?
            var message: String?
        }

        struct Conflict: Decodable {
            var emoteID: String?
            var alias: String?

            enum CodingKeys: String, CodingKey {
                case alias
                case emoteID = "emote_id"
                case emoteIDCamel = "emoteId"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let snake: String? = (try? c.decodeIfPresent(String.self, forKey: .emoteID)) ?? nil
                let camel: String? = (try? c.decodeIfPresent(String.self, forKey: .emoteIDCamel)) ?? nil
                emoteID = snake ?? camel
                alias = (try? c.decodeIfPresent(String.self, forKey: .alias)) ?? nil
            }
        }

        var error: Err?
        var message: String?
        var conflict: Conflict?

        enum CodingKeys: String, CodingKey { case error, message, conflict }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = (try? c.decodeIfPresent(Err.self, forKey: .error)) ?? nil
            message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
            conflict = (try? c.decodeIfPresent(Conflict.self, forKey: .conflict)) ?? nil
        }
    }

    static func parse(_ data: Data) -> SevenTvError? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data), let code = body.error?.code else { return nil }
        guard let known = SevenTvError(code: code, message: body.message ?? body.error?.message) else { return nil }
        if case .nameTaken = known {
            return .nameTaken(
                conflictEmoteID: SevenTvWire.nonEmpty(body.conflict?.emoteID), alias: SevenTvWire.nonEmpty(body.conflict?.alias))
        }
        return known
    }
}
