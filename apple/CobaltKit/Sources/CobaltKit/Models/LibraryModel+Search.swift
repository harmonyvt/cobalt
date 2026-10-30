import Foundation

// The library's server search (APP-API-CONTRACT 21; apple/CONTRACT.md 13). With `features.search`, a query of two or
// more letters waits out a typing pause (`searchDebounce`), then asks `GET /library/search`; a new keystroke cancels
// whatever is in flight. The local name filter (`AppModel.libraryRows`) answers at once and stays the answer while the
// server thinks, and whenever it cannot (search off, failed, offline). `503 error.search.waking` is retried every
// `wakingRetry` seconds, up to `wakingRetries` times (a Space waking from sleep takes a few minutes to load the model);
// after that the search is `.failed` and the name matches stay, rather than a spinner that never ends.

extension LibraryModel {
    /// The typing pause before a query goes to the server.
    static let searchDebounce: Double = 0.35
    /// The wait between retries of a search the sleeping Space refused (`error.search.waking`).
    static let wakingRetry: Double = 15
    /// Retries of a waking search before giving up on it (with the server's own 25 s wait each, about 2 to 5 minutes).
    static let wakingRetries = 8
    /// Posts asked for (the server's maximum).
    static let searchLimit = 50

    /// A query the server is asked about: at least two characters once spaces are gone.
    static func isServerQuery(_ query: String) -> Bool {
        query.filter { !$0.isWhitespace }.count >= 2
    }

    /// The server's results for the current query, when there are any.
    public var activeSearchResults: [LibraryPost]? {
        guard !trimmedQuery.isEmpty else { return nil }
        return searchResults
    }

    /// A post by id: the loaded one, else one a search returned (for a detail opened from a result past the loaded pages).
    public func post(id: String) -> LibraryPost? {
        posts.first { $0.id == id } ?? searchResults?.first { $0.id == id } ?? searchKnown[id]
    }

    /// `query` changed: drop the last answer (it was for other words), cancel what is in flight, and start the pause.
    func queryDidChange() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
        searchScores = [:]
        let q = trimmedQuery
        guard ctx.capabilities.search, Self.isServerQuery(q) else {
            searchState = .idle
            return
        }
        if searchOffByServer {
            searchState = .off
            return
        }
        searchState = .searching
        let clock = ctx.clock
        searchTask = Task { [weak self] in
            do { try await clock.sleep(seconds: Self.searchDebounce) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.runSearch(q, wakingRetriesLeft: Self.wakingRetries)
        }
    }

    /// Asks the server for `q`; an answer for words that are no longer in the field is thrown away.
    func runSearch(_ q: String, wakingRetriesLeft: Int) async {
        // a retry keeps saying the Space is waking up, not "searching…" for each try
        if searchState != .waking { searchState = .searching }
        do {
            let result = try await ctx.librarySearch(query: q, limit: Self.searchLimit)
            guard !Task.isCancelled, q == trimmedQuery else { return }
            let posts = result.posts
            searchResults = posts
            searchScores = Dictionary(result.hits.map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })
            for post in posts { searchKnown[post.id] = post }
            searchState = .results(count: posts.count, pending: max(0, result.pending ?? 0))
        } catch {
            guard !Task.isCancelled, q == trimmedQuery else { return }
            searchResults = nil
            searchScores = [:]
            switch Self.searchErrorCode(error) {
            case "error.search.waking":
                guard wakingRetriesLeft > 0 else {
                    searchState = .failed
                    return
                }
                searchState = .waking
                do { try await ctx.clock.sleep(seconds: Self.wakingRetry) } catch { return }
                guard !Task.isCancelled, q == trimmedQuery else { return }
                await runSearch(q, wakingRetriesLeft: wakingRetriesLeft - 1)
            case "error.search.off":
                searchOffByServer = true
                searchState = .off
            default:
                searchState = .failed
            }
        }
    }

    /// The server's error code behind a failed search, when it sent one.
    public static func searchErrorCode(_ error: Error) -> String? {
        if case let .api(code, _)? = error as? CobaltError { return code }
        if case let .server(code)? = error as? PipelineFailure { return code }
        return nil
    }

    /// `GET /library/search/post` for the detail's "search index" section (only when `features.search`).
    public func searchStatus(postKey: String) async throws -> LibrarySearchStatus {
        guard ctx.capabilities.search else { throw PipelineFailure.unsupported }
        return try await ctx.client.librarySearchStatus(postKey: postKey)
    }

    /// `GET /library/about` for the detail's "what it's about" section (only when `features.about`, which needs search).
    public func about(postKey: String) async throws -> LibraryAbout {
        guard ctx.capabilities.about else { throw PipelineFailure.unsupported }
        return try await ctx.client.libraryAbout(postKey: postKey)
    }

    /// `PATCH /library/about`: the owner's tags for the post (cleaned and capped as the server keeps them); nil goes back
    /// to the server's own. Answers the post's about as it is now.
    public func setAboutTags(postKey: String, tags: [String]?) async throws -> LibraryAbout {
        guard ctx.capabilities.about else { throw PipelineFailure.unsupported }
        return try await ctx.client.setLibraryAboutTags(postKey: postKey, tags: tags.map(LibraryAbout.cleanTags))
    }

    /// Files the server confirmed gone leave the search's copies too; a post left with none goes.
    func forgetSearched(files ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if var results = searchResults {
            for index in results.indices { results[index].files.removeAll { ids.contains($0.id) } }
            searchResults = results.filter { !$0.files.isEmpty }
        }
        for (id, var post) in searchKnown where post.files.contains(where: { ids.contains($0.id) }) {
            post.files.removeAll { ids.contains($0.id) }
            searchKnown[id] = post.files.isEmpty ? nil : post
        }
    }

    /// Whole posts gone on the server leave the search's copies.
    func forgetSearched(posts ids: Set<String>) {
        guard !ids.isEmpty else { return }
        searchResults?.removeAll { ids.contains($0.id) }
        for id in ids { searchKnown[id] = nil }
    }
}
