import CobaltKit
import SwiftUI

// The library's `add to link` (APP-API-CONTRACT 41.4): from the select panel (every pick) and from the context menu of
// a tile, row or table line (that post, or the table's selection when the row is part of it). Both open the same
// `LinkPickerSheet`; a tap on a link with room appends the files and the toast offers `open`.

/// The posts the link picker is open for.
struct LibraryLinkPicks: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    /// From the select panel: select mode ends once the files are in.
    let endsSelecting: Bool
}

extension LibraryController {
    /// The server edits gallery links (`features.share_set_edit`).
    var addsToLinks: Bool { model.capabilities.shareSets && model.capabilities.shareSetEdit }

    /// Whether the context menu offers `add to link…` for this post: a shareable, not hidden post with a file.
    func canAddToLink(_ row: LibraryRow) -> Bool {
        addsToLinks && row.shareable && !row.isHidden && ShareSetPick(item: row.item).anyFileID != nil
    }

    /// The context menu's `add to link…`: the post, or every post of the table's selection when it is one of them.
    func addToLink(_ row: LibraryRow, also selected: [LibraryRow]) {
        let rows = selected.contains(where: { $0.id == row.id }) ? selected.filter(canAddToLink) : [row]
        guard !rows.isEmpty else { return }
        addingToLink = LibraryLinkPicks(items: rows.map(\.item), endsSelecting: false)
    }

    /// The select panel's `add to link`: every pick, in pick order.
    func addPicksToLink(_ rows: [LibraryRow]) {
        guard !rows.isEmpty else { return }
        addingToLink = LibraryLinkPicks(items: rows.map(\.item), endsSelecting: true)
    }
}

/// Presents the link picker for `controller.addingToLink`, appends the files to the chosen link, and shows the link the
/// toast's `open` asks for (in a sheet, since the library has no links stack).
struct LibraryAddToLinkPresenter: ViewModifier {
    let model: AppModel
    @Bindable var controller: LibraryController
    @State private var openedLink: LinkRoute?
    @State private var addedToken = 0
    @State private var addFailedToken = 0
    @Environment(\.shell) private var shell

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.addingToLink) { picks in
                LinkPickerSheet(
                    store: model.shareSets, picks: picks.items.map { ShareSetPick(item: $0) },
                    maximum: model.capabilities.limits.shareSetMax,
                    showsBadges: model.capabilities.privateLinks
                ) { link, ids in add(ids, to: link, endsSelecting: picks.endsSelecting) }
            }
            .sheet(item: $openedLink) { route in
                NavigationStack {
                    LinkScreen(model: model, setID: route.id, inSheet: true)
                }
                .cobaltRoot(model: model)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
            }
            .haptic(.success, trigger: addedToken)
            .haptic(.error, trigger: addFailedToken)
    }

    private func add(_ ids: [String], to link: ShareSet, endsSelecting: Bool) {
        guard !ids.isEmpty, !controller.appendingToLink else { return }
        controller.appendingToLink = true
        let store = model.shareSets
        let shell = self.shell
        let controller = self.controller
        Task {
            defer { controller.appendingToLink = false }
            do {
                let updated = try await store.addFiles(ids, to: link.id)
                if endsSelecting { withAnimation(Motion.rows) { controller.endSelecting() } }
                addedToken += 1
                let id = updated.id
                shell.showNote(StatusNote(
                    text: Copy.LinkEdit.addedTo(ids.count, updated.displayTitle), actionTitle: Copy.LinkEdit.openAction
                ) { openedLink = LinkRoute(id: id) })
            } catch {
                addFailedToken += 1
                shell.showStatus(Copy.LinkEdit.message(for: error))
            }
        }
    }
}
