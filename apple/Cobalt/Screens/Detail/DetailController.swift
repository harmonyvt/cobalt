import CobaltKit
import Foundation
import Observation

/// What the detail is doing and asking about: the selected tab, the confirm, the state of a delete, and the
/// small flashes of the buttons. The screen holds one; the actions go to `AppModel` (CONTRACT-MEDIA 4.2)
/// and the model's answer is what the screen shows next. No delete is faked: nothing is claimed gone that
/// the server did not confirm.
@MainActor @Observable
final class DetailController {
    /// The question a `confirmationDialog` asks, and what "try again" repeats.
    enum Confirm: Equatable, Identifiable {
        case deleteWebp(Rendition.ID)       // on the server (and here)
        case removeWebp(Rendition.ID)       // the server cannot delete it with a key: only this device
        case removeMedia                    // whole media, from this device only
        case deleteEverything
        case deletePhoto(Int)               // one item of a gallery, for everyone (its index in the post)
        case deletePhotos([Int])            // the ticked items (`select photos`)
        case deleteMade(Rendition.ID)       // a slideshow, a gallery image or a crop, for everyone

        var id: String {
            switch self {
            case .deleteWebp(let id): return "delete:\(id)"
            case .removeWebp(let id): return "removeWebp:\(id)"
            case .removeMedia: return "removeMedia"
            case .deleteEverything: return "deleteEverything"
            case .deletePhoto(let index): return "deletePhoto:\(index)"
            case .deletePhotos(let indices): return "deletePhotos:\(indices.map(String.init).joined(separator: ","))"
            case .deleteMade(let id): return "deleteMade:\(id)"
            }
        }
    }

    /// Where a delete is (CONTRACT-MEDIA 1.12): nothing, going, "couldn't delete that", the server's
    /// partial answer with how many files are left, or a run of this media that has to finish first.
    enum Phase: Equatable {
        case idle, deleting, failed, partial(remaining: Int), busy
    }

    enum Step: Equatable { case idle, working, done }

    /// What the screen does after an action that ended it.
    enum Effect: Equatable { case none, popWithStatus(String), makeWebp }

    let model: AppModel

    /// The rendition shown; nil = the media's face (a gallery: its first photo). A stale id (its file went) falls back to
    /// the face. On a gallery's `items` tab it is the shown photo's id (`item:3`), or nil on a page that was never saved.
    var selectedID: Rendition.ID?
    /// A gallery's shown page, by the item's place in the post. A page that was deleted falls to the one after it.
    var pageIndex: Int?
    /// `select photos` is on: the strip shows ticks, the actions become share / to photos / delete.
    var selecting = false
    var picked: Set<Int> = []
    /// A neutral line under the actions for a moment (`copied 12 links.`, `saved to Photos.`).
    var flash: String?
    /// A switch of the whole post is on its way.
    var postVisibility: Step = .idle
    /// Items whose `try again` was pressed and which have not landed yet.
    var retrying: Set<Int> = []
    /// A photo being read for its text (the rendition id).
    var readingText: Rendition.ID?
    /// A batch save to Photos (`save all`, the ticked ones).
    var batchPhotos: Step = .idle
    /// `make from this post…` is open (lane A2's combine sheet).
    var showsMakeSheet = false
    var confirm: Confirm?
    var phase: Phase = .idle
    /// What "try again" repeats after a failure or a partial delete.
    var retry: Confirm?
    /// A failure of a button other than a delete (save, public share, remove), in words.
    var notice: String?
    /// The rendition whose link was just copied (the button reads "copied" for a moment).
    var copiedID: String?
    var photos: [Rendition.ID: Step] = [:]
    var hosting: Step = .idle
    /// A switch that failed, in words, by rendition: shown under the public link row until the next try.
    var visibilityFailed: [Rendition.ID: String] = [:]
    /// Renditions whose last switch off could not clear the public link from the server's cache.
    var visibilityCacheNote: Set<Rendition.ID> = []
    /// Shown on the screen underneath once the whole media is gone (`deleted.`); nil for a removal that
    /// only freed space.
    var exitStatus: String?
    /// `#Preview`s and evidence runs: this media's own run is "in progress", and every delete answers
    /// "couldn't delete that" (the preview client's deletes succeed). Never set by the app itself.
    var previewBusy = false
    var previewFailsDeletes = false
    var previewPlacement: PhotosPlacement?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - selection

