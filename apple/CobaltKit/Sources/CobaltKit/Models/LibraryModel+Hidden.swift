import Foundation

// The hidden album and the bulk status change (APP-API-CONTRACT 37). A hidden post is in `hiddenPosts` and nowhere else:
// not in `posts`, not in a search, not in `libraryRows` unless the hidden chip (`showingHidden`) is on. `setStatus`
// moves posts between the two lists once the server has answered, one request per `limits.statusIds` posts.

extension LibraryModel {
    // MARK: - The album's pages

    /// The first page of the hidden album (`GET /library?hidden=1`), replacing what was loaded.
    public func loadHidden() async {
        guard !hiddenLoading else { return }
        hiddenLoading = true
        defer { hiddenLoading = false }
        do {
            let epoch = statusEpoch
            let page = try await ctx.client.hiddenLibrary(cursor: nil, limit: Self.pageSize)
            applyHidden(page, replacing: true)
            if epoch == statusEpoch, !statusInFlight { recentlyUnhidden = [] }       // asked after the last change: the truth
            hiddenFailure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { hiddenFailure = f }
        }
    }

    /// The next page of the album.
    public func loadMoreHidden() async {
        guard !hiddenLoading, hiddenHasMore, let cursor = hiddenCursor else { return }
        hiddenLoading = true
        defer { hiddenLoading = false }
        do {
            let page = try await ctx.client.hiddenLibrary(cursor: cursor, limit: Self.pageSize)
            applyHidden(page, replacing: false)
            hiddenFailure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { hiddenFailure = f }
        }
    }

    /// Every hidden post up to `cap`, pages of 50 (a sort, a filter or a search in the album needs them all).
    func loadAllHidden(cap: Int) async {
        guard !hiddenLoading, hiddenPosts.isEmpty || hiddenHasMore else { return }
        hiddenLoading = true
        defer { hiddenLoading = false }
        do {
            var next = hiddenPosts.isEmpty ? nil : hiddenCursor
            while hiddenPosts.count < cap {
                let page = try await ctx.client.hiddenLibrary(cursor: next, limit: min(Self.wholePageSize, cap - hiddenPosts.count))
                applyHidden(page, replacing: next == nil && hiddenPosts.isEmpty)
                hiddenFailure = nil
                next = page.next
                if next == nil || page.posts.isEmpty { break }
            }
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { hiddenFailure = f }
        }
    }

    /// `authoritative`: the page is the server's whole list of hidden posts (not the first page of it), so what the device
    /// remembers of the hidden posts is replaced by it; otherwise the posts are only added to it.
    func applyHidden(_ page: LibraryPage, replacing: Bool, authoritative: Bool = false) {
        // whatever the server calls a hidden page is hidden, files off; a post this device just unhid is not on it (a page
        // that was on its way still lists it)
        let listed = page.posts.filter { !recentlyUnhidden.contains($0.id) }.map { post -> LibraryPost in
            var p = post
            p.hidden = true
            return p
        }
        if replacing {
            // a post this device just hid, in a page that began before it, stays
            let ids = Set(listed.map(\.id))
            let kept = hiddenPosts.filter { recentlyHidden.contains($0.id) && !ids.contains($0.id) }
            hiddenPosts = kept + listed
        } else {
            let known = Set(hiddenPosts.map(\.id))
            hiddenPosts += listed.filter { !known.contains($0.id) }
        }
        if authoritative { replaceHiddenIndex(with: hiddenPosts) } else { rememberHidden(listed) }
        hiddenCursor = page.next
        hiddenHasMore = page.next != nil
        if !statusInFlight { hiddenCount = max(page.hiddenCount, hiddenPosts.count) }
        if replacing { hiddenSyncedCount = hiddenCount }
    }

    // MARK: - What the device remembers (HiddenIndex)

