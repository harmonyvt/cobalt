import Foundation

// `GET /sync` (the contract in `SyncContract.swift`). Absent until the server slice ships: a 404 is
// `SyncError.notDeployed` and the library keeps today's pages.
extension HTTPCobaltClient {
    func syncChanges(since: Int64, limit: Int) async throws -> SyncPage {
        let capped = max(1, min(SyncContract.pageLimit, limit))
        let req = try makeRequest(
            "GET", SyncContract.path, query: [("since", String(since)), ("limit", String(capped))],
            keyed: true, timeout: 60)
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await send(req)
        } catch let error as CobaltError {
            if case .network = error { throw SyncError.retryable(String(describing: error)) }
            throw error
        }
        if http.statusCode == 404 { throw SyncError.notDeployed }
        if SyncPage.isCursorTooOld(status: http.statusCode, data: data) { throw SyncError.cursorTooOld }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.retryable(String(describing: apiError(data, status: http.statusCode)))
        }
        return try SyncPage.decode(data)
    }
}
