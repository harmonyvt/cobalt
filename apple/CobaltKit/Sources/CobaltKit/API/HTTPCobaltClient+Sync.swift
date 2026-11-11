import Foundation

// `GET /sync` (the contract in `SyncContract.swift`). A server without the route (404) is
// `SyncError.notDeployed`: the library keeps today's pages for this launch. A 503 is not: the server
// answers it for any database read that failed, not only for tables that are not there yet, so it is
// thrown like every other error answer. With nothing on the device the engine still falls back on it
// (`SyncEngine.pullFailed`); with a copy and edits waiting, the engine must stay on.
extension HTTPCobaltClient {
    func syncChanges(since: Int64, limit: Int) async throws -> SyncPage {
        let capped = max(1, min(SyncContract.pageLimit, limit))
        let req = try makeRequest(
            "GET", SyncContract.path, query: [("since", String(since)), ("limit", String(capped))],
            keyed: true, timeout: 60)
        // A lost connection, a missing key and an error answer are thrown as they are, so the library
        // can word them the way it words a failed `GET /library`.
        let (data, http) = try await send(req)
        if http.statusCode == 404 { throw SyncError.notDeployed }
        if SyncPage.isCursorTooOld(status: http.statusCode, data: data) { throw SyncError.cursorTooOld }
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        return try SyncPage.decode(data)
    }
}
