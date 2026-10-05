import Foundation
import UniformTypeIdentifiers

// One media, many renditions (CONTRACT-MEDIA.md): the join of the device's `StoredMedia` with the
// library's `LibraryPost`, and what the detail can do with it.

extension AppModel {
    // MARK: - Joining

    /// The device's media, joined with the library's post for it when the library has one.
    public func mediaItem(for local: StoredMedia) -> MediaItem {
        let post = library.posts.first { MediaItem.joins(local, $0) }
        return withLocalTitle(MediaItem.merge(local: local, post: post)!)          // `local` is non-nil: never nil
    }

    /// The library's post, joined with the device's media for it when the store has one.
    public func mediaItem(for post: LibraryPost) -> MediaItem {
        let local = store.media.first { MediaItem.joins($0, post) }
        return withLocalTitle(MediaItem.merge(local: local, post: post)!)          // `post` is non-nil: never nil
    }

    /// The device's own rename of a media wins over a copy the store carries (it is the newer one).
    /// A `StoredMedia` a view still holds may predate a rename: the store's record is the current one.
    private func withLocalTitle(_ item: MediaItem) -> MediaItem {
        var item = item
        if let local = item.local, let current = store.media(id: local.id) { item.localTitle = current.customTitle }
        if let title = library.localTitles[item.id] { item.localTitle = title }
        return item
    }

    // MARK: - Renaming (CONTRACT-LIBRARY2 decisions 5-8)

    /// Decision 5: optimistic (the title shows at once, on the library's post and on this device), then
    /// `PATCH /library/items/<id>/post` when the media has a server file and the server has `titles`;
    /// a failure reverts both and throws the mapped failure (`couldn't rename that. try again.`).
    /// `nil`, an empty or blank text, or the default text clears the custom title. Without the capability
    /// (an older deploy, plain cobalt) the rename stays on this device and no request is made.
    public func rename(_ item: MediaItem, to raw: String?) async throws {
        let cleaned = raw.flatMap(MediaTitle.clean)
        let new: String? = cleaned == item.defaultTitleText ? nil : cleaned
        guard new != item.customTitle else { return }

        let post = item.post
        let previousPost = post?.customTitle
        let previousLocal = item.localTitle
        persistLocalTitle(new, for: item)
        guard capabilities.titles, let post, let anchor = post.files.first?.id else { return }

        library.setCustomTitle(new, post: post.id)
        do {
            let result = try await ctx.client.setTitle(anchor: anchor, new)
            // the server may have trimmed or cut it further than we did: its answer is the truth
            if result.title != new {
                library.setCustomTitle(result.title, post: post.id)
                persistLocalTitle(result.title, for: item)
            }
        } catch {
            library.setCustomTitle(previousPost, post: post.id)
            persistLocalTitle(previousLocal, for: item)
            throw failure(from: error)
        }
    }

    /// This device keeps the title too (decision 8): on every record of the media (`StoredVideo.title`).
    /// A post this device holds no media for (and a store write that failed) keeps it in memory only,
    /// in `library.localTitles`, which `mediaItem(for:)` overlays.
    func persistLocalTitle(_ title: String?, for item: MediaItem) {
        if let local = item.local, store.writeTitle(title, media: local.id) {
            library.setLocalTitle(nil, media: item.id)               // the store is the copy now
        } else {
            library.setLocalTitle(title, media: item.id)
        }
    }

    // MARK: - Public or private (CONTRACT-VISIBILITY.md)

    /// Library file ids with a switch on its way to the server.
    public var visibilityInFlight: Set<String> { library.visibilityInFlight }

    /// The switch of this rendition is on its way to the server.
    public func isChangingVisibility(_ rendition: Rendition) -> Bool {
        rendition.file.map { library.visibilityInFlight.contains($0.id) } ?? false
    }

    /// Turns a rendition's public link on or off. Optimistic like `rename`: the library's file flips at once (off
    /// drops its link; on has none to show until the server's answer, which carries the same link every time),
    /// then `PATCH /library/items/<id>/visibility`; a failure puts the file back and throws the mapped failure.
    /// On success the server's file replaces ours and this device's record of the original follows (the link is
    /// kept or cleared). One request per file at a time: a second call while one runs changes nothing.
    /// Throws `.unsupported` without the capability, or for a rendition the server does not take.
    @discardableResult
    public func setVisibility(_ rendition: Rendition, public makePublic: Bool) async throws -> VisibilityChange {
        guard capabilities.visibility, let listed = rendition.file, listed.canToggleVisibility else {
            throw PipelineFailure.unsupported
        }
        guard !library.visibilityInFlight.contains(listed.id) else { return VisibilityChange(file: listed, cacheCleared: nil) }
        let previous = library.file(id: listed.id) ?? listed
        library.visibilityInFlight.insert(listed.id)
        defer { library.visibilityInFlight.remove(listed.id) }

        var optimistic = previous
        optimistic.wireVisibility = makePublic ? .public : .private
        if !makePublic { optimistic.url = nil }
        library.replace(file: optimistic)
        do {
            let change = try await ctx.client.setVisibility(item: listed.id, public: makePublic)
            library.replace(file: change.file)
            if !rendition.isWebp, let local = rendition.local {
                ctx.store.setPublicURL(change.file.isPublic ? change.file.url : nil, forSession: local.sessionID, orEntry: local.id)
            }
            return change
        } catch {
            library.replace(file: previous)
            throw failure(from: error)
        }
    }

