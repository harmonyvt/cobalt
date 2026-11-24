import CobaltKit
import SwiftUI

// The select actions in the screen pane (apple/CONTRACT-PANE.md section 5: library `.selection`). While the library is in
// select mode on a window with room for the pane, the actions live here instead of the pill: the picks as thumbnails
// (hold one to see it), four big buttons (make link, collection, share, edit), and the rest (add to link, status, trash)
// in the header's menu. The picks are the library's own (`LibraryController`, handed over with `pane.provide`); the
// pane's xmark only hides this page, `done selecting` is what leaves select mode.
//
// On one narrow screen (the iPhone) the page is the select pill expanded: a `.medium` / `.large` sheet over a grid that
// stays tappable at `.medium` (`PaneItem.compactSheet`), titled `N posts` with what they are under it (`2 videos · 1
// picture`), the grid share / add to link / hide / delete, and make link, collection, edit and the status choices in
// `more`. Swiping it down or its xmark goes back to the pill and keeps select mode and the ticks. What the library itself
// presents (the share sheet and its progress card, the link picker, the confirm of hiding) waits for the sheet to go down
// first (`afterCollapse`): a sheet cannot be presented from under another.

/// `.selection`: reads the library's controller from the pane. A window with no library behind it (the tab was never
/// built) says so and offers the close.
struct PaneSelectionPage: View {
    let model: AppModel
    let pane: Pane

    var body: some View {
        if let controller = pane.provided(LibraryController.self) {
            PaneSelectionContent(model: model, pane: pane, controller: controller)
        } else {
            PaneGonePage(message: Copy.SelectPane.nothingPicked)
        }
    }
}

struct PaneSelectionContent: View {
    let model: AppModel
    let pane: Pane
    @Bindable var controller: LibraryController

    @Environment(\.paneShape) private var shape
    @State private var pickingCollection = false
    @State private var deleting = false
    @State private var editNote: String?
    @State private var creatingEdit = false
    /// A hold on a pick's thumbnail: its media over this page.
    @State private var peeking: LibraryRow?

    private var store: ShareSetStore { model.shareSets }
    private var makesLinks: Bool { model.capabilities.shareSets }
    private var files: Bool { makesLinks && model.capabilities.shareCollections }
    private var inAlbum: Bool { model.library.showingHidden }
    private var offersStatus: Bool { model.capabilities.hidden }
    private var busy: Bool { controller.changingStatus || model.library.statusInFlight }
    /// The pane is the sheet of one narrow screen: the pill's expanded form.
    private var compact: Bool { pane.placement == .compact }

    var body: some View {
        let rows = controller.shownRows
        let picks = controller.pickedRows(rows)
        let verdict = controller.shareLinkVerdict(rows)
        let ready = verdict == .ready && !controller.makingShareLink
        Group {
            if shape == .bar {
                bar(picks)
            } else {
                page(rows: rows, picks: picks, verdict: verdict, ready: ready)
            }
        }
        .overlay {
            if let row = peeking {
                LibraryPeek(row: row, dims: true)
                    .transition(.opacity)
            }
        }
        .motion(Motion.card, value: peeking?.id)
        // the album's picks are not in the app switcher's snapshot (the pane is not under the library's own cover)
        .hiddenCover(controller)
        .navigationDestination(isPresented: $pickingCollection) {
            CollectionPickerSheet(store: store, picks: picks, file: { target in
                Task { await controller.makeLinkAndEnd(controller.shownRows, into: target) }
            }, inPane: true)
        }
        .sheet(isPresented: $deleting) {
            let doomed = controller.pickedRows(controller.shownRows).map(\.item).filter { controller.canDelete($0) }
            LibraryDeleteSheet(picks: doomed, impact: DeleteImpact(picks: doomed, model: model), delete: controller.deletePicks)
        }
    }

    // MARK: the page

