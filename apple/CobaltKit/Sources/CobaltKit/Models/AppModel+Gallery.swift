import Foundation

// What the detail and the combine sheet can do with a gallery media (apple/CONTRACT-GALLERY.md 1.15-1.20). The save of a
// pasted gallery and its first make live in `PipelineGallery.swift`; this file is the same work for a post that is
// already in the library: asking for a make, retrying missing items, deleting one item or one made file, switching a
// whole post public or private, copying its links, saving some of it to Photos on request.

extension AppModel {
    // MARK: - The post's items, as the plans need them

    /// The media's items as `GalleryItem`s (types, sizes, lengths, thumbs), in the post's order.
    public func galleryItems(of item: MediaItem) -> [GalleryItem] {
        item.items.compactMap { r in
            guard let index = r.itemIndex else { return nil }
            return GalleryItem(
                id: index, type: r.itemType ?? .photo, width: r.width, height: r.height,
                duration: r.itemType == .photo ? nil : r.duration, thumb: r.posterURL ?? r.local?.posterURL)
        }
    }

    /// The studio session a make from this media goes to: the post's open session; nil when the library lists none (it
    /// has expired) or the media is only on this device.
    func gallerySession(of item: MediaItem) -> LibrarySession? {
        guard let session = item.post?.session, session.status == .ready, session.expiresAt > ctx.clock.now() else { return nil }
        return session
    }

    // MARK: - Making

    /// Slideshow webp, slideshow mp4 or gallery image from this media's items (the combine sheet's `make`). The make is a
    /// job of the queue (`JobQueue.addGallery`): the tray shows it, closing the sheet never stops it, and its result
    /// joins this media as a tab and lands in its Files folder. When the media is the one a job already holds open (a
    /// gallery just pasted), the make goes to that job instead, after its save if it is still running (R7).
    ///
    /// Throws `.unsupported` on a server without `features.gallery_make`, `.expired` when the post's session is over (the
    /// server makes from its stored originals only while the session lives), and the cap that the plan breaks
    /// (`error.webp.too_long`, `error.studio.not_gallery`) before anything is sent.
    public func make(_ m: GalleryMake, from item: MediaItem) async throws {
        guard capabilities.gallery, capabilities.galleryMake else { throw PipelineFailure.unsupported }
        let items = galleryItems(of: item)
        switch m {
        case .slideshow(let plan):
            switch plan.check(items) {
            case .ok: break
            case .tooFew: throw PipelineFailure.server(code: "error.studio.not_gallery")
            case .tooLong, .tooMuchVideo: throw PipelineFailure.server(code: "error.webp.too_long")
            }
        case .image(let plan):
            guard plan.isPossible(in: items) else { throw PipelineFailure.server(code: "error.studio.too_few_photos") }
        }
        let sid = item.post?.session?.id ?? item.post?.id ?? item.local?.sessionIDs.first
        if let sid, let job = queue.galleryJob(session: sid) {
            await job.pipeline.make(m)
            return
        }
        guard let session = gallerySession(of: item) else { throw PipelineFailure.expired }
        let info = item.post.map {
            MediaInfo(name: item.titleText, duration: nil, width: $0.width, height: $0.height, bytes: nil, isImage: true)
        }
        queue.addGallery(
            .make(m), session: session.id, items: items, media: info, link: item.link ?? item.post?.link, mediaID: item.local?.id)
    }

    /// "try photo 7 again": the server fetches the items it could not, again; they are stored here as they land.
    public func retryMissing(_ item: MediaItem) async throws {
        guard capabilities.gallery else { throw PipelineFailure.unsupported }
        let missing = item.missing
        guard !missing.isEmpty else { return }
        guard let session = gallerySession(of: item) else { throw PipelineFailure.expired }
        var failures: [Int: String] = [:]
        for index in missing { failures[index] = "error.api.fetch.generic" }
        let info = MediaInfo(name: item.titleText, duration: nil, width: nil, height: nil, bytes: nil, isImage: true)
        queue.addGallery(
            .retry(missing), session: session.id, items: galleryItems(of: item), media: info,
            link: item.link ?? item.post?.link, mediaID: item.local?.id, failures: failures)
    }

    /// "make a webp" of one video or gif item (the detail's per-item button): the home tab, the focus on this media with the
    /// trim open on that item. The webp joins this media (`madeFrom: [index]`). False when the item is a photo, unknown, or
    /// has neither a copy here nor a library row to fetch it from.
    @discardableResult
    public func makeWebp(for item: MediaItem, itemIndex index: Int) -> Bool {
        guard capabilities.gallery, capabilities.studio,
              let rendition = item.items.first(where: { $0.itemIndex == index }), rendition.itemType != .photo,
              let sid = item.post?.session?.id ?? item.post?.id ?? item.local?.sessionIDs.first
        else { return false }
        let local = rendition.local?.fileURL
        guard local != nil || rendition.file != nil else { return false }
        let info = MediaInfo(
            name: item.titleText, duration: rendition.duration, width: rendition.width, height: rendition.height,
            bytes: rendition.bytes, isImage: false)
        selectedTab = .save
        pipeline.resume(session: sid, media: info, item: index, localFile: local, libraryItem: rendition.file?.id)
        pipeline.targetMediaID = item.local?.id
        return true
    }

