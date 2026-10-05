import Foundation

/// `PATCH /library/items/<id>/post` (CONTRACT-LIBRARY2 4.2, section 6; keyed). Lives in its own file so
/// `HTTPCobaltClient.swift` stays untouched while another lane edits it.
///
/// Signs with the client's own key and session (both internal for this file).
extension HTTPCobaltClient {
    private struct TitleError: Decodable {
        struct Body: Decodable { var code: String? }
        var error: Body?
    }

    /// The key and session `setTitle` signs and sends with.
    var titleCredentials: (key: String?, session: URLSession) { (apiKey(), urlSession) }

    /// 200 → the result; `400 error.library.bad_title` → `PipelineFailure.server`; `404` →
    /// `.server("error.library.not_found")`; anything else as the other keyed calls throw it
    /// (`CobaltError.api(code:httpStatus:)`, which maps to `.keyInvalid` for a revoked key).
    public func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult {
        let (key, session) = titleCredentials
        guard let key else { throw CobaltError.noAPIKey }               // never leaves the device
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CobaltError.invalidResponse(httpStatus: 0)
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let safeID = itemID.addingPercentEncoding(withAllowedCharacters: allowed) ?? itemID
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.percentEncodedPath = basePath + "/library/items/\(safeID)/post"
        guard let url = comps.url else { throw CobaltError.invalidResponse(httpStatus: 0) }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Api-Key \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title.map { $0 as Any } ?? NSNull()])

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: req)
            guard let r = response as? HTTPURLResponse else { throw CobaltError.invalidResponse(httpStatus: 0) }
            (data, http) = (d, r)
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
        let code = (try? JSONDecoder().decode(TitleError.self, from: data))?.error?.code
        switch http.statusCode {
        case 200..<300:
            guard let result = try? CobaltJSON.decoder().decode(PostTitleResult.self, from: data) else {
                if let code { throw CobaltError.api(code: code, httpStatus: http.statusCode) }
                throw CobaltError.invalidResponse(httpStatus: http.statusCode)
            }
            return result
        case 400 where code == "error.library.bad_title":
            throw PipelineFailure.server(code: "error.library.bad_title")
        case 404:
            throw PipelineFailure.server(code: "error.library.not_found")
        default:
            if let code { throw CobaltError.api(code: code, httpStatus: http.statusCode) }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }
}
