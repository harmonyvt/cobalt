import Foundation

/// Audio loudness leveling endpoints (`features.audio_leveling`) on the live HTTP client.
extension HTTPCobaltClient {
    /// `GET /audio/settings`
    public func audioSettings() async throws -> AudioLevelSettings {
        let ep = Endpoints.audioSettingsGet()
        let req = try makeRequest(ep.method, ep.path, keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(AudioLevelSettings.self, from: data) }
        catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `PUT /audio/settings`
    public func updateAudioSettings(_ patch: AudioLevelSettingsPatch) async throws -> AudioLevelSettings {
        let ep = Endpoints.audioSettingsSet()
        let req = try makeRequest(ep.method, ep.path, keyed: true, timeout: 20)
        let (data, http) = try await send(req, body: Self.jsonBody(patch.body))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(AudioLevelSettings.self, from: data) }
        catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `POST /library/items/:id/audio/level`
    public func levelItemAudio(id: String, target: AudioTargetLufs? = nil) async throws -> AudioLevelQueued {
        let ep = Endpoints.libraryItemAudioLevel(id: id)
        let req = try makeRequest(ep.method, ep.path, keyed: true, timeout: 30)
        var body: [String: Any] = [:]
        if let target { body["target_lufs"] = target.rawValue }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(AudioLevelQueued.self, from: data) }
        catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `DELETE /library/items/:id/audio/level`
    public func removeItemAudioLevel(id: String) async throws -> AudioLevelRemoval {
        let ep = Endpoints.libraryItemAudioRemove(id: id)
        let req = try makeRequest(ep.method, ep.path, keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(AudioLevelRemoval.self, from: data) }
        catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `POST /audio/backfill`
    public func backfillAudioLoudness(limit: Int? = nil) async throws -> AudioBackfillResult {
        let ep = Endpoints.audioBackfill()
        let req = try makeRequest(ep.method, ep.path, keyed: true, timeout: 30)
        var body: [String: Any] = [:]
        if let limit { body["limit"] = max(1, min(25, limit)) }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(AudioBackfillResult.self, from: data) }
        catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }
}
