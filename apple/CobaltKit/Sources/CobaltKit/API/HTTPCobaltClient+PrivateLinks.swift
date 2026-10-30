import Foundation

// Private share links (APP-API-CONTRACT 36.3) on the real client, keyed. Built with the literal paths (not generated
// endpoint helpers), so it compiles before `Endpoints.swift` is regenerated; the routes move to the generated ones like
// the other calls, one at a time.
extension HTTPCobaltClient {
    /// `GET /share/private`. Before migration 0024 the server answers `{links: [], new_links: "public"}`.
    public func privateLinks() async throws -> PrivateLinkList {
        let req = try makeRequest("GET", "/share/private", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw privateLinkError(data, status: http.statusCode) }
        do { return try PrivateLinkList.decode(data) } catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `PUT /share/private/items|sets/<id>` → `{status, link}`.
    public func enablePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink {
        let req = try makeRequest("PUT", Self.privatePath(kind, id), keyed: true, timeout: 60)
        return try await privateLinkAnswer(req)
    }

    /// `DELETE /share/private/items|sets/<id>` → `{status}`; none live is still 200.
    public func revokePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws {
        let req = try makeRequest("DELETE", Self.privatePath(kind, id), keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw privateLinkError(data, status: http.statusCode) }
    }

    /// `POST /share/private/items|sets/<id>/rotate` → `{status, link}`.
    public func rotatePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink {
        let req = try makeRequest("POST", Self.privatePath(kind, id) + "/rotate", keyed: true, timeout: 30)
        return try await privateLinkAnswer(req)
    }

    /// `POST /share/private/rotate-all` → `{status, links, rotated}`.
    public func rotateAllPrivateLinks() async throws -> PrivateLinkRotation {
        let req = try makeRequest("POST", "/share/private/rotate-all", keyed: true, timeout: 60)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw privateLinkError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(PrivateLinkRotation.self, from: data) }
        catch { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
    }

    /// `PATCH /share/private/settings {"new_links"}` → `{status, new_links}`.
    public func setNewLinks(_ value: NewLinks) async throws -> NewLinks {
        let req = try makeRequest("PATCH", "/share/private/settings", keyed: true, timeout: 20)
        let (data, http) = try await send(req, body: Self.jsonBody(["new_links": value.rawValue]))
        guard (200..<300).contains(http.statusCode) else { throw privateLinkError(data, status: http.statusCode) }
        struct Wire: Decodable { var newLinks: NewLinks? }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.newLinks ?? value
    }

    /// `POST /share/collections/<id>/privacy` `{private}` or `{rotate: true}` → `{status, links}`. `404
    /// error.collection.not_found` is `ShareCollectionError.notFound`, `400 error.collection.bad_request` `.badRequest`.
    public func setCollectionPrivacy(id: String, _ change: CollectionPrivacy) async throws -> [PrivateLink] {
        let req = try makeRequest("POST", "/share/collections/\(Self.encode(id))/privacy", keyed: true, timeout: 60)
        let (data, http) = try await send(req, body: Self.jsonBody(change.body))
        guard (200..<300).contains(http.statusCode) else {
            struct Body: Decodable {
                struct Err: Decodable { var code: String? }
                var error: Err?
            }
            switch (try? JSONDecoder().decode(Body.self, from: data))?.error?.code {
            case "error.collection.not_found": throw ShareCollectionError.notFound
            case "error.collection.bad_request": throw ShareCollectionError.badRequest
            default:
                if http.statusCode == 503 { throw ShareCollectionError.unavailable }
                throw privateLinkError(data, status: http.statusCode)
            }
        }
        struct Wire: Decodable { var links: [Lossy<PrivateLink>]? }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return (wire.links ?? []).compactMap(\.value)
    }

    // MARK: plumbing

    /// `/share/private/items/<id>` or `/share/private/sets/<id>`.
    static func privatePath(_ kind: PrivateLink.Kind, _ id: String) -> String {
        "/share/private/\(kind == .item ? "items" : "sets")/\(encode(id))"
    }

    private func privateLinkAnswer(_ req: URLRequest) async throws -> PrivateLink {
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw privateLinkError(data, status: http.statusCode) }
        struct Wire: Decodable { var link: PrivateLink }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.link
    }

    /// The private-link routes' refusals as `PrivateLinkError`; any other code stays the generic `CobaltError.api` (a
    /// revoked key keeps its own code, so the app can say so).
    func privateLinkError(_ data: Data, status: Int) -> Error {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
        }
        switch (try? JSONDecoder().decode(Body.self, from: data))?.error?.code {
        case "error.private.not_found": return PrivateLinkError.notFound
        case "error.private.not_toggleable": return PrivateLinkError.notToggleable
        case "error.private.bad_request": return PrivateLinkError.badRequest
        case let code? where code.hasPrefix("error.api.auth."): return apiError(data, status: status)
        default:
            if status == 503 { return PrivateLinkError.unavailable }
            return apiError(data, status: status)
        }
    }
}