    func selected(in item: MediaItem) -> Rendition {
        // a gallery or a photo opens on its first photo, not on the newest made file (the face is the planet's rule)
        if item.detailShape != .classic { return galleryRendition(in: item) }
        if let selectedID, let r = item.rendition(id: selectedID) { return r }
        return item.face
    }

    func select(_ id: Rendition.ID) {
        guard id != selectedID else { return }
        selectedID = id
        notice = nil
        flash = nil
        endSelecting()
        // a failed webp delete belongs to its tab; a partial delete of everything belongs to the media
        if phase == .failed, retry != .deleteEverything { phase = .idle; retry = nil }
    }

    // MARK: - what is allowed

    func isBusy(_ item: MediaItem) -> Bool {
        #if DEBUG
        if DetailDebug.forceBusy { return true }
        #endif
        return previewBusy || model.isBusy(item)
    }

    var isDeleting: Bool { phase == .deleting }

    var failsDeletes: Bool {
        #if DEBUG
        if DetailDebug.failDeletes { return true }
        #endif
        return previewFailsDeletes
    }

    /// A way to make a webp from this media: the library's post (reopened when its session expired), or a
    /// session this device still holds.
    func canMakeWebp(_ item: MediaItem) -> Bool {
        guard model.capabilities.studio else { return false }
        if let post = item.post { return post.session != nil || post.link != nil }
        return item.local?.original?.sessionID != nil || !(item.local?.sessionIDs.isEmpty ?? true)
    }

    /// The route `delete everything` takes (CONTRACT-MEDIA 1.12): one call on a server that has
    /// `delete_post`, else the webps one by one.
    func usesPostRoute(_ item: MediaItem) -> Bool {
        model.capabilities.deletePost && item.post != nil
    }

    /// Webps the fallback route can delete (they have a name the server takes).
    func deletableWebps(_ item: MediaItem) -> Int {
        item.webps.filter { $0.deletableName != nil }.count
    }

    /// `delete everything` is offered when the media has something on the server and a way to delete it:
    /// the post route, or at least one webp the fallback can take. Plain cobalt has neither.
    func canDeleteEverything(_ item: MediaItem) -> Bool {
        guard item.hasServerCopy else { return false }
        return usesPostRoute(item) || deletableWebps(item) > 0
    }

    /// Where the rendition is in the owner's Photos. A gallery's files are keyed by their place in the post, so they ask with
    /// the media (`g:<sid>:<n>`, `m:<library id>`).
    func placement(of r: Rendition, in item: MediaItem? = nil) -> PhotosPlacement {
        if let previewPlacement { return previewPlacement }
        #if DEBUG
        if let forced = DetailDebug.placement { return forced }
        #endif
        if let item, r.isItem || r.isMade { return model.photosPlacement(of: r, in: item) }
        return model.photosPlacement(of: r)
    }

    // MARK: - buttons

