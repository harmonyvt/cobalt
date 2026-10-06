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

/// The library screen's state and what its menus do: what is opened (a push on the phone, the inspector on the
/// iPad and Mac), what is lit, the rename and delete in progress, and each action of the context menu. One per
/// screen; the views read the parts they draw, so a lit tile never re-evaluates the table.
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
    /// Bumped by a refresh: a tile whose picture failed tries again.
    var reload = 0
    var renaming: MediaItem?
    var deleting: MediaItem?
    /// The media whose video the owner is turning private (the confirm: its link stops working for everyone).
    var makingPrivate: MediaItem?

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
        if compact {
            opened = OpenedMedia(item: row.item, initial: row.item.face.id)
        } else {
            selection = row.id
            inspectorOpen = true
        }
    }

    /// The media the inspector shows: the loaded post whatever the filter says.
    var selectedItem: MediaItem? {
        guard let id = selection, let post = library.posts.first(where: { $0.id == id }) else { return nil }
        return model.mediaItem(for: post)
    }

    func light(_ id: String) {
        lit = id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lit == id { lit = nil }
        }
    }

    // MARK: the menu's questions

    /// The newest public webp's link.
    func webpLink(_ item: MediaItem) -> URL? { item.webps.last(where: { $0.publicURL != nil })?.publicURL }

    /// The hosted video's link.
    func videoLink(_ item: MediaItem) -> URL? { item.video?.hosted?.url ?? item.video?.publicURL }

    /// The face's public link, else its file on this device.
    func shareURL(_ item: MediaItem) -> URL? {
        let face = item.face
        if let url = face.publicURL { return url }
        if let url = face.local?.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
    }

    func canSave(_ item: MediaItem) -> Bool { RenditionPhotos.canSave(item.face) }

    /// "make public" / "make private…": the server takes the switch for this media's video (the same switch the
    /// detail has; a webp's is on its tab there).
    func canSwitchVisibility(_ item: MediaItem) -> Bool {
        model.capabilities.visibility && (item.video?.canToggleVisibility ?? false)
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
        Pasteboard.copy(url.absoluteString)
        showStatus(Copy.Media.copied)
    }

    /// The video's link on or off, said in the shell's status line. Off asks first (`makingPrivate`); the library's
    /// file flips at once and goes back when the server says no (`AppModel.setVisibility`).
    func setVisibility(_ item: MediaItem, public makePublic: Bool) {
        guard let video = item.video else { return }
        Task {
            if makePublic { showStatus(Copy.Library2.makingPublic) }
            do {
                let change = try await model.setVisibility(video, public: makePublic)
                if makePublic {
                    showStatus(Copy.Library2.nowPublic)
                } else {
                    showStatus(change.cacheCleared == false ? "\(Copy.Library2.nowPrivate) \(Copy.Media.cacheNote)" : Copy.Library2.nowPrivate)
                }
            } catch {
                showStatus(makePublic ? Copy.Media.makeLinkFailed : Copy.Media.turnOffFailed)
            }
        }
    }

    func save(_ item: MediaItem) {
        Task {
            do {
                try await RenditionPhotos.save(item.face, model: model)
                #if os(iOS)
                showStatus(Copy.savedPhotos)
                #endif
            } catch {
                showStatus(Self.words(error))
            }
        }
    }

    /// `delete everything` after the confirm, with the outcomes of the detail's (CONTRACT-MEDIA 1.12).
    func deleteEverything(_ item: MediaItem) {
        Task {
            if model.isBusy(item) {
                showStatus(Copy.Media.deleteBusy)
                return
            }
            showStatus(Copy.Media.deleting)
            do {
                switch try await model.deleteEverything(item) {
                case .done:
                    showStatus(Copy.Media.deleted)
                    if let id = item.post?.id, selection == id { selection = nil }
                case .partial(let remaining):
                    showStatus(Copy.Media.deletePartial(remaining: remaining))
                case .leftOnServer:
                    showStatus(Copy.Media.stillOnServer)
                }
            } catch {
                showStatus((error as? PipelineFailure) == .serverBusy ? Copy.Media.deleteBusy : Copy.Media.deleteFailed)
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