    /// The device now knows these posts are hidden.
    func rememberHidden(_ posts: [LibraryPost]) {
        guard !posts.isEmpty else { return }
        var index = ctx.settings.hiddenIndex
        index.add(posts)
        if index != ctx.settings.hiddenIndex { ctx.settings.hiddenIndex = index; hiddenVersion += 1 }
    }

    /// These posts are not hidden any more (or are gone).
    func forgetHidden(posts ids: some Sequence<String>) {
        var index = ctx.settings.hiddenIndex
        index.remove(posts: ids)
        if index != ctx.settings.hiddenIndex { ctx.settings.hiddenIndex = index; hiddenVersion += 1 }
    }

    func forgetHidden(files ids: Set<String>) {
        var index = ctx.settings.hiddenIndex
        index.remove(files: ids)
        if index != ctx.settings.hiddenIndex { ctx.settings.hiddenIndex = index; hiddenVersion += 1 }
    }

    private func replaceHiddenIndex(with posts: [LibraryPost]) {
        var index = ctx.settings.hiddenIndex
        index.replace(with: posts)
        if index != ctx.settings.hiddenIndex { ctx.settings.hiddenIndex = index; hiddenVersion += 1 }
    }

    /// After a library refresh, and once after launch or a server check: with `features.hidden` the album is read whole
    /// (up to `Self.syncCap` posts, pages of 50) and the device's memory of what is hidden (`HiddenIndex`) is replaced by
    /// it, so the lists of the device's own media never show a hidden post's offline copy: a rule hid a save, another
    /// device hid or unhid a post. Cheap when little is hidden (one request); a long album is read again only when its
    /// count moved or after five minutes. Quiet: no spinner, a failure says nothing. The answer is dropped when this device
    /// changed the hidden posts (a hide, an unhide, a delete) while its pages were on their way.
    func syncHiddenIndex(force: Bool = false) async {
        guard ctx.capabilities.hidden, !hiddenLoading, !hiddenSyncing, !statusInFlight else { return }
        let now = ctx.clock.now()
        let moved = hiddenCount != (hiddenSyncedCount ?? -1)
        let stale = hiddenSyncedAt.map { now.timeIntervalSince($0) > 300 } ?? true
        guard force || moved || stale || hiddenCount <= Self.wholePageSize else { return }
        hiddenSyncing = true
        defer { hiddenSyncing = false }
        let epoch = hiddenEpoch
        var collected: [LibraryPost] = []
        var cursor: String?
        var last: LibraryPage?
        repeat {
            guard let page = try? await ctx.client.hiddenLibrary(cursor: cursor, limit: Self.wholePageSize) else { return }
            collected += page.posts
            cursor = page.next
            last = page
            if page.posts.isEmpty { break }
        } while cursor != nil && collected.count < Self.syncCap && !Task.isCancelled
        await afterHiddenRead?()
        // this device changed what is hidden meanwhile (or a request is on its way): that answer began before it
        guard epoch == hiddenEpoch, !statusInFlight, var whole = last else { return }
        let complete = cursor == nil || last?.posts.isEmpty == true
        whole.posts = collected
        applyHidden(whole, replacing: true, authoritative: complete)
        hiddenSyncedAt = now
    }

    /// Previews: the album starts with these posts.
    func seedHidden(_ posts: [LibraryPost]) {
        hiddenPosts = posts
        hiddenCount = posts.count
        hiddenSyncedCount = posts.count
        replaceHiddenIndex(with: posts)
    }

    // MARK: - Bulk status

    /// Gives every post the status: `hidden` takes them out of the library into the album, `off`, `public` and `private`
    /// put a hidden post back (its files stay off until the status says otherwise) and switch a visible one. One
    /// `POST /library/status` per `limits.statusIds` posts (200 at most); what the server refused is in the outcome and
    /// stays as it was. A post moves only after the server answered for it.
    @discardableResult
    public func setStatus(_ status: PostStatus, posts targets: [LibraryPost]) async -> StatusOutcome {
        var seen = Set<String>()
        let unique = targets.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return StatusOutcome() }
        let byID = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let size = max(1, min(200, ctx.capabilities.limits.statusIds))
        let ids = unique.map(\.id)