    // MARK: - Deleting

    /// Deletes some items of the post for everyone (`DELETE /library/items/<id>`, one by one); each leaves this device
    /// too, Files copy included. The made files and the other items stay. Deleting the last item is refused
    /// (`error.library.last_item`: use `deleteEverything`); an item the server no longer has counts as deleted. A
    /// failure part-way throws after the ones that did go were dropped.
    public func deleteItems(_ indices: [Int], of item: MediaItem) async throws {
        let wanted = Set(indices)
        let live = item.items.filter { $0.itemIndex != nil }
        let targets = live.filter { wanted.contains($0.itemIndex ?? -1) }
        guard !targets.isEmpty else { return }
        if live.count - targets.count < 1 { throw PipelineFailure.server(code: "error.library.last_item") }
        for rendition in targets { try await deleteOne(rendition) }
    }

    /// Deletes one made file (a slideshow, a gallery image, a crop) for everyone; the items stay.
    public func deleteMade(_ rendition: Rendition, of item: MediaItem) async throws {
        guard rendition.isMade else { throw PipelineFailure.unsupported }
        try await deleteOne(rendition)
    }

    private func deleteOne(_ rendition: Rendition) async throws {
        if let file = rendition.file {
            do {
                try await ctx.client.deleteItem(file.id)
            } catch CobaltError.api(_, 404) {
                // already gone
            } catch CobaltError.invalidResponse(404) {
                // already gone
            } catch {
                let mapped = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
                if let f = mapped as? PipelineFailure, f == .keyInvalid { markKeyInvalid() }
                throw mapped
            }
            library.drop(files: [file.id])
        }
        if let local = rendition.local { await store.remove(local.id) }
    }

    // MARK: - Public or private, for the whole post

    /// Switches every public-able file of the post (`PATCH …/visibility {"scope": "post"}`). The files the server answers
    /// replace the library's; this device's records follow. A partial answer (`502 error.library.partial`) applies what
    /// switched and throws `error.library.partial`, and the same call again finishes it.
    @discardableResult
    public func setPublic(_ on: Bool, for item: MediaItem) async throws -> VisibilityResult {
        guard capabilities.gallery, capabilities.visibility else { throw PipelineFailure.unsupported }
        guard let anchor = item.items.first?.file?.id ?? item.post?.files.first?.id else { throw PipelineFailure.unsupported }
        let result: VisibilityResult
        do {
            result = try await ctx.client.setPostVisibility(anchor: anchor, public: on)
        } catch {
            let mapped = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
            if let f = mapped as? PipelineFailure, f == .keyInvalid { markKeyInvalid() }
            throw mapped
        }
        for file in result.files {
            library.replace(file: file)
            for local in store.videos where local.libraryID == file.id {
                store.setPublicURL(file.isPublic ? file.url : nil, forSession: nil, orEntry: local.id)
            }
        }
        if !result.remaining.isEmpty { throw PipelineFailure.server(code: "error.library.partial") }
        return result
    }

    // MARK: - Links

    /// Every public link of the post, one a line: the items in order, then what was made. Private files have none.
    public func copyAllLinks(_ item: MediaItem) -> String {
        (item.items + item.made).compactMap { $0.isPublic ? $0.publicURL?.absoluteString : nil }.joined(separator: "\n")
    }

    // MARK: - Photos (only on request)

    /// "save to photos" for some of the post's files (a photo, a selection, everything, a made file). Photos gets nothing
    /// unless the owner asks, here and in `saveToPhotos(_:)`. Each file's Photos ledger key is recorded (`g:<sid>:<n>` for
    /// an item, `m:<library id>` for a made file), so the album sync never adds it again and the buttons read "in your
    /// photos". The first failure stops the rest and throws; files saved before it stay saved.
    public func saveToPhotos(_ renditions: [Rendition], of item: MediaItem) async throws {
        for rendition in renditions {
            try await saveToPhotos(rendition, key: galleryPhotosKey(of: rendition, in: item))
        }
    }

    /// The ledger key of a gallery file: its local record's, else from the post.
    func galleryPhotosKey(of rendition: Rendition, in item: MediaItem) -> String? {
        if let local = rendition.local { return PhotosKey.of(local) }
        if let index = rendition.itemIndex, let sid = item.post?.id ?? item.local?.sessionIDs.first {
            return PhotosKey.item(session: sid, index: index)
        }
        if rendition.isMade, let id = rendition.file?.id { return PhotosKey.made(item: id) }
        return nil
    }

    /// Where a gallery file is in the owner's Photos.
    public func photosPlacement(of rendition: Rendition, in item: MediaItem) -> PhotosPlacement {
        guard let key = galleryPhotosKey(of: rendition, in: item) else { return .none }
        return ctx.photosPlacement(forKey: key)
    }
}