    // MARK: - Another webp

    /// "another webp" / "make a webp": the home tab, the focus on this media with the trim open; the
    /// run's webp joins this media (`Pipeline.targetMediaID`). The source is the local original when
    /// it is on disk, else the open session, else the library item reopened (5 days). Generalises
    /// `trimNewWebp(from:)`, which stays.
    public func makeWebp(for item: MediaItem) async {
        var item = item
        // A media the device has but the library has not been loaded for yet: its post is where the
        // private copy (the reopen) lives.
        if item.post == nil, let local = item.local, capabilities.library, library.posts.isEmpty {
            await library.refresh()
            item = mediaItem(for: local)
        }
        selectedTab = .save
        if let post = item.post {
            pipeline.resumeFromLibrary(post)
        } else if let local = item.local,
                  let sid = local.original?.sessionID ?? local.renditions.compactMap(\.sessionID).first {
            let source = local.original ?? local.face
            pipeline.resume(session: sid, media: MediaInfo(
                name: local.title, duration: source.duration, width: source.width, height: source.height,
                bytes: source.bytes, isImage: false))
        } else {
            return                                                  // nothing to make a webp from
        }
        pipeline.targetMediaID = item.local?.id                      // after `begin`, which cleared it
    }

    // MARK: - Photos

    /// The Photos ledger key of a rendition (CONTRACT-MEDIA 1.15): the key of its local record (`s:<sid>` for
    /// a video, `w:<url>` for a webp), else for a webp this device never held the key its record would get
    /// (`w:<public url>`). A video with no local record has none.
    func photosKey(of rendition: Rendition) -> String? {
        if let local = rendition.local { return PhotosKey.of(local) }
        guard rendition.isWebp, let url = rendition.file?.url ?? rendition.publicURL else { return nil }
        return PhotosKey.of(kind: .webp, sessionID: nil, remoteURL: url, storeID: "")
    }

    /// Where the rendition is in the owner's Photos right now: the album, the library, or nowhere. Reads the
    /// same ledger the album sync and the focus's "save to photos" write.
    public func photosPlacement(of rendition: Rendition) -> PhotosPlacement {
        guard let key = photosKey(of: rendition) else { return .none }
        return ctx.photosPlacement(forKey: key)
    }

