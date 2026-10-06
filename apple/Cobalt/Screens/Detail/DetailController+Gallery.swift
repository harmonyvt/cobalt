import CobaltKit
import Foundation

/// What the gallery detail does and asks about (CONTRACT-GALLERY 1.18-1.20): which page of the pager is shown, `select
/// photos`, the switch of the whole post, saving some or all to Photos on request, copying links and text, deleting one
/// photo or one made file, trying a missing photo again, and `make a webp` of a video item. The actions go to `AppModel`
/// (CONTRACT-GALLERY.A0-API.md section 7); the model's answer is what the screen shows next. Nothing is faked.
extension DetailController {
    // MARK: - pages and tabs

    /// The page of the pager on screen; nil on a made file's tab (and for a media with no pager).
    func currentPage(in item: MediaItem) -> GalleryPage? {
        guard item.detailShape != .classic else { return nil }
        let pages = item.galleryPages
        guard !pages.isEmpty else { return nil }
        // a tab of a made file or a webp (a rendition that is not one of the pages) is not the pager
        if let selectedID, let r = item.rendition(id: selectedID), !r.isItem, !pages.contains(where: { $0.rendition?.id == r.id }) {
            return nil
        }
        let wanted = pageIndex ?? selectedID.flatMap { item.rendition(id: $0)?.itemIndex } ?? pages[0].index
        return pages.first { $0.index >= wanted } ?? pages.last
    }

    /// The rendition the rows under the hero are about: the page's file, a made file, or (on a page that was never saved)
    /// the first item, which only stands in for the rows that need some file.
    func galleryRendition(in item: MediaItem) -> Rendition {
        if let page = currentPage(in: item) { return page.rendition ?? item.items.first ?? item.renditions[0] }
        if let selectedID, let r = item.rendition(id: selectedID) { return r }
        return item.items.first ?? item.renditions[0]
    }

    /// The tab that is selected: `items` for the pager, else the rendition's id.
    func tabID(in item: MediaItem) -> String {
        if item.detailShape != .classic, currentPage(in: item) != nil { return DetailTab.items }
        return selected(in: item).id
    }

    func selectTab(_ id: String, in item: MediaItem) {
        guard item.detailShape != .classic else { select(id); return }
        guard id == DetailTab.items else { select(id); return }
        guard currentPage(in: item) == nil else { return }
        selectedID = nil
        notice = nil
        flash = nil
        endSelecting()
        if phase == .failed, retry != .deleteEverything { phase = .idle; retry = nil }
    }

    func selectPage(_ index: Int, in item: MediaItem) {
        pageIndex = index
        selectedID = item.items.first { $0.itemIndex == index }?.id
        notice = nil
        flash = nil
        if phase == .failed, retry != .deleteEverything { phase = .idle; retry = nil }
    }

    /// The next (`+1`) or the previous (`-1`) page, if there is one.
    func movePage(_ delta: Int, in item: MediaItem) {
        let pages = item.galleryPages
        guard let page = currentPage(in: item), let at = pages.firstIndex(where: { $0.index == page.index }) else { return }
        let to = at + delta
        guard pages.indices.contains(to) else { return }
        selectPage(pages[to].index, in: item)
    }

    // MARK: - select photos

    func beginSelecting(with index: Int? = nil) {
        selecting = true
        picked = index.map { [$0] } ?? []
        flash = nil
        notice = nil
    }

    func endSelecting() {
        selecting = false
        picked = []
    }

    func toggle(_ index: Int) {
        if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
    }

    /// The ticked photos that exist, in the post's order.
    func pickedRenditions(in item: MediaItem) -> [Rendition] {
        item.items.filter { r in r.itemIndex.map { picked.contains($0) } ?? false }
    }

    // MARK: - words

