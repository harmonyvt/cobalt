import CobaltKit
import SwiftUI

// What a post's page does, shared by the two pages that show one: `MediaDetail` (pushed on the iPhone's tabs, opened in
// sheets) and `PanePostPage` (the iPad's and the Mac's pane, the iPhone's pane sheet for the items that still open there).
// One kit holds the logic (share, the confirms, add to link, edit, hide, ask about, open in library), one state object
// holds what is on screen because of it (the share sheet's files, the link picker, the hide confirm), one modifier presents
// them, and `PostGridControls` / `PostToolIcons` draw the controls. A page keeps only what is really its own: where it
// pops to (`leave`) and how it knows the media is gone.

/// What the page shows because of an action: the system share sheet's files, the link picker, the hide / unhide confirm,
/// the editor project being made. An object so the kit (a value, rebuilt each pass) can set it.
@MainActor
@Observable
final class PostActionState {
    /// File URLs for the system share sheet (empty: nothing is presented).
    var filesToShare: [URL] = []
    /// `add to link…` is picking a link for this post.
    var addingToLink: LibraryLinkPicks?
    /// `hide…` / `unhide` waiting on its confirm (`.hidden` or `.off`).
    var statusAsk: PostStatus?
    var creatingEdit = false
}

@MainActor
struct PostActionKit {
    let model: AppModel
    let controller: DetailController
    let state: PostActionState
    let shell: ShellActions
    /// Leaves the page: the pane closes, the detail pops.
    let leave: () -> Void
    /// The page is the iPhone's: its grid is what the library's context menu was (share, add to link, edit, delete last)
    /// instead of the plan's first four.
    let compactGrid: Bool
    /// `open in library` leaves the page first (a sheet over the tab would light the post behind it).
    let leavesForLibrary: Bool
    /// The page was opened on a hidden post (from the hidden album).
    let fromAlbum: Bool
    /// Nothing of the media is left anywhere.
    let isGone: () -> Bool
    /// The page shows `deleted.` (and pops, where it can).
    let finishGone: () -> Void
    /// Opens a link in the pane (`added to <link>`'s `open`); nothing where there is no pane.
    let openLink: (String) -> Void

    // MARK: the buttons

    func postActions(_ c: DetailContext) -> PostActions {
        PostActions(
            c: c, share: share, shareLink: { state.filesToShare = [$0] }, leave: leave,
            shellMakeWebp: { shell.makeWebp($0) })
    }

    /// The grid and what goes to `more`. A compact grid ends on `delete everything`, so `more` has no delete then.
    func arranged(_ c: DetailContext) -> (grid: [PaneAction], rest: [PaneAction]) {
        let item = c.item
        return PostActions.arrange(
            plan: postActions(c).all, compact: compactGrid, addToLink: addToLinkAction(item), edit: editAction(item),
            delete: compactGrid ? deleteAction(item) : nil)
    }

    /// The header menu's rows: what the grid left, `open in library` (a page that has no menu of its own for it passes it),
    /// `hide…` / `unhide`, and `delete everything` when the grid did not take it.
    func moreActions(_ c: DetailContext, rest: [PaneAction], openInLibrary: PaneAction? = nil) -> [PaneAction] {
        var list = rest
        if let openInLibrary { list.append(openInLibrary) }
        if let hide = hideAction(c.item) { list.append(hide) }
        if !compactGrid, let delete = deleteAction(c.item) { list.append(delete) }
        return list
    }

    /// What `MediaDetail`'s own `more` menu adds to the entries it always had: on a page whose grid is the iPhone's, what
    /// the grid left, else `add to link`, `edit`; and in both, `hide…` / `unhide`.
    func menuExtras(_ c: DetailContext, grid: Bool) -> [PaneAction] {
        if grid { return arranged(c).rest + [hideAction(c.item)].compactMap { $0 } }
        return [addToLinkAction(c.item), editAction(c.item), hideAction(c.item)].compactMap { $0 }
    }

    /// `delete everything`, with its confirm.
    func deleteAction(_ item: MediaItem) -> PaneAction? {
        guard controller.canDeleteEverything(item) else { return nil }
        return PaneAction(
            Copy.Media.deleteEverything, systemImage: Symbol.Media.deleteEverything, role: .destructive,
            disabled: controller.isDeleting || controller.isBusy(item), id: "delete"
        ) { controller.confirm = .deleteEverything }
    }

    /// `add to link…`: the link picker, as a sheet of this page.
    func addToLinkAction(_ item: MediaItem) -> PaneAction? {
        let row = LibraryRow(item: item)
        guard model.capabilities.shareSets, model.capabilities.shareSetEdit, row.shareable, !row.isHidden,
              ShareSetPick(item: item).anyFileID != nil else { return nil }
        return PaneAction(
            Copy.LinkEdit.addToLinkMenu, systemImage: Symbol.LinkEdit.addToLink, needsServer: true, id: "add-to-link"
        ) { state.addingToLink = LibraryLinkPicks(items: [item], endsSelecting: false) }
    }