        statusInFlight = true
        statusEpoch += 1
        hiddenEpoch += 1
        defer { statusInFlight = false; statusEpoch += 1; hiddenEpoch += 1 }

        var outcome = StatusOutcome()
        var threw = false
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + size, ids.count)])
            start += size
            // hiding: a page already on its way must not list them again
            if status == .hidden { recentlyHidden.formUnion(chunk) }
            do {
                let change = try await ctx.client.setStatus(ids: chunk, status: status)
                // a failure that names a file of a post the server answered for is the file's; any other is the post's
                var answered = Set<String>()
                for answer in change.posts { answered.insert(answer.id); answered.formUnion(answer.files.map(\.id)) }
                for answer in change.posts { for post in [byID[answer.id] ?? byID[answer.postKey]].compactMap({ $0 }) { answered.formUnion(post.files.map(\.id)) } }
                let failedFiles = Set(change.failed.filter { answered.contains($0.id) }.map(\.id))
                // the first post asked for ends up first in the album
                for answer in change.posts.reversed() {
                    guard let post = byID[answer.id] ?? byID[answer.postKey] else { continue }
                    move(post, answer, failedFiles: failedFiles)
                }
                outcome.changed += change.posts.count
                for failure in change.failed {
                    if failedFiles.contains(failure.id) { outcome.fileFailures.append(failure) } else { outcome.failed.append(failure) }
                }
                if status == .hidden {
                    // a post the server did not hide stays in the library
                    let hidden = Set(change.posts.map(\.id))
                    recentlyHidden.subtract(chunk.filter { !hidden.contains($0) })
                }
            } catch {
                threw = true
                if status == .hidden { recentlyHidden.subtract(chunk) }
                let code = Self.statusErrorCode(error)
                outcome.failed += chunk.map { StatusChange.Failure(id: $0, error: code) }
                // nothing reached the server: do not ask again for the rest
                if case .network? = error as? CobaltError {
                    outcome.failed += ids[start...].map { StatusChange.Failure(id: $0, error: code) }
                    break
                }
            }
        }
        if threw {
            // the server may have changed some of them before the answer was lost: read both lists again, quietly
            Task { [weak self] in
                await self?.refresh()
                await self?.syncHiddenIndex(force: true)
            }
        }
        return outcome
    }

    /// The code that says why a whole request failed.
    static func statusErrorCode(_ error: Error) -> String {
        switch error {
        case let e as CobaltError:
            switch e {
            case .api(let code, _): return code
            case .network: return "error.app.unreachable"
            case .noAPIKey: return "error.api.auth.key.missing"
            default: return "error.api.generic"
            }
        case let f as PipelineFailure:
            if case .server(let code) = f { return code }
            return f == .unsupported ? "error.library.unsupported" : "error.api.generic"
        default:
            return "error.api.generic"
        }
    }

    /// The server answered for `post`: it moves between `posts` and `hiddenPosts`, its files take the answer, the counts follow.
    private func move(_ post: LibraryPost, _ answer: StatusChange.Post, failedFiles: Set<String> = []) {
        let id = post.id
        let current = posts.first { $0.id == id } ?? hiddenPosts.first { $0.id == id } ?? post
        let wasHidden = hiddenPosts.contains { $0.id == id } || current.hidden
        let inLibrary = posts.contains { $0.id == id }
        if expandedPostID == id { expandedPostID = nil }

        if answer.status == .hidden {
            var hidden = current
            hidden.hidden = true
            hidden.hiddenBy = .you
            hidden.hiddenRule = nil
            // the server's word for each file: one it could not take off (it is listed under `failed`) stays as it was
            for i in hidden.files.indices {
                let wire = answer.files.first { $0.id == hidden.files[i].id }
                if wire?.visibility == "public" { hidden.files[i].wireVisibility = .public; continue }       // still public: the server says so
                if wire == nil, failedFiles.contains(hidden.files[i].id) { continue }         // failed and not described: as it was
                Self.switchOff(&hidden.files[i])
            }
            if hidden.visibility != nil { hidden.visibility = hidden.files.contains { $0.isPublic } ? .public : .private }
            hiddenPosts.removeAll { $0.id == id }
            hiddenPosts.insert(hidden, at: 0)
            rememberHidden([hidden])
            recentlyUnhidden.remove(id)
            forgetSearched(posts: [id])
            if inLibrary {
                posts.removeAll { $0.id == id }
                postCount = max(0, postCount - 1)
                fileCount = max(0, fileCount - current.files.count)
            }
            if !wasHidden { hiddenCount += 1 }
            return
        }

        var next = current
        next.hidden = false
        next.hiddenBy = nil
        next.hiddenRule = nil
        for i in next.files.indices {
            let wire = answer.files.first { $0.id == next.files[i].id }
            if wire == nil, failedFiles.contains(next.files[i].id) { continue }              // failed and not described: as it was
            // the server's word for the file, else the post's status
            if wire.map({ $0.visibility == "public" }) ?? (answer.status == .public) {
                next.files[i].wireVisibility = .public
                next.files[i].privateURL = nil
                if next.files[i].url == nil, let name = next.files[i].mediaName, let base = ctx.capabilities.mediaBaseURL {
                    next.files[i].url = base.appendingPathComponent(name)
                }
            } else {
                Self.switchOff(&next.files[i])
                if answer.status == .private { next.files[i].privateURL = wire?.privateURL }
            }
        }
        if next.visibility != nil {
            next.visibility = next.files.first { $0.role == .privateCopy }?.visibility
                ?? (next.files.contains { $0.isPublic } ? .public : .private)
        }
        if wasHidden {
            hiddenPosts.removeAll { $0.id == id }
            hiddenCount = max(0, hiddenCount - 1)
            recentlyHidden.remove(id)
            recentlyUnhidden.insert(id)         // a hidden page that began before this still lists it
            forgetHidden(posts: [id])
            if !inLibrary {
                let at = posts.firstIndex { $0.createdAt < next.createdAt } ?? posts.endIndex
                posts.insert(next, at: at)
                postCount += 1
                fileCount += next.files.count
            }
        }
        if let index = posts.firstIndex(where: { $0.id == id }) { posts[index] = next }
        if var results = searchResults, let i = results.firstIndex(where: { $0.id == id }) {
            results[i] = next
            searchResults = results
        }
        if searchKnown[id] != nil { searchKnown[id] = next }
    }

    /// A file with no link: not public, no private link, no public address.
    private static func switchOff(_ file: inout LibraryFile) {
        file.wireVisibility = .private
        file.privateURL = nil
        file.url = nil
    }

    // MARK: - Deletes from the album

    /// The server confirmed these files gone: they leave the album, and a hidden post left with none goes with them.
    func dropHidden(files ids: Set<String>) {
        guard !ids.isEmpty else { return }
        hiddenEpoch += 1
        forgetHidden(files: ids)
        guard !hiddenPosts.isEmpty else { return }
        for index in hiddenPosts.indices.reversed() {
            let before = hiddenPosts[index].files.count
            hiddenPosts[index].files.removeAll { ids.contains($0.id) }
            guard hiddenPosts[index].files.count != before else { continue }
            if hiddenPosts[index].files.isEmpty {
                if expandedPostID == hiddenPosts[index].id { expandedPostID = nil }
                hiddenPosts.remove(at: index)
                hiddenCount = max(0, hiddenCount - 1)
            }
        }
    }

    /// A whole hidden post is gone on the server.
    func dropHidden(post id: String) {
        hiddenEpoch += 1
        forgetHidden(posts: [id])
        guard let index = hiddenPosts.firstIndex(where: { $0.id == id }) else { return }
        if expandedPostID == id { expandedPostID = nil }
        hiddenPosts.remove(at: index)
        hiddenCount = max(0, hiddenCount - 1)
    }
}