    /// A neutral line under the actions for a moment.
    func say(_ text: String) {
        notice = nil
        flash = text
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if flash == text { flash = nil }
        }
    }

    // MARK: - Photos, on request

    /// `save all to photos` (every item of the post) or the ticked ones.
    func saveToPhotos(_ renditions: [Rendition], of item: MediaItem) async {
        guard batchPhotos != .working, !renditions.isEmpty else { return }
        notice = nil
        flash = nil
        batchPhotos = .working
        do {
            try await RenditionPhotos.save(renditions, of: item, model: model)
            batchPhotos = .done
            #if os(macOS)
            say(DetailWords.savedToFolder(renditions.count))
            #else
            say(DetailWords.savedToPhotos(renditions.count))
            #endif
            endSelecting()
        } catch {
            batchPhotos = .idle
            notice = Self.words(error)
            return
        }
        try? await Task.sleep(for: .seconds(1.8))
        batchPhotos = .idle
    }

    // MARK: - the switch of the whole post (one switch, CONTRACT-GALLERY 1.19)

    /// The post's files that have a link right now.
    func publicLinks(of item: MediaItem) -> Int {
        (item.items + item.made).filter { $0.isPublic && $0.publicURL != nil }.count
    }

    func isPostPublic(_ item: MediaItem) -> Bool { (item.items + item.made).contains { $0.isPublic } }

    /// The post has a switch: the server takes it (`features.gallery` and `visibility`) and there is a file to ask it by.
    func canSwitchPost(_ item: MediaItem) -> Bool {
        model.capabilities.gallery && model.capabilities.visibility && ((item.items.first?.file ?? item.post?.files.first) != nil)
    }

    /// Turns every link of the post on or off. The model puts the library's files where the server says; a partial answer
    /// (some files switched, some not) is said in words and the same switch again finishes it.
    func setPostPublic(_ on: Bool, for item: MediaItem) async {
        guard postVisibility != .working else { return }
        visibilityFailed[Self.postKey] = nil
        visibilityCacheNote.remove(Self.postKey)
        postVisibility = .working
        defer { postVisibility = .idle }
        do {
            let change = try await model.setPublic(on, for: item)
            if !on, change.cacheCleared == false { visibilityCacheNote.insert(Self.postKey) }
        } catch {
            if let failure = error as? PipelineFailure, [.keyInvalid, .keyMissing, .unreachable].contains(failure) {
                visibilityFailed[Self.postKey] = Copy.failure(failure)
            } else if (error as? PipelineFailure) == .server(code: "error.library.partial") {
                visibilityFailed[Self.postKey] = DetailWords.partialSwitch(on: on)
            } else {
                visibilityFailed[Self.postKey] = on ? Copy.Media.makeLinkFailed : Copy.Media.turnOffFailed
            }
        }
    }

    /// The key the post's switch uses in `visibilityFailed` and `visibilityCacheNote`.
    static let postKey = "post"

    // MARK: - links and text

    func copyAllLinks(_ item: MediaItem) {
        let text = model.copyAllLinks(item)
        guard !text.isEmpty else {
            say(DetailWords.noLinks)
            return
        }
        Pasteboard.copy(text)
        copiedID = nil
        say(DetailWords.copiedLinks(text.split(separator: "\n").count))
    }

    /// `copy text`: the words in the photo, read on the device.
    func copyText(of r: Rendition) async {
        guard readingText == nil else { return }
        notice = nil
        flash = nil
        readingText = r.id
        defer { readingText = nil }
        var source: URL?
        if let url = r.local?.fileURL, FileManager.default.fileExists(atPath: url.path) {
            source = url
        } else if let file = r.file {
            source = try? await model.library.localCopy(file)
        }
        guard let source else {
            notice = DetailWords.noPhotoFile
            return
        }
        let text = await PhotoText.read(source)
        if text.isEmpty {
            say(DetailWords.noText)
        } else {
            Pasteboard.copy(text)
            say(DetailWords.copiedText)
        }
    }

    // MARK: - a photo that was never saved

    /// `try photo 7 again`: the server fetches the post's missing items once more; each lands here as it is stored. The
    /// page says it is fetching until the library lists the photo (the view prunes `retrying` against `item.missing`).
    func retryMissing(_ item: MediaItem) async {
        let missing = Set(item.missing)
        guard !missing.isEmpty, retrying.isDisjoint(with: missing) else { return }
        notice = nil
        retrying.formUnion(missing)
        do {
            try await model.retryMissing(item)
        } catch {
            retrying.subtract(missing)
            notice = Self.words(error)
            return
        }
        // a safety net: a fetch that never lands (the job failed) gives the button back
        try? await Task.sleep(for: .seconds(90))
        retrying.subtract(missing)
    }

    // MARK: - convert to webp, per video or gif item

    /// The server can make a webp of this item: the post's session is open (or this device holds the session), and the
    /// item's file is here or on the server.
    func canMakeWebp(ofItem r: Rendition, in item: MediaItem) -> Bool {
        guard model.capabilities.gallery, model.capabilities.studio, r.isMotionItem else { return false }
        guard r.local?.fileURL != nil || r.file != nil else { return false }
        if let session = item.post?.session { return session.status == .ready && session.expiresAt > Date() }
        return item.post != nil || item.local?.sessionIDs.first != nil
    }

    /// Opens the focus on this item with the trim ready (today's flow). False (and a line) when the model refuses.
    func makeWebp(ofItem r: Rendition, in item: MediaItem) -> Bool {
        guard let index = r.itemIndex else { return false }
        if model.makeWebp(for: item, itemIndex: index) { return true }
        notice = DetailWords.cantMakeWebp
        return false
    }

    // MARK: - make from this post (lane A2's combine sheet)

    enum MakeAvailability: Equatable { case ready, serverCant, expired, needsTwo }

    func makeAvailability(_ item: MediaItem) -> MakeAvailability {
        guard model.capabilities.gallery, model.capabilities.galleryMake else { return .serverCant }
        guard item.items.count >= 2 else { return .needsTwo }
        if let session = item.post?.session {
            return session.status == .ready && session.expiresAt > Date() ? .ready : .expired
        }
        return item.post == nil ? .ready : .expired
    }

    // MARK: - deleting one photo, some photos, one made file

    /// `delete this photo` / `delete 3` for everyone (`DELETE /library/items/<id>`, one by one). The made files and the other
    /// photos stay; the last photo is refused (delete everything instead).
    func deletePhotos(_ indices: [Int], of item: MediaItem) async {
        guard phase != .deleting, !indices.isEmpty else { return }
        retry = indices.count == 1 ? .deletePhoto(indices[0]) : .deletePhotos(indices)
        notice = nil
        flash = nil
        exitStatus = nil
        phase = .deleting
        if failsDeletes {
            try? await Task.sleep(for: .milliseconds(700))
            phase = .failed
            return
        }
        do {
            try await model.deleteItems(indices, of: item)
            phase = .idle
            retry = nil
            endSelecting()
        } catch {
            if (error as? PipelineFailure) == .server(code: "error.library.last_item") {
                phase = .idle
                retry = nil
                notice = DetailWords.lastPhoto
            } else {
                phase = Self.isBusy(error) ? .busy : .failed
            }
        }
    }

    /// `delete this file`: a slideshow, a gallery image or a crop, for everyone. The photos stay.
    func deleteMade(_ r: Rendition, of item: MediaItem) async {
        guard phase != .deleting else { return }
        retry = .deleteMade(r.id)
        notice = nil
        flash = nil
        exitStatus = nil
        phase = .deleting
        if failsDeletes {
            try? await Task.sleep(for: .milliseconds(700))
            phase = .failed
            return
        }
        do {
            try await model.deleteMade(r, of: item)
            phase = .idle
            retry = nil
            if selectedID == r.id { selectedID = nil }
        } catch {
            phase = Self.isBusy(error) ? .busy : .failed
        }
    }
}