    /// `edit`: a new editor project from this post's video.
    func editAction(_ item: MediaItem) -> PaneAction? {
        guard model.editor.isAvailable, EditPicksButton.canEdit(LibraryRow(item: item)) else { return nil }
        return PaneAction(
            state.creatingEdit ? Copy.Editor.creating : Copy.Editor.edit, systemImage: Symbol.Editor.edit,
            needsServer: true, disabled: state.creatingEdit, id: "edit"
        ) { createEdit(item) }
    }

    /// `hide…` (asks first) and, in the hidden album, `unhide`.
    func hideAction(_ item: MediaItem) -> PaneAction? {
        guard model.capabilities.hidden, item.post != nil else { return nil }
        if fromAlbum || model.isHiddenPost(item) {
            // queuesOffline: `setStatus` -> `controller.setPostStatus` -> `LibraryModel.setStatus`, which enqueues in the sync outbox
            return PaneAction(
                Copy.HiddenAlbum.menuUnhide, systemImage: Symbol.HiddenAlbum.unhide, needsServer: true,
                queuesOffline: model.libraryQueuesEdits, id: "unhide"
            ) { state.statusAsk = .off }
        }
        return PaneAction(
            Copy.HiddenAlbum.menuHide, systemImage: Symbol.HiddenAlbum.hidden, needsServer: true,
            queuesOffline: model.libraryQueuesEdits, id: "hide"
        ) { state.statusAsk = .hidden }
    }

    /// `open in library` as a row (the pane's header menu has no entry of its own for it).
    func openInLibraryAction(_ item: MediaItem) -> PaneAction? {
        guard model.capabilities.library, item.post != nil, model.selectedTab != .library else { return nil }
        return PaneAction(Copy.Media.openInLibrary, systemImage: Symbol.Media.openInLibrary) { openInLibrary(item) }
    }

    // MARK: what they do

    /// Copies the files onto this device if they are not here, then presents the system sheet.
    func share(_ renditions: [Rendition]) {
        let controller = controller
        let state = state
        Task {
            guard !controller.preparingShare else { return }
            controller.preparingShare = true
            let urls = await controller.localFileURLs(for: renditions)
            controller.preparingShare = false
            guard !urls.isEmpty else { return }
            state.filesToShare = urls
        }
    }

    /// The answer to a confirm (`DetailDialogs`).
    func run(_ ask: DetailController.Confirm, _ item: MediaItem) {
        Task {
            switch ask {
            case .deleteWebp(let id), .removeWebp(let id):
                guard let r = item.rendition(id: id) else { return }
                if case .deleteWebp = ask { await controller.deleteWebp(r, of: item, onServer: true) }
                else { await controller.deleteWebp(r, of: item, onServer: false) }
            case .deletePhoto(let index):
                await controller.deletePhotos([index], of: item)
            case .deletePhotos(let indices):
                await controller.deletePhotos(indices, of: item)
            case .deleteMade(let id):
                guard let r = item.rendition(id: id) else { return }
                await controller.deleteMade(r, of: item)
            case .removeMedia:
                if await controller.removeFromDevice(item) {
                    if isGone() { finishGone() } else { leave() }
                }
            case .deleteEverything:
                if case .popWithStatus(let message) = await controller.deleteEverything(item) {
                    shell.showStatus(message)
                    leave()
                }
            }
        }
    }

    /// "ask about this": a new chat with this post attached, the chat tab open on it.
    func askAbout(_ item: MediaItem) {
        guard let post = item.post else { return }
        Task {
            do {
                try await model.askAbout([post])
                leave()
            } catch {
                shell.showStatus(Copy.Chat.message(for: error))
            }
        }
    }

    func openInLibrary(_ item: MediaItem) {
        guard let post = item.post else { return }
        // on one narrow screen the pane is a sheet over the tab: it goes, or the library would light the post behind it
        if leavesForLibrary { leave() }
        model.library.expandedPostID = post.id
        model.selectedTab = .library
    }

    func addToLink(_ ids: [String], link: ShareSet) {
        guard !ids.isEmpty else { return }
        let store = model.shareSets
        let shell = shell
        let openLink = openLink
        Task {
            do {
                let updated = try await store.addFiles(ids, to: link.id)
                let id = updated.id
                shell.showNote(StatusNote(
                    text: Copy.LinkEdit.addedTo(ids.count, updated.displayTitle), actionTitle: Copy.LinkEdit.openAction
                ) { openLink(id) })
            } catch {
                shell.showStatus(Copy.LinkEdit.message(for: error))
            }
        }
    }

    func setStatus(_ status: PostStatus, _ item: MediaItem) {
        guard let post = item.post else { return }
        Task {
            let result = await controller.setPostStatus(status, post: post, key: controller.selected(in: item).id)
            if result.changed { shell.showStatus(result.words(for: status)) }
            if result.changed, status == .hidden { leave() }
        }
    }

