import CobaltKit
import SwiftUI

/// What a tap opened on the phone: the media as it was then (the detail keeps itself current) and the tab
/// to start on.
struct OpenedMedia: Identifiable, Hashable {
    let item: MediaItem
    let initial: Rendition.ID?

    var id: String { "\(item.id)|\(initial ?? "")" }
    static func == (a: OpenedMedia, b: OpenedMedia) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// "open in library" asked for this post to be shown (the token makes the same post a new request).
struct LibraryReveal: Equatable {
    let id: String
    let token = UUID()
}

extension LibraryRow {
    /// Whether select mode can tick it. Galleries are not shared, so they cannot be ticked.
    var shareable: Bool { kind != .gallery }
}

/// One row of the card shown while ticked posts are being copied for the share sheet.
struct SharePrepRow: Identifiable, Equatable {
    enum State: Equatable {
        /// Already a file on this device: nothing to download.
        case onDevice
        case waiting, downloading, ready, skipped

        var done: Bool { self == .onDevice || self == .ready || self == .skipped }
    }

    /// What the shared file is. Galleries are never shared, so never a row here.
    enum Kind: Equatable {
        case video, photo, webp
    }

    let id: String
    var title: String
    /// For the card's thumbnail.
    var item: MediaItem
    var kind: Kind
    /// The video's length, when the file is a video.
    var length: Double?
    var state: State

    init(_ row: LibraryRow, state: State) {
        id = row.id
        title = row.title
        item = row.item
        self.state = state
        if row.item.face.isWebp {
            kind = .webp
        } else if row.originalIsImage || row.kind == .photo {
            kind = .photo
        } else {
            kind = .video
        }
        length = kind == .video && row.length > 0 ? row.length : nil
    }
}

/// The library screen's state and what its menus do: what is opened (a push on the phone, the inspector on the
/// iPad and Mac), what is lit, select mode for the posts on screen, the rename and delete in progress, and each
/// action of the context menu. One per screen; the views read the parts they draw, so a lit tile never re-evaluates
/// the table.
@MainActor @Observable
final class LibraryController {
    let model: AppModel

    /// The phone's pushed detail.
    var opened: OpenedMedia?
    /// The row the inspector shows (iPad, Mac).
    var selection: String?
    /// The inspector's open state (remembered per device once the owner or the width decides).
    var inspectorOpen: Bool {
        didSet { if inspectorOpen != oldValue { Self.defaults.set(inspectorOpen, forKey: Self.inspectorKey); decided = true } }
    }
    /// The post "open in library" lit, for 1.6 s.
    var lit: String?
    var reveal: LibraryReveal?
    /// The trailing checkbox: taps tick posts instead of opening them.
    var selecting = false
    /// Ticked posts (`LibraryRow.id`). Kept across a re-enter; `endSelecting` clears it.
    var picked: Set<String> = []
    /// A share of the ticked posts is copying files. A second tap while this is set does nothing.
    var preparingShare = false
    /// A share link is being made (`make share link`). A second tap while this is set does nothing.
    var makingShareLink = false
    /// Bumped when a share link was made and copied: the success haptic.
    var shareLinksMade = 0
    /// Bumped when a copy, a save, a visibility switch or a delete lands (success haptic), half lands (warning) or
    /// fails (error).
    var doneTick = 0
    var warnTick = 0
    var failTick = 0
    /// What the share card lists while `preparingShare` is set. Cleared when the copy finishes.
    var sharePrep: [SharePrepRow] = []
    /// The card's `cancel`: the copy stops before the next post and no sheet opens.
    var shareCancelled = false
    /// Bumped by a refresh: a tile whose picture failed tries again.
    var reload = 0
    var renaming: MediaItem?
    var deleting: MediaItem?
    /// The media whose video the owner is turning private (the confirm: its link stops working for everyone).
    var makingPrivate: MediaItem?
    /// The gallery the owner chose `make from this post…` for: the combine sheet is open on it (`LibraryCombineSheet`).
    var combining: MediaItem?

