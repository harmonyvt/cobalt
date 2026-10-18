import CobaltKit
import Observation
import SwiftUI

// What the links tab and a collection's screen share (APP-API-CONTRACT sections 24 and 26): copy, the revoke confirm,
// putting a link in or out of a collection, the new / rename sheet and the delete-collection confirm. Each screen owns
// its own controller (a pushed screen leaves the one underneath mounted, so two screens must never present from one
// piece of state) and applies `.linkPresentations(_:)`.

/// The new / rename sheet.
enum CollectionSheetRequest: Identifiable, Equatable {
    /// A new collection; `preselected` are the link ids ticked at the start (the link it was opened from).
    case create(preselected: [String])
    case rename(ShareCollection)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let c): return "rename-\(c.id)"
        }
    }
}

@MainActor @Observable
final class LinksController {
    let model: AppModel

    /// The link the owner chose `revoke` for: the confirm is open on it.
    var revoking: ShareSet?
    /// Links whose DELETE is in flight (dimmed; a second tap does nothing).
    var revokingIDs: Set<String> = []
    var copiedToken = 0
    /// +1 when a revoke, an add or remove, a reroll or a delete lands (success haptic) or fails (error haptic).
    var doneToken = 0
    var failedToken = 0
    /// The collection the owner chose `delete` for: the confirm is open on it.
    var deleting: ShareCollection?
    /// The collection the owner chose `reroll all links` for: the confirm is open on it.
    var rerolling: ShareCollection?
    /// Collections whose reroll is in flight (the item is disabled; a second tap does nothing).
    var rerollingIDs: Set<String> = []
    /// The new / rename sheet.
    var sheet: CollectionSheetRequest?

    init(model: AppModel) {
        self.model = model
    }

    var store: ShareSetStore { model.shareSets }

    /// Collections are offered only while the server has them.
    var collectionsEnabled: Bool { model.capabilities.shareCollections }

    // MARK: links

    /// The usual copy: the link on the pasteboard and `copied` over the shell.
    func copy(_ link: ShareSet, shell: ShellActions) {
        Pasteboard.copy(link.url.absoluteString)
        shell.showStatus(Copy.Media.copied)
        copiedToken += 1
    }

    /// Every link in the collection, one per line, on the pasteboard, and `copied` over the shell.
    func copyAll(_ collection: ShareCollection, shell: ShellActions) {
        guard let text = store.linksText(in: collection) else { return }
        Pasteboard.copy(text)
        shell.showStatus(Copy.Media.copied)
        copiedToken += 1
    }

    func revoke(_ link: ShareSet, shell: ShellActions) {
        guard !revokingIDs.contains(link.id) else { return }
        revokingIDs.insert(link.id)
        Task {
            defer { revokingIDs.remove(link.id) }
            do {
                try await store.revoke(link.id)
                shell.showStatus(Copy.Links.revoked)
                doneToken += 1
            } catch {
                shell.showStatus(Copy.actionFailed)
                failedToken += 1
            }
        }
    }

    // MARK: collections

    /// Opens the new-collection sheet, with this link ticked when it was opened from a row.
    func newCollection(including link: ShareSet?) {
        sheet = .create(preselected: link.map { [$0.id] } ?? [])
    }

    /// The menu's tap on a collection: in it → take it out, not in it → put it in.
    func toggle(_ link: ShareSet, in collection: ShareCollection, shell: ShellActions) {
        if collection.contains(link.id) {
            remove(link, from: collection, shell: shell)
        } else {
            Task {
                do {
                    try await store.addLink(link.id, to: collection.id)
                    shell.showStatus(Copy.Collections.added)
                    doneToken += 1
                } catch {
                    shell.showStatus(Copy.Collections.message(for: error))
                    failedToken += 1
                }
            }
        }
    }

    /// Takes a link out of a collection. Reversible, so there is no confirm.
    func remove(_ link: ShareSet, from collection: ShareCollection, shell: ShellActions) {
        Task {
            do {
                try await store.removeLink(link.id, from: collection.id)
                shell.showStatus(Copy.Collections.removed)
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Collections.message(for: error))
                failedToken += 1
            }
        }
    }

    /// Whether `reroll all links` is offered on this collection: it has loaded links and none is running on it.
    func canReroll(_ collection: ShareCollection) -> Bool {
        store.linksText(in: collection) != nil && !rerollingIDs.contains(collection.id)
    }

    /// Replaces every live link of the collection with a new one (after the confirm). The store swaps the ids and lists
    /// the links again; the status says what happened.
    func reroll(_ collection: ShareCollection, shell: ShellActions) {
        guard !rerollingIDs.contains(collection.id) else { return }
        rerollingIDs.insert(collection.id)
        shell.showStatus(Copy.Collections.rerolling)
        Task {
            defer { rerollingIDs.remove(collection.id) }
            do {
                try await store.rerollCollection(collection.id)
                shell.showStatus(Copy.Collections.rerolled)
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Collections.message(for: error))
                failedToken += 1
            }
        }
    }

    func delete(_ collection: ShareCollection, shell: ShellActions) {
        Task {
            do {
                try await store.deleteCollection(collection.id)
                shell.showStatus(Copy.Collections.deleted)
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Collections.message(for: error))
                failedToken += 1
            }
        }
    }
}

// MARK: - the presentations both screens apply

private struct LinkPresentations: ViewModifier {
    @Bindable var controller: LinksController

    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Copy.Links.revokeTitle, isPresented: revokingPresented, titleVisibility: .visible,
                presenting: controller.revoking
            ) { link in
                Button(Copy.Links.revoke, role: .destructive) { controller.revoke(link, shell: shell) }
                Button(Copy.Links.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.Links.revokeMessage)
            }
            .confirmationDialog(
                Copy.Collections.deleteTitle, isPresented: deletingPresented, titleVisibility: .visible,
                presenting: controller.deleting
            ) { collection in
                Button(Copy.Collections.delete, role: .destructive) { controller.delete(collection, shell: shell) }
                Button(Copy.Collections.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.Collections.deleteMessage)
            }
            .confirmationDialog(
                Copy.Collections.rerollTitle, isPresented: rerollingPresented, titleVisibility: .visible,
                presenting: controller.rerolling
            ) { collection in
                Button(Copy.Collections.rerollConfirm, role: .destructive) { controller.reroll(collection, shell: shell) }
                Button(Copy.Collections.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.Collections.rerollMessage)
            }
            .sheet(item: $controller.sheet) { request in
                CollectionSheet(model: controller.model, request: request)
            }
            .haptic(.success, trigger: controller.copiedToken, enabled: haptics)
            .haptic(.success, trigger: controller.doneToken, enabled: haptics)
            .haptic(.error, trigger: controller.failedToken, enabled: haptics)
    }

    private var revokingPresented: Binding<Bool> {
        Binding(get: { controller.revoking != nil }, set: { if !$0 { controller.revoking = nil } })
    }

    private var rerollingPresented: Binding<Bool> {
        Binding(get: { controller.rerolling != nil }, set: { if !$0 { controller.rerolling = nil } })
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { controller.deleting != nil }, set: { if !$0 { controller.deleting = nil } })
    }
}

extension View {
    func linkPresentations(_ controller: LinksController) -> some View {
        modifier(LinkPresentations(controller: controller))
    }
}