    func copy(_ url: URL, for id: String) {
        Pasteboard.copy(url.absoluteString)
        notice = nil
        copiedID = id
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if copiedID == id { copiedID = nil }
        }
    }

    func savePhotos(_ r: Rendition, in item: MediaItem? = nil) async {
        guard photos[r.id] != .working else { return }
        notice = nil
        photos[r.id] = .working
        do {
            try await RenditionPhotos.save(r, in: item, model: model)
            photos[r.id] = .done
        } catch {
            photos[r.id] = .idle
            notice = Self.words(error)
        }
    }

    // MARK: - public or private (CONTRACT-VISIBILITY 6.2)

    /// The rendition has a public/private switch: the server takes it (`features.visibility`, and the file says it
    /// can be switched). Without it the old "public share" button stays.
    func canSwitchVisibility(_ r: Rendition) -> Bool {
        model.capabilities.visibility && r.canToggleVisibility
    }

    /// Turns the rendition's link on or off. The model flips the file at once and puts it back when the server
    /// says no; here the answer becomes words under the row.
    func setVisibility(_ r: Rendition, public makePublic: Bool) async {
        guard !model.isChangingVisibility(r) else { return }
        visibilityFailed[r.id] = nil
        visibilityCacheNote.remove(r.id)
        do {
            let change = try await model.setVisibility(r, public: makePublic)
            if !makePublic, change.cacheCleared == false { visibilityCacheNote.insert(r.id) }
        } catch {
            if let failure = error as? PipelineFailure, [.keyInvalid, .keyMissing, .unreachable].contains(failure) {
                visibilityFailed[r.id] = Copy.failure(failure)
            } else {
                visibilityFailed[r.id] = makePublic ? Copy.Media.makeLinkFailed : Copy.Media.turnOffFailed
            }
        }
    }

    /// "public share": hosts the private copy; the library gives the link back (and copies it).
    func publicShare(_ r: Rendition) async {
        guard hosting != .working, let file = r.file else { return }
        notice = nil
        hosting = .working
        do {
            _ = try await model.library.host(file)
            hosting = .done
            copiedID = r.id
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                if copiedID == r.id { copiedID = nil }
                hosting = .idle
            }
        } catch {
            hosting = .idle
            notice = Self.words(error)
        }
    }

    // MARK: - removing and deleting

    /// "remove from this iphone": the media's local records go; the server, the library and every public
    /// link stay. False (nothing removed) while something on the device is using a file.
    func removeFromDevice(_ item: MediaItem) async -> Bool {
        notice = nil
        exitStatus = nil
        let removed = await model.removeFromDevice(item)
        if !removed { notice = Copy.Media.deleteBusy }
        return removed
    }

    /// One webp: on the server when it has a name the key can delete, and the local record. A failure keeps
    /// the tab and says so under the actions.
    func deleteWebp(_ r: Rendition, of item: MediaItem, onServer: Bool) async {
        guard phase != .deleting else { return }
        retry = onServer ? .deleteWebp(r.id) : .removeWebp(r.id)
        notice = nil
        phase = .deleting
        exitStatus = onServer && item.renditions.count == 1 ? Copy.Media.deleted : nil
        if onServer, failsDeletes {
            try? await Task.sleep(for: .milliseconds(700))
            phase = .failed
            return
        }
        // The tab that takes over when this one goes: the next one, else the one before.
        let order = item.renditions.map(\.id)
        let fallback = order.firstIndex(of: r.id).flatMap { i in
            order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil)
        }
        do {
            try await model.deleteWebp(r, of: item)
            phase = .idle
            retry = nil
            if selectedID == r.id { selectedID = fallback }
        } catch {
            phase = Self.isBusy(error) ? .busy : .failed
        }
    }

    /// `delete everything` (CONTRACT-MEDIA 1.12).
    func deleteEverything(_ item: MediaItem) async -> Effect {
        guard phase != .deleting else { return .none }
        retry = .deleteEverything
        notice = nil
        if isBusy(item) {
            phase = .busy
            return .none
        }
        phase = .deleting
        exitStatus = Copy.Media.deleted
        if failsDeletes {
            try? await Task.sleep(for: .milliseconds(700))
            phase = .failed
            return .none
        }
        do {
            switch try await model.deleteEverything(item) {
            case .done:
                // nothing left anywhere: the screen sees the media gone and pops (see `MediaDetail`)
                phase = .idle
                retry = nil
                return .none
            case .partial(let remaining):
                exitStatus = nil
                phase = .partial(remaining: remaining)
                return .none
            case .leftOnServer:
                phase = .idle
                retry = nil
                exitStatus = nil
                return .popWithStatus(Copy.Media.stillOnServer)
            }
        } catch {
            exitStatus = nil
            phase = Self.isBusy(error) ? .busy : .failed
            return .none
        }
    }

    /// "try again": the same call again (the server's delete is idempotent).
    func tryAgain(_ item: MediaItem) async -> Effect {
        switch retry {
        case .deleteEverything:
            return await deleteEverything(item)
        case .deleteWebp(let id), .removeWebp(let id):
            guard let r = item.rendition(id: id) else { phase = .idle; return .none }
            await deleteWebp(r, of: item, onServer: retry == .deleteWebp(id))
            return .none
        case .deletePhoto(let index):
            await deletePhotos([index], of: item)
            return .none
        case .deletePhotos(let indices):
            await deletePhotos(indices, of: item)
            return .none
        case .deleteMade(let id):
            guard let r = item.rendition(id: id) else { phase = .idle; return .none }
            await deleteMade(r, of: item)
            return .none
        default:
            phase = .idle
            return .none
        }
    }

    // MARK: - words

    static func isBusy(_ error: Error) -> Bool {
        (error as? PipelineFailure) == .serverBusy
    }

    /// A button's failure in plain words.
    static func words(_ error: Error) -> String {
        if let failure = error as? PipelineFailure { return Copy.failure(failure) }
        return Copy.actionFailed
    }
}
