import Foundation

// Post frames on the real client (APP-API-CONTRACT 52.2). The routes are written out here; once the op registry's generated
// endpoints (`Generated/Endpoints.swift`) carry `library.postDetails`, `library.setPostDetails`, `library.postAvatar` and
// `library.postFrame`, these can move over like the other calls.
extension HTTPCobaltClient {
    static func postDetailsPath(_ id: String) -> String { "/library/items/\(encode(id))/post-details" }

    /// `GET /library/items/<id>/post-details[?refresh=1]` (keyed). A lookup can wait on the yt-dlp box: 60 s.
    public func postDetails(item id: String, refresh: Bool) async throws -> PostDetails {
        let req = try makeRequest(
            "GET", Self.postDetailsPath(id), query: refresh ? [("refresh", "1")] : [], keyed: true, timeout: 60)
        let (data, http) = try await send(req)
        return try postDetailsAnswer(data, http)
    }

    /// `PATCH /library/items/<id>/post-details` (keyed) with only the fields that change.
    public func setPostDetails(item id: String, _ patch: PostDetailsPatch) async throws -> PostDetails {
        let req = try makeRequest("PATCH", Self.postDetailsPath(id), keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(patch.wire))
        return try postDetailsAnswer(data, http)
    }

    /// `GET /library/items/<id>/post-details/avatar` (keyed): the picture's bytes.
    public func postAvatar(item id: String) async throws -> Data {
        var req = try makeRequest("GET", Self.postDetailsPath(id) + "/avatar", keyed: true, timeout: 30)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode), !data.isEmpty else { throw postFrameError(data, status: http.statusCode) }
        return data
    }

    /// `POST /library/items/<id>/post-frame` (keyed): `202 {render}`. The render queue's refusals come back as `EditError`.
    public func postFrame(item id: String, options: PostFrameOptions) async throws -> EditRender {
        let req = try makeRequest("POST", "/library/items/\(Self.encode(id))/post-frame", keyed: true, timeout: 60)
        let (data, http) = try await send(req, body: Self.jsonBody(Self.postFrameBody(options)))
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                switch code {
                case "error.edit.queue_full": throw EditError.queueFull
                case "error.edit.off": throw EditError.off
                default: break
                }
            }
            throw postFrameError(data, status: http.statusCode)
        }
        struct Wire: Decodable { var render: EditRender }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.render
    }

    /// The body of `POST /library/items/<id>/post-frame` (`PostFrameOptions.wire`).
    static func postFrameBody(_ options: PostFrameOptions) -> [String: Any] { options.wire }

    /// `{"status":"success","details": PostDetails}`, or the refusal.
    private func postDetailsAnswer(_ data: Data, _ http: HTTPURLResponse) throws -> PostDetails {
        guard (200..<300).contains(http.statusCode) else { throw postFrameError(data, status: http.statusCode) }
        struct Wire: Decodable { var details: PostDetails }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw PostFrameError(code: code) ?? CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.details
    }

    /// The post-frame routes' refusals as `PostFrameError`; a `400` with another code is `.badRequest`; anything else stays
    /// the generic `CobaltError.api`.
    func postFrameError(_ data: Data, status: Int) -> Error {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
            if let known = PostFrameError(code: code) { return known }
            if status == 400 { return PostFrameError.badRequest }
        }
        return apiError(data, status: status)
    }
}