    /// "save to photos" from the detail: the file goes to Photos (into the `cobalt` album when the app's sync
    /// has it on) and its ledger key is recorded, so the sync never adds it again and the button reads
    /// "in your cobalt album" / "in your photos" (`photosPlacement(of:)`). A rendition with no file here
    /// first fetches its stored copy: the library's file (as `LibraryModel.copy` does), else a webp's public
    /// link. The Mac saves with a panel in the UI and does not call this.
    public func saveToPhotos(_ rendition: Rendition) async throws {
        let fm = FileManager.default
        var source: URL?
        var temporary = false
        if let url = rendition.local?.fileURL, fm.fileExists(atPath: url.path) { source = url }
        do {
            if source == nil {
                if let file = rendition.file {
                    (source, temporary) = try await library.copy(file)
                } else if rendition.isWebp, let url = rendition.publicURL {
                    let name = url.lastPathComponent.isEmpty ? "rendition.webp" : url.lastPathComponent
                    source = try await ctx.client.download(.open(url), to: ctx.store.inboxURL(for: name), progress: { _ in })
                    temporary = true
                }
            }
            guard let file = source else { throw PipelineFailure.unsupported }
            defer { if temporary { try? fm.removeItem(at: file) } }
            let type = UTType(filenameExtension: file.pathExtension.lowercased())
            let isImage = rendition.isWebp || (type?.conforms(to: .image) ?? false)
            try await ctx.savePhoto(fileURL: file, isImage: isImage, key: photosKey(of: rendition))
        } catch {
            if let mapped = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) { throw mapped }
            throw error
        }
    }

    // MARK: - Removing

    /// "remove from this iphone": every local record of the media goes, the server keeps its copies.
    /// False (nothing removed) when a rendition is in use.
    @discardableResult
    public func removeFromDevice(_ item: MediaItem) async -> Bool {
        guard let local = item.local else { return false }
        return await store.removeMedia(local.id)
    }

    /// True while this device runs something for the media: the focus (any run on a session of the
    /// media, or aimed at it), a detached render or a keep-original on one of its sessions.
    /// `delete everything` is disabled meanwhile (the server's 409 covers runs started elsewhere).
    public func isBusy(_ item: MediaItem) -> Bool {
        let localID = item.local?.id
        var sessions = item.local?.sessionIDs ?? []
        if let post = item.post {
            sessions.insert(post.id)
            if let id = post.session?.id { sessions.insert(id) }
        }
        let storedIDs = Set(item.local?.renditions.map(\.id) ?? [])
        func relates(_ p: Pipeline) -> Bool {
            if let localID, p.targetMediaID == localID { return true }
            if let sid = p.sessionID, sessions.contains(sid) { return true }
            if let stored = p.stored, storedIDs.contains(stored.id) { return true }
            return false
        }
        if relates(pipeline) {
            if case .idle = pipeline.state {
                if pipeline.keepRequest != nil || pipeline.hostRequest != nil { return true }
            } else {
                return true
            }
        }
        return ctx.background.runs.contains { relates($0) }
    }

    // MARK: - Deleting

    /// One webp: on the server when it has a deletable name (`DELETE /media/<name>`, then `library`
    /// drops the file), and the local record. A webp with no name only leaves this device ("remove
    /// this webp from this iphone"). A webp the server already no longer has counts as deleted.
    public func deleteWebp(_ rendition: Rendition, of item: MediaItem) async throws {
        guard rendition.isWebp else { throw PipelineFailure.unsupported }
        if let name = rendition.deletableName {
            try await deleteOnServer(name)
            if let file = rendition.file { library.drop(files: [file.id]) }
        }
        if let local = rendition.local { await store.remove(local.id) }
    }

    /// `delete everything` (CONTRACT-MEDIA 1.12): the whole media for everyone.
    /// (b) when `capabilities.deletePost` and the item has a post: one call,
    /// `client.deletePost(anchor: post.files.first.id)`. (a) otherwise: `deleteMedia(name:)` for every
    /// webp with a deletable name, one at a time. Local records are removed for every rendition the
    /// server confirmed gone; on (b) `.done` the whole local media goes (`store.removeMedia`) and
    /// `library` drops the post. Throws `PipelineFailure.serverBusy` for the server's 409 and the
    /// mapped failure when no answer came; never throws for a partial result. The Photos album and its
    /// ledger are never touched: what is in Photos stays, and is never added again.
    public func deleteEverything(_ item: MediaItem) async throws -> DeleteOutcome {
        if capabilities.deletePost, let post = item.post, let anchor = post.files.first?.id {
            return try await deleteWholePost(item, post: post, anchor: anchor)
        }
        return try await deleteWebpsOnly(item)
    }

    private func deleteWholePost(_ item: MediaItem, post: LibraryPost, anchor: String) async throws -> DeleteOutcome {
        let result: PostDeleteResult
        do {
            result = try await ctx.client.deletePost(anchor: anchor)
        } catch PipelineFailure.expired {
            result = PostDeleteResult(deletedFiles: 0, deletedBytes: 0, remaining: [])    // already gone
        } catch {
            throw failure(from: error)
        }
        let remaining = Set(result.remaining)
        if remaining.isEmpty {
            library.drop(post: post.id)
            if let local = item.local, !(await store.removeMedia(local.id)) {
                for record in local.renditions where !store.isInUse(record.id) { await store.remove(record.id) }
            }
            return .done
        }
        // Partial: what the server confirmed gone leaves this device too; the rest stays on the tabs.
        library.drop(files: Set(post.files.map(\.id)).subtracting(remaining))
        for rendition in item.renditions {
            let ids = Set(rendition.serverFileIDs)
            guard !ids.isEmpty, ids.isDisjoint(with: remaining), let local = rendition.local else { continue }
            await store.remove(local.id)
        }
        return .partial(remaining: result.remaining.count)
    }

    private func deleteWebpsOnly(_ item: MediaItem) async throws -> DeleteOutcome {
        var remaining = 0
        for webp in item.webps {
            guard let name = webp.deletableName else {
                if webp.file != nil || webp.publicURL != nil { remaining += 1 }       // on the server, no way to delete it
                continue
            }
            do {
                try await deleteOnServer(name)
            } catch {
                let mapped = failure(from: error)
                if let f = mapped as? PipelineFailure, f == .keyInvalid || f == .keyMissing { throw f }
                remaining += 1
                continue
            }
            if let file = webp.file { library.drop(files: [file.id]) }
            if let local = webp.local { await store.remove(local.id) }
        }
        if remaining > 0 { return .partial(remaining: remaining) }
        let video = item.video
        let hostedLink = video?.publicURL != nil
        let privateCopy = video?.file != nil || (item.post == nil && video?.local?.sessionID != nil)
        return hostedLink || privateCopy ? .leftOnServer(hostedLink: hostedLink, privateCopy: privateCopy) : .done
    }

    /// `DELETE /media/<name>`; a webp the server no longer has (404) is as good as deleted.
    private func deleteOnServer(_ name: String) async throws {
        do {
            try await ctx.client.deleteMedia(name: name)
        } catch CobaltError.api(_, 404) {
            return
        } catch CobaltError.invalidResponse(404) {
            return
        } catch {
            throw failure(from: error)
        }
    }

    /// The failure a screen can word; a revoked key is told to the app, as every other call does.
    private func failure(from error: Error) -> Error {
        let mapped = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        if let f = mapped as? PipelineFailure, f == .keyInvalid { markKeyInvalid() }
        return mapped
    }
}