    /// True on the phone layout (a push); false where the detail is an inspector.
    @ObservationIgnored var compact = true
    /// Set once the owner (or the width, the first time) has decided the inspector's state.
    @ObservationIgnored private(set) var decided: Bool
    /// The shell's status line (`ShellActions.showStatus`), set by the screen.
    @ObservationIgnored var showStatus: @MainActor (String) -> Void = { _ in }

    private static let inspectorKey = "library.inspector"
    private static let defaults = UserDefaults.standard

    init(model: AppModel) {
        self.model = model
        if let stored = Self.defaults.object(forKey: Self.inspectorKey) as? Bool {
            inspectorOpen = stored
            decided = true
        } else {
            inspectorOpen = false
            decided = false
        }
    }

    var library: LibraryModel { model.library }

    /// The first time, an iPad in landscape or a normal Mac window opens the inspector (decision 15).
    func decideInspector(width: CGFloat) {
        guard !decided, !compact else { return }
        decided = true
        if width >= 1100 { inspectorOpen = true }
    }

    // MARK: opening

    /// A tap: the phone pushes the detail on the media's face; the iPad and Mac select it in the inspector.
    func open(_ row: LibraryRow) {
        open(row.item, initial: row.item.face.id)
    }

    /// Opens the detail of `item` on the tab `initial` (the phone pushes it; the iPad and Mac select it).
    func open(_ item: MediaItem, initial: Rendition.ID?) {
        if compact {
            opened = OpenedMedia(item: item, initial: initial)
        } else {
            selection = item.post?.id ?? item.id
            inspectorOpen = true
        }
    }

    /// The media the inspector shows: the loaded post whatever the filter says (else the post a search returned).
    var selectedItem: MediaItem? {
        guard let id = selection, let post = library.post(id: id) else { return nil }
        return model.mediaItem(for: post)
    }

    func light(_ id: String) {
        lit = id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lit == id { lit = nil }
        }
    }

    // MARK: select mode

    /// Starts select mode. Does not clear `picked`: ending is what empties it, so a fresh enter starts empty
    /// and a second call while already selecting keeps the ticks.
    func beginSelecting() {
        selecting = true
    }

    func endSelecting() {
        selecting = false
        picked = []
    }

    /// Ticks or unticks one post. A gallery cannot be ticked: galleries are not shared.
    func togglePick(_ row: LibraryRow) {
        guard row.shareable else { return }
        if picked.contains(row.id) { picked.remove(row.id) } else { picked.insert(row.id) }
    }