    func createEdit(_ item: MediaItem) {
        let state = state
        state.creatingEdit = true
        let model = model
        let shell = shell
        Task {
            defer { state.creatingEdit = false }
            do {
                let left = try await model.editor.create(from: [item])
                EditorLauncher.shared.firstToast = EditPicksButton.firstToast(left)
            } catch {
                switch EditError.from(error) {
                case .invalid(.empty): shell.showStatus(Copy.Editor.editNoVideo)
                case .tooMany: shell.showStatus(Copy.Editor.tooManyProjects)
                case .invalid(let problem): shell.showStatus(Copy.Editor.problem(problem))
                default: shell.showStatus(Copy.Editor.couldntCreate)
                }
            }
        }
    }
}

// MARK: - what is presented

/// The system share sheet, the link picker and the hide / unhide confirm of a post page. The confirm for each way to get
/// rid of something (`detailDialogs`), the make sheet and the rename alert stay with the page, which owns their state.
private struct PostActionPresenters: ViewModifier {
    @Bindable var state: PostActionState
    let kit: PostActionKit
    let item: MediaItem

    func body(content: Content) -> some View {
        content
            .background { GalleryFileShare(fileURLs: $state.filesToShare) }
            .sheet(item: $state.addingToLink) { picks in
                LinkPickerSheet(
                    store: kit.model.shareSets, picks: picks.items.map { ShareSetPick(item: $0) },
                    maximum: kit.model.capabilities.limits.shareSetMax, showsBadges: kit.model.capabilities.privateLinks
                ) { link, ids in kit.addToLink(ids, link: link) }
            }
            .confirmationDialog(
                state.statusAsk == .hidden ? Copy.Hidden.hideTitle : Copy.Hidden.unhideTitle,
                isPresented: Binding(get: { state.statusAsk != nil }, set: { if !$0 { state.statusAsk = nil } }),
                titleVisibility: .visible, presenting: state.statusAsk
            ) { ask in
                if ask == .hidden {
                    Button(Copy.Hidden.hideConfirm, role: .destructive) { kit.setStatus(.hidden, item) }
                } else {
                    Button(Copy.Hidden.unhide) { kit.setStatus(.off, item) }
                }
                Button(Copy.Hidden.cancel, role: .cancel) {}
            } message: { ask in
                Text(ask == .hidden ? Copy.Hidden.hideMessage : Copy.Hidden.unhideMessage)
            }
    }
}

extension View {
    func postActionPresenters(kit: PostActionKit, item: MediaItem) -> some View {
        modifier(PostActionPresenters(state: kit.state, kit: kit, item: item))
    }
}

// MARK: - what is drawn

/// The big buttons of a post and what runs under them: a gallery's `select photos` bar or the grid (with the offline words of
/// `PaneActionGrid`: "needs network", "queued"), then the state of whatever is running or failed.
struct PostGridControls: View {
    let c: DetailContext
    let kit: PostActionKit
    var leave: () -> Void
    /// Draws the post's icon circles (`PostToolIcons`) under the grid: the page that has no body of its own for them.
    var tools = false

    var body: some View {
        let arranged = kit.arranged(c)
        VStack(spacing: 12) {
            if c.controller.selecting, c.page != nil {
                GallerySelectionBar(c: c, share: kit.share)
            } else if !arranged.grid.isEmpty {
                PaneActionGrid(arranged.grid)
                    .disabled(c.controller.isDeleting)
            }
            if tools {
                PostToolIcons(c: c, hidden: kit.fromAlbum || c.model.isHiddenPost(c.item))
            }
            DetailStatus(controller: c.controller, item: c.item, leave: leave)
        }
    }
}

/// The icon circles that belong to a post beside its grid: `this is…` (a search name's example), the 7TV upload and the
/// emote editor. Draws nothing when none applies.
struct PostToolIcons: View {
    let c: DetailContext
    let hidden: Bool
    /// The page's own first icon (the pane's `more` menu as a circle), drawn ahead of these.
    var leading: AnyView?

    @Environment(\.shell) private var shell

    private var model: AppModel { c.model }

    var body: some View {
        IconRow(alignment: .leading) {
            if let leading { leading }
            if model.capabilities.names, !hidden, let key = c.item.post?.id {
                NamesPostMenu(model: model, postKey: key, showStatus: { shell.showStatus($0) }, iconCircle: true)
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
            }
            SevenTvUploadIcon(model: model, file: c.rendition.file, title: c.item.titleText)
            EmoteEditorIcon(model: model, rendition: c.rendition, title: c.item.titleText)
        }
        .sevenTvUploadReady(model, file: c.rendition.file)
    }
}

/// A list of `PaneAction`s as menu rows: a disabled row while the server is away (the menu has no room for the captions the
/// grid draws), a submenu for an action with choices (`share`).
struct PaneActionMenuItems: View {
    let actions: [PaneAction]
    let offline: Bool

    var body: some View {
        ForEach(actions) { action in
            if action.choices.isEmpty {
                Button(role: action.role) { action.perform() } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(action.off(offline: offline))
            } else {
                Menu(action.title, systemImage: action.systemImage) { PaneChoiceItems(choices: action.choices) }
                    .disabled(action.off(offline: offline))
            }
        }
    }
}
