import Foundation

// The generated endpoints (Generated/Endpoints.swift, from the server's op registry, APP-API-CONTRACT 33.13) on the
// real client: the request comes from the endpoint, so the method, path and whether the key goes along match the
// server's own route. The library list and the collections use them first; the other calls move over one at a time.
extension HTTPCobaltClient {
    /// A request for a generated endpoint. The key goes along exactly when the route takes one.
    func makeRequest<R>(_ endpoint: APIEndpoint<R>, query: [(String, String)] = [], timeout: TimeInterval = 30) throws -> URLRequest {
        try makeRequest(endpoint.method, endpoint.path, query: query, keyed: endpoint.auth.keyed, timeout: timeout)
    }

    /// The endpoint's reply, decoded as its generated type. A non-2xx answer, or a 2xx that is an error envelope, throws
    /// as the keyed calls throw it; `refusal` maps a route's own error codes first.
    func send<R>(
        _ endpoint: APIEndpoint<R>, query: [(String, String)] = [], timeout: TimeInterval = 30,
        refusal: ((Data, Int) -> Error)? = nil
    ) async throws -> R {
        let (data, http) = try await send(makeRequest(endpoint, query: query, timeout: timeout))
        guard (200..<300).contains(http.statusCode) else { throw refusal?(data, http.statusCode) ?? apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(R.self, from: data) }
        catch {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }
}