    private func page(rows: [LibraryRow], picks: [LibraryRow], verdict: ShareSetVerdict, ready: Bool) -> some View {
        PanePage(
            title: compact ? Copy.SelectPane.posts(picks.count) : Copy.Library2.pickedCount(picks.count),
            subtitle: subtitle(picks, verdict: verdict),
            actions: headerActions(rows, picks: picks),
            more: moreActions(rows, picks: picks)
        ) {
            thumbs(picks)
        } controls: {
            VStack(alignment: .leading, spacing: 12) {
                // (the iPhone's sheet leaves the choice out: make link is in `more` there, and follows settings › sharing)
                if !inAlbum, !compact, makesLinks, model.capabilities.privateLinks { privacyChoice }
                PaneActionGrid(gridActions(rows, picks: picks, ready: ready))
                if let editNote, !picks.isEmpty, !inAlbum {
                    Text(editNote)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func subtitle(_ picks: [LibraryRow], verdict: ShareSetVerdict) -> String {
        if picks.isEmpty { return Copy.SelectPane.nothingPicked }
        if compact { return Copy.SelectPane.kinds(picks) }
        guard !inAlbum, makesLinks else { return "" }
        return Copy.PrivateLinks.line(for: verdict, count: picks.count, isPrivate: controller.makesPrivateLink)
    }

    // MARK: the picks

    /// The picks in tap order: a strip under the header bar (tall), a grid on the media's own screen otherwise.
    @ViewBuilder
    private func thumbs(_ picks: [LibraryRow]) -> some View {
        if picks.isEmpty {
            EmptyView()
        } else if shape == .tall {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { index, row in
                            SelectionThumb(row: row, number: index + 1, controller: controller, peeking: $peeking,
                                           side: compact ? 48 : 64)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, compact ? 6 : 8)
                }
                .padding(.top, 8)
                .onChange(of: picks.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(Motion.rows) { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, row in
                        SelectionThumb(row: row, number: index + 1, controller: controller, peeking: $peeking, side: nil)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: the actions

    private func headerActions(_ rows: [LibraryRow], picks: [LibraryRow]) -> [PaneAction] {
        let shareable = rows.filter(\.shareable)
        let allPicked = !shareable.isEmpty && shareable.allSatisfy { controller.picked.contains($0.id) }
        return [
            PaneAction(
                allPicked ? Copy.Library2.selectNone : Copy.Library2.selectAll,
                systemImage: allPicked ? Symbol.Library.selectNone : Symbol.Library.selectAll, disabled: shareable.isEmpty
            ) { withAnimation(Motion.rows) { controller.toggleAll(rows) } },
            PaneAction(Copy.SelectPane.done, systemImage: Symbol.checkmark) {
                withAnimation(Motion.rows) { controller.endSelecting() }
            },
        ]
    }

    /// The four big buttons: in the album `unhide`; else make link, collection, share and edit (the ones the server offers).
    private func gridActions(_ rows: [LibraryRow], picks: [LibraryRow], ready: Bool) -> [PaneAction] {
        if inAlbum {
            // queuesOffline (here and in `statusActions`, `compactActions`): `controller.chooseStatus` -> `applyStatus` ->
            // `LibraryModel.setStatus`, which enqueues in the sync outbox when the engine is on
            return [PaneAction(Copy.HiddenAlbum.unhide, systemImage: Symbol.HiddenAlbum.unhide, needsServer: true,
                               queuesOffline: model.libraryQueuesEdits, disabled: picks.isEmpty || busy) {
                controller.chooseStatus(.off, posts: controller.pickedPosts(rows))
            }]
        }
        if compact, !inAlbum { return compactActions(rows, picks: picks, ready: ready).grid }
        var out: [PaneAction] = []
        if let makeLink = makeLinkAction(ready: ready) { out.append(makeLink) }
        if let collection = collectionAction(ready: ready) { out.append(collection) }
        out.append(shareAction(picks))
        if let edit = editAction(picks) { out.append(edit) }
        return out
    }

    private func makeLinkAction(ready: Bool) -> PaneAction? {
        guard makesLinks else { return nil }
        return PaneAction(
            controller.makingShareLink ? Copy.Links.making : Copy.Links.make, systemImage: Symbol.link,
            needsServer: true, disabled: !ready, id: "make-link"
        ) { Task { await controller.makeLinkAndEnd(controller.shownRows) } }
    }

    private func collectionAction(ready: Bool) -> PaneAction? {
        guard files else { return nil }
        return PaneAction(
            Copy.Library2.collection, systemImage: Symbol.Library.collectionFile, needsServer: true, disabled: !ready,
            id: "collection"
        ) { pickingCollection = true }
    }

    private func shareAction(_ picks: [LibraryRow]) -> PaneAction {
        PaneAction(
            Copy.Library2.share, systemImage: Symbol.Library.share, disabled: controller.preparingShare || picks.isEmpty,
            id: "share"
        ) { afterCollapse { Task { await controller.shareAndEnd(controller.shownRows) } } }
    }

    private func editAction(_ picks: [LibraryRow]) -> PaneAction? {
        guard model.editor.isAvailable else { return nil }
        return PaneAction(
            creatingEdit ? Copy.Editor.creating : Copy.Editor.edit, systemImage: Symbol.Editor.edit,
            needsServer: true, disabled: !picks.contains(where: EditPicksButton.canEdit) || creatingEdit, id: "edit"
        ) { createEdit(picks) }
    }

    private func addToLinkAction(_ picks: [LibraryRow]) -> PaneAction? {
        guard !inAlbum, controller.addsToLinks else { return nil }
        return PaneAction(
            Copy.LinkEdit.addToLink, systemImage: Symbol.LinkEdit.addToLink,
            needsServer: true, disabled: picks.isEmpty || controller.appendingToLink, id: "add-to-link"
        ) { afterCollapse { controller.addPicksToLink(picks) } }
    }

    private func deleteAction(_ picks: [LibraryRow]) -> PaneAction? {
        guard picks.contains(where: { controller.canDelete($0.item) }) else { return nil }
        return PaneAction(
            Copy.DeletePicks.delete, systemImage: Symbol.Library.deleteEverything, role: .destructive,
            needsServer: true, disabled: picks.isEmpty || busy, id: "delete"
        ) { deleting = true }
    }

    /// The status choices (hidden, off, public, private), each one request for every pick.
    private func statusActions(_ rows: [LibraryRow], picks: [LibraryRow], includeHidden: Bool) -> [PaneAction] {
        guard offersStatus else { return [] }
        let disabled = picks.isEmpty || busy
        let posts = controller.pickedPosts(rows)
        var out: [PaneAction] = []
        if includeHidden {
            out.append(PaneAction(Copy.HiddenAlbum.statusHidden, systemImage: Symbol.HiddenAlbum.hidden, needsServer: true, queuesOffline: model.libraryQueuesEdits, disabled: disabled, id: "status-hidden") {
                controller.chooseStatus(.hidden, posts: posts)
            })
        }
        out.append(PaneAction(Copy.HiddenAlbum.statusOff, systemImage: Symbol.HiddenAlbum.off, needsServer: true, queuesOffline: model.libraryQueuesEdits, disabled: disabled, id: "status-off") {
            controller.chooseStatus(.off, posts: posts)
        })
        out.append(PaneAction(Copy.HiddenAlbum.statusPublic, systemImage: Symbol.HiddenAlbum.publicLink, needsServer: true, queuesOffline: model.libraryQueuesEdits, disabled: disabled, id: "status-public") {
            controller.chooseStatus(.public, posts: posts)
        })
        if model.capabilities.privateLinks {
            out.append(PaneAction(Copy.HiddenAlbum.statusPrivate, systemImage: Symbol.HiddenAlbum.privateLink, needsServer: true, queuesOffline: model.libraryQueuesEdits, disabled: disabled, id: "status-private") {
                controller.chooseStatus(.private, posts: posts)
            })
        }
        return out
    }

    /// The iPhone sheet's grid (share, add to link, hide, delete last) and the rest. The pill's own row is make link,
    /// collection, add to link, edit, share, status, trash; here the ones the owner reaches for most are the grid.
    private func compactActions(_ rows: [LibraryRow], picks: [LibraryRow], ready: Bool) -> (grid: [PaneAction], rest: [PaneAction]) {
        let disabled = picks.isEmpty || busy
        let posts = controller.pickedPosts(rows)
        let hide: PaneAction? = offersStatus ? PaneAction(
            Copy.HiddenAlbum.menuHide, systemImage: Symbol.HiddenAlbum.hidden, needsServer: true,
            queuesOffline: model.libraryQueuesEdits, disabled: disabled, id: "hide"
        ) { afterCollapse { controller.chooseStatus(.hidden, posts: posts) } } : nil
        let lead = [shareAction(picks), addToLinkAction(picks), hide].compactMap { $0 }
            + [makeLinkAction(ready: ready), collectionAction(ready: ready), editAction(picks)].compactMap { $0 }
        let delete = deleteAction(picks)
        let room = delete == nil ? PaneActionGrid.limit : PaneActionGrid.limit - 1
        return (
            Array(lead.prefix(room)) + [delete].compactMap { $0 },
            Array(lead.dropFirst(room)) + statusActions(rows, picks: picks, includeHidden: false))
    }

    /// On the iPhone's sheet the library presents some things itself (the share sheet, the link picker, the confirm of
    /// hiding): the sheet goes down first and the action runs once it is gone. Select mode and the ticks stay.
    private func afterCollapse(_ run: @escaping @MainActor () -> Void) {
        guard compact else { run(); return }
        pane.close(ifShowing: .selection)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            run()
        }
    }

    /// What does not fit the grid: add to a link, the status choices, the trash.
    private func moreActions(_ rows: [LibraryRow], picks: [LibraryRow]) -> [PaneAction] {
        if compact, !inAlbum { return compactActions(rows, picks: picks, ready: controller.shareLinkVerdict(rows) == .ready && !controller.makingShareLink).rest }
        var out: [PaneAction] = []
        if let add = addToLinkAction(picks) { out.append(add) }
        out += statusActions(rows, picks: picks, includeHidden: true)
        if let delete = deleteAction(picks) { out.append(delete) }
        return out
    }

    /// `public` / `private` for the link the page makes (APP-API-CONTRACT 36.6), starting at settings › sharing.
    private var privacyChoice: some View {
        Picker(Copy.PrivateLinks.choice, selection: Binding(
            get: { controller.makesPrivateLink },
            set: { controller.shareLinkPrivate = $0 }
        )) {
            Label(Copy.PrivateLinks.choicePublic, systemImage: Symbol.PrivateLinks.publicLink).tag(false)
            Label(Copy.PrivateLinks.choicePrivate, systemImage: Symbol.PrivateLinks.makePrivate).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(controller.makingShareLink)
        .task {
            if !store.privateLoaded { try? await store.refreshPrivate() }
        }
    }

    /// `edit`: makes the editor's project from the picks that have a video on the server, and opens it.
    private func createEdit(_ picks: [LibraryRow]) {
        editNote = nil
        creatingEdit = true
        Task {
            defer { creatingEdit = false }
            let items = picks.filter(EditPicksButton.canEdit).map(\.item)
            do {
                let left = try await model.editor.create(from: items)
                EditorLauncher.shared.firstToast = EditPicksButton.firstToast(left)
            } catch {
                switch EditError.from(error) {
                case .invalid(.empty): editNote = Copy.Editor.editNoVideo
                case .tooMany: editNote = Copy.Editor.tooManyProjects
                case .invalid(let problem): editNote = Copy.Editor.problem(problem)
                default: editNote = Copy.Editor.couldntCreate
                }
            }
        }
    }

    // MARK: the bar

    /// Select mode never runs on its own: the bar is not used. Drawn anyway so a restored route shows the count.
    private func bar(_ picks: [LibraryRow]) -> some View {
        PanePage(title: Copy.Library2.pickedCount(picks.count)) {
            Image(systemName: Symbol.Library.select)
        } controls: {
            EmptyView()
        }
    }
}

/// One pick: its picture with its number. A tap takes it out of the picks; a hold shows it (over the page).
private struct SelectionThumb: View {
    let row: LibraryRow
    let number: Int
    let controller: LibraryController
    @Binding var peeking: LibraryRow?
    /// Nil: as wide as the grid cell.
    var side: CGFloat? = 64

    var body: some View {
        Button {
            if controller.takeSwallowedTap() { return }
            withAnimation(Motion.rows) { controller.unpick(row.id) }
        } label: {
            FacePicture(item: row.item, maxPixel: 192, showsGlyph: false)
                .frame(width: side, height: side)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(CobaltColor.onText)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(CobaltColor.text, in: Circle())
                        .offset(x: -5, y: -5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .peekOnHold(row, controller: controller, local: $peeking)
        .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
        .accessibilityHint(Copy.Library2.unpickHint)
    }
}

// MARK: - previews

#if DEBUG
private struct SelectionPreview: View {
    var shape: PaneShape = .tall
    @State private var pane = Pane(route: PaneRoute(item: .selection, state: .screen))
    @State private var controller: LibraryController?

    var body: some View {
        PreviewHost(.happy, tab: .library) { model in
            Group {
                if let controller {
                    PaneSelectionContent(model: model, pane: pane, controller: controller)
                } else {
                    Color.clear
                }
            }
            .environment(\.paneShape, shape)
            .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
            .environment(pane)
            .background(CobaltColor.bg)
            .task {
                if model.library.posts.isEmpty { await model.library.refresh() }
                let made = LibraryController(model: model)
                let rows = await model.settledLibraryRows()
                made.shownRows = rows
                made.beginSelecting()
                for row in rows.prefix(3) where row.shareable { made.togglePick(row) }
                controller = made
            }
        }
    }
}

#Preview("selection · tall", traits: .fixedLayout(width: 440, height: 900)) { SelectionPreview() }
#Preview("selection · wide", traits: .fixedLayout(width: 1000, height: 560)) { SelectionPreview(shape: .wide) }
#endif
