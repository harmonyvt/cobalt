import Foundation

// Fetching an evicted item again (CONTRACT-LIVE.md 4.2). The stored properties live in
// `LibraryModel` (`redownloads`, `redownloadTasks`).

extension LibraryModel {
    /// An entry the storage limit emptied (poster and record kept, `fileURL` nil) gets its file back
    /// from the server and keeps its id, poster and metadata: the original from the studio session
    /// (`GET /studio/<sid>/source`, good for 7 days), then from the URL it was first downloaded from,
    /// then from the library's private copy (`GET /library/items/<id>/file`); a webp from its public
    /// URL. The refilled entry becomes the newest for eviction. Progress shows in
    /// `redownloads[video.id]`; a second call for the same entry joins the first.
    ///
    /// Throws the mapped `PipelineFailure` (`.expired` when the server no longer has it,
    /// `.unreachable`, ...). Nothing is attached on failure.
    @discardableResult
    public func redownload(_ video: StoredVideo) async throws -> StoredVideo {
        if let running = redownloadTasks[video.id] { return try await running.value }
        let id = video.id
        let task = Task { @MainActor [self] in
            defer {
                redownloadTasks[id] = nil
                redownloads[id] = nil
            }
            return try await fetchAgain(video)
        }
        redownloadTasks[id] = task
        redownloads[id] = TransferProgress(bytes: 0, total: video.bytes > 0 ? video.bytes : nil)
        return try await task.value
    }

    private func fetchAgain(_ video: StoredVideo) async throws -> StoredVideo {
        // Already back (another process refilled it): nothing to fetch.
        if let current = ctx.store.videos.first(where: { $0.id == video.id }),
           let url = current.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return current
        }
        let client = ctx.client
        let id = video.id
        let relay = MainActorRelay<TransferProgress> { [weak self] p in
            if self?.redownloads[id] != nil { self?.redownloads[id] = p }
        }
        var candidates = await redownloadSources(for: video, includeLibrary: false)
        var triedLibrary = false
        var lastError: Error = PipelineFailure.expired
        while true {
            guard !candidates.isEmpty else {
                if !triedLibrary {
                    triedLibrary = true
                    candidates = await redownloadSources(for: video, includeLibrary: true)
                    continue
                }
                throw pipelineFailure(from: lastError, during: .saving, limits: ctx.capabilities.limits) ?? lastError
            }
            let source = candidates.removeFirst()
            let dest = ctx.store.inboxURL(for: Self.redownloadName(for: video))
            do {
                let file = try await client.download(source, to: dest) { relay.push($0) }
                try Task.checkCancellation()
                do {
                    return try await ctx.store.attach(file: file, to: video.id, move: true, keep: true)
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            } catch {
                if error is OfflineStoreError { throw error }       // the record was removed meanwhile: not a server matter
                lastError = error
                guard Self.sourceIsGone(error) else {
                    throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
                }
            }
        }
    }

    /// The server (or the web) answered "not here": try the next place. Anything else (offline, a
    /// revoked key, a full disk) would fail the same way again.
    private static func sourceIsGone(_ error: Error) -> Bool {
        guard let e = error as? CobaltError else { return false }
        switch e {
        case .api(let code, let status):
            return [404, 409, 410].contains(status)
                || ["error.studio.expired", "error.studio.not_found", "error.studio.not_ready"].contains(code)
        case .invalidResponse(let status):
            return [404, 410].contains(status)
        default:
            return false
        }
    }

    private static func redownloadName(for video: StoredVideo) -> String {
        let ext = video.kind == .webp ? "webp" : "mp4"
        return (video.name as NSString).pathExtension.isEmpty ? "\(video.name).\(ext)" : video.name
    }

    /// Where a stored item's bytes may still live, best first. The library listing is only read when
    /// the cheaper places are gone.
    private func redownloadSources(for video: StoredVideo, includeLibrary: Bool) async -> [RemoteFile] {
        var out: [RemoteFile] = []
        switch video.kind {
        case .original:
            if !includeLibrary {
                if let sid = video.sessionID { out.append(.studioSource(session: sid)) }
                if let url = video.remoteURL { out.append(.open(url)) }
            } else if ctx.capabilities.library {
                if posts.isEmpty { await refresh() }
                for post in posts {
                    let sameSession = video.sessionID != nil && post.session?.id == video.sessionID
                    let sameLink = video.link != nil && post.link == video.link
                    guard sameSession || sameLink else { continue }
                    for file in post.files where file.role == .privateCopy { out.append(.libraryItem(id: file.id)) }
                }
            }
        case .webp:
            if !includeLibrary, let url = video.remoteURL { out.append(.open(url)) }
        }
        return out
    }
}