    /// Ticks every post on screen that can be shared (the kind chip, the search and the show filter decide which), or
    /// clears them all when every one is already ticked.
    func toggleAll(_ rows: [LibraryRow]) {
        let ids = Set(rows.filter(\.shareable).map(\.id))
        if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) }
    }

    /// Select mode with exactly these posts ticked: a kind chip's `select all` / `share all`.
    func pickOnly(_ rows: [LibraryRow]) {
        selecting = true
        picked = Set(rows.filter(\.shareable).map(\.id))
    }

    /// Local files for the ticked posts, in `rows` order. One file per picked row: that row's face only
    /// (never a gallery, not `post.link`, never `publicURL`). One download at a time.
    /// The URL `localCopy` returns is kept — deleting it can destroy the only copy.
    /// Empty means nothing could be shared (`Copy.actionFailed` is already shown). `[]` while a share is
    /// already being prepared: the caller does nothing.
    func sharePicked(_ rows: [LibraryRow]) async -> [URL] {
        guard !preparingShare else { return [] }
        preparingShare = true
        let chosen = picked
        let rows = rows.filter(\.shareable)
        shareCancelled = false
        sharePrep = rows.filter { chosen.contains($0.id) }.map { SharePrepRow($0, state: Self.shareState(of: $0.item.face)) }
        defer {
            preparingShare = false
            sharePrep = []
        }
        var urls: [URL] = []
        for row in rows where chosen.contains(row.id) {
            // `cancel` on the card: nothing is shared (what already downloaded stays as the cache's)
            if shareCancelled { return [] }
            let face = row.item.face
            if let url = face.local?.fileURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                setShareState(row.id, .onDevice)
                urls.append(url)
                continue
            }
            setShareState(row.id, .downloading)
            guard let file = face.file else {
                setShareState(row.id, .skipped)
                continue
            }
            do {
                let copied = try await model.library.localCopy(file)
                guard copied.isFileURL else {
                    setShareState(row.id, .skipped)
                    continue
                }
                setShareState(row.id, .ready)
                urls.append(copied)
            } catch {
                setShareState(row.id, .skipped)
                continue
            }
        }
        if shareCancelled { return [] }
        if urls.isEmpty { showStatus(Copy.actionFailed); failTick += 1 }
        return urls
    }

    // MARK: gallery share link (APP-API-CONTRACT 24)

    /// The picked posts that are on screen (`rows` order) with the public library file that stands for each, nil when
    /// the post has no public file. What the select bar's verdict and the button both read, so they cannot disagree.
    func shareLinkPicks(_ rows: [LibraryRow]) -> [(row: LibraryRow, fileID: String?)] {
        rows.filter { $0.shareable && picked.contains($0.id) }.map { ($0, ShareSetRule.fileID(for: $0.item)) }
    }

    func shareLinkVerdict(_ rows: [LibraryRow]) -> ShareSetVerdict {
        ShareSetRule.verdict(
            publicFlags: shareLinkPicks(rows).map { $0.fileID != nil }, max: model.capabilities.limits.shareSetMax)
    }

    /// Makes one link for the picked posts and copies it. True when it was made (the caller leaves select mode).
    /// A second call while one runs does nothing. `.notPublic` says so; any other failure is the generic one.
    func makeShareLink(_ rows: [LibraryRow]) async -> Bool {
        guard !makingShareLink, shareLinkVerdict(rows) == .ready else { return false }
        let ids = shareLinkPicks(rows).compactMap(\.fileID)
        makingShareLink = true
        defer { makingShareLink = false }
        do {
            let set = try await model.shareSets.create(items: ids, title: nil)
            Pasteboard.copy(set.url.absoluteString)
            showStatus(Copy.Media.copied)
            shareLinksMade += 1
            return true
        } catch ShareSetError.notPublic {
            showStatus(Copy.Links.makeThesePublic)
            warnTick += 1
        } catch {
            showStatus(Copy.actionFailed)
            failTick += 1
        }
        return false
    }

    private func setShareState(_ id: String, _ state: SharePrepRow.State) {
        guard let index = sharePrep.firstIndex(where: { $0.id == id }) else { return }
        sharePrep[index].state = state
    }

    private static func shareState(of face: Rendition) -> SharePrepRow.State {
        if let url = face.local?.fileURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return .onDevice
        }
        return .waiting
    }

    // MARK: the menu's questions

    /// The newest public webp's link.
    func webpLink(_ item: MediaItem) -> URL? { item.webps.last(where: { $0.publicURL != nil })?.publicURL }

    /// The hosted video's link.
    func videoLink(_ item: MediaItem) -> URL? { item.video?.hosted?.url ?? item.video?.publicURL }

    /// The face's public link, else its file on this device.
    func shareURL(_ item: MediaItem) -> URL? {
        let face = item.face
        if let url = face.publicURL { return model.capabilities.shareLink(for: url) }
        if let url = face.local?.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
    }

    /// `save to photos` of one file: a video, a webp, or a single photo. A gallery has `save all to photos` instead.
    func canSave(_ item: MediaItem) -> Bool { item.kind != .gallery && RenditionPhotos.canSave(item.face) }

    /// A photo or a gallery: what the media holds is its items, not a video.
    func holdsItems(_ item: MediaItem) -> Bool { item.video == nil && !item.items.isEmpty }

    /// `copy photo link`: a single photo's public link.
    func photoLink(_ item: MediaItem) -> URL? { item.kind == .photo ? item.face.publicURL : nil }

    /// `copy all links` is offered for a gallery with at least one public link (items, then what was made).
    func canCopyAllLinks(_ item: MediaItem) -> Bool {
        item.kind == .gallery && !model.copyAllLinks(item).isEmpty
    }

    /// `save all to photos` (owner-asked only; the Mac has no Photos sync, its folder is in Finder): a gallery's items.
    func canSaveAll(_ item: MediaItem) -> Bool {
        #if os(iOS)
        item.kind == .gallery && item.items.contains { RenditionPhotos.canSave($0) }
        #else
        false
        #endif
    }

    /// `make from this post…`: a gallery of 2+ items on a server that makes things.
    func canMakeFromPost(_ item: MediaItem) -> Bool {
        item.kind == .gallery && item.itemCount >= 2 && model.capabilities.gallery && model.capabilities.galleryMake
    }

    /// "make public" / "make private…": the server takes the switch for this media's video (the same switch the
    /// detail has; a webp's is on its tab there). A photo or gallery has the post's switch (`AppModel.setPublic`).
    func canSwitchVisibility(_ item: MediaItem) -> Bool {
        guard model.capabilities.visibility else { return false }
        if let video = item.video { return video.canToggleVisibility }
        return holdsItems(item) && item.items.contains { $0.canToggleVisibility }
    }

    /// `delete everything` is offered when the media has something on the server and a way to delete it
    /// (the keyed post route, or a webp the older route can take); plain cobalt has neither.
    func canDelete(_ item: MediaItem) -> Bool {
        guard item.hasServerCopy else { return false }
        return usesPostRoute(item) || item.webps.contains { $0.deletableName != nil }
    }

    func usesPostRoute(_ item: MediaItem) -> Bool { model.capabilities.deletePost && item.post != nil }

    func isBusy(_ item: MediaItem) -> Bool { model.isBusy(item) }

    /// The confirm's message (CONTRACT-MEDIA 1.12): what exists, for everyone, or on an older server only the webps.
    func deleteMessage(_ item: MediaItem) -> String {
        if usesPostRoute(item), holdsItems(item) {
            return Copy.Library2.deleteGalleryMessage(items: item.itemCount, made: item.made.count)
        }
        if usesPostRoute(item) {
            let video = item.video
            let hosted = video?.hosted != nil || video?.publicURL != nil
            return Copy.Media.deleteEverythingMessage(video: video != nil, hosted: hosted, webps: item.webpCount)
        }
        return Copy.Media.deleteEverythingFallbackMessage(webps: item.webps.filter { $0.deletableName != nil }.count)
    }

    /// The rename alert's extra line: a fork without `features.titles` keeps the name on this device only.
    func renameIsLocalOnly(_ item: MediaItem) -> Bool {
        model.capabilities.library && !model.capabilities.titles && item.post != nil
    }

    // MARK: actions

    func copy(_ url: URL) {
        Pasteboard.copy(model.capabilities.shareLink(for: url).absoluteString)
        showStatus(Copy.Media.copied)
        doneTick += 1
    }

    /// The video's link on or off, said in the shell's status line. Off asks first (`makingPrivate`); the library's
    /// file flips at once and goes back when the server says no (`AppModel.setVisibility`).
    func setVisibility(_ item: MediaItem, public makePublic: Bool) {
        let video = item.video
        guard video != nil || holdsItems(item) else { return }
        Task {
            if makePublic { showStatus(Copy.Library2.makingPublic) }
            do {
                var cacheCleared: Bool?
                if let video {
                    cacheCleared = try await model.setVisibility(video, public: makePublic).cacheCleared
                } else {
                    cacheCleared = try await model.setPublic(makePublic, for: item).cacheCleared
                }
                doneTick += 1
                if makePublic {
                    showStatus(Copy.Library2.nowPublic)
                } else {
                    showStatus(cacheCleared == false ? "\(Copy.Library2.nowPrivate) \(Copy.Media.cacheNote)" : Copy.Library2.nowPrivate)
                }
            } catch {
                showStatus(makePublic ? Copy.Media.makeLinkFailed : Copy.Media.turnOffFailed)
                failTick += 1
            }
        }
    }

    func save(_ item: MediaItem) {
        Task {
            do {
                let face = item.face
                #if os(iOS)
                if face.isItem || face.isMade {
                    try await model.saveToPhotos([face], of: item)      // records the gallery file's ledger key
                } else {
                    try await RenditionPhotos.save(face, model: model)
                }
                #else
                try await RenditionPhotos.save(face, model: model)
                #endif
                #if os(iOS)
                showStatus(Copy.savedPhotos)
                #endif
                doneTick += 1
            } catch {
                showStatus(Self.words(error))
                failTick += 1
            }
        }
    }

    /// `save all to photos`: every item of the gallery, only because the owner asked (iPhone and iPad).
    func saveAll(_ item: MediaItem) {
        #if os(iOS)
        Task {
            do {
                try await model.saveToPhotos(item.items.filter { RenditionPhotos.canSave($0) }, of: item)
                showStatus(Copy.savedPhotos)
                doneTick += 1
            } catch {
                showStatus(Self.words(error))
                failTick += 1
            }
        }
        #endif
    }

    /// `copy all links`: the public links of the items and of what was made, one a line.
    func copyAllLinks(_ item: MediaItem) {
        let text = model.copyAllLinks(item)
        guard !text.isEmpty else {
            showStatus(Copy.Library2.noPublicLinks)
            warnTick += 1
            return
        }
        Pasteboard.copy(text)
        showStatus(Copy.Library2.copiedLinks(text.split(separator: "\n").count))
        doneTick += 1
    }

    /// `make from this post…`: the combine sheet on this gallery.
    func makeFromPost(_ item: MediaItem) {
        combining = item
    }

    /// `delete everything` after the confirm, with the outcomes of the detail's (CONTRACT-MEDIA 1.12).
    func deleteEverything(_ item: MediaItem) {
        Task {
            if model.isBusy(item) {
                showStatus(Copy.Media.deleteBusy)
                warnTick += 1
                return
            }
            showStatus(Copy.Media.deleting)
            do {
                switch try await model.deleteEverything(item) {
                case .done:
                    showStatus(Copy.Media.deleted)
                    doneTick += 1
                    if let id = item.post?.id, selection == id { selection = nil }
                case .partial(let remaining):
                    showStatus(Copy.Media.deletePartial(remaining: remaining))
                    warnTick += 1
                case .leftOnServer:
                    showStatus(Copy.Media.stillOnServer)
                    warnTick += 1
                }
            } catch {
                showStatus((error as? PipelineFailure) == .serverBusy ? Copy.Media.deleteBusy : Copy.Media.deleteFailed)
                failTick += 1
            }
        }
    }

    /// A button's failure in plain words.
    static func words(_ error: Error) -> String {
        if let failure = error as? PipelineFailure { return Copy.failure(failure) }
        return Copy.actionFailed
    }

    // MARK: loading

    /// The next page near the end of the list (the whole-library modes already load everything).
    func loadMoreIfNeeded() {
        guard !library.needsWholeLibrary else { return }
        Task { await library.loadMore() }
    }

    func refresh() async {
        await library.refresh()
        if library.needsWholeLibrary { await library.loadAll() }
        reload += 1
    }

    /// Pull to refresh: the spinner lets go at once and the page loads in place. Holding the gesture open for the
    /// network left the page hanging ~90 pt low under a blank band after a fling to the top (the owner's flicker).
    func pullToRefresh() {
        Task { await refresh() }
    }
}
