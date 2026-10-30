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

/// A collection's `privacy…` choice waiting on its confirm.
struct CollectionPrivacyRequest: Identifiable, Equatable {
    let collection: ShareCollection
    let change: CollectionPrivacy
    var id: String { collection.id }
}

@MainActor @Observable
final class LinksController {
    let model: AppModel

    /// The link the owner chose `revoke` for: the confirm is open on it.
    var revoking: ShareSet?
    /// Links whose DELETE is in flight (dimmed; a second tap does nothing).
    var revokingIDs: Set<String> = []
    var copiedToken = 0
    /// The link copied last: its row's button says "copied" for a moment.
    var copiedID: String?
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

    // private links (APP-API-CONTRACT 36)
    /// The link the owner chose `make public…` for: the confirm is open on it.
    var makingPublic: ShareSet?
    /// The link the owner chose `rotate key…` for: the confirm is open on it.
    var rotatingKey: ShareSet?
    /// A collection's `privacy…` choice that asks first (rotate every key, make every link public).
    var privacyRequest: CollectionPrivacyRequest?
    /// Links whose private link is changing (dimmed; a second tap does nothing).
    var privacyIDs: Set<String> = []
    /// Collections whose `privacy…` change is in flight.
    var collectionPrivacyIDs: Set<String> = []

    init(model: AppModel) {
        self.model = model
    }

    var store: ShareSetStore { model.shareSets }

    /// Collections are offered only while the server has them.
    var collectionsEnabled: Bool { model.capabilities.shareCollections }

    // MARK: sets (section 28): groups of collections

    /// Sets are offered only while the server has them.
    var setsEnabled: Bool { model.capabilities.shareGroups }
    /// The set chip that is on in the collections section: only its collections show. Nil shows every collection.
    var selectedSetID: String?
    /// The name alert for a new set (with the collection it was made from, if any) or a rename.
    var naming: SetNaming?
    /// The set the owner chose `delete set` for: the confirm is open on it.
    var deletingSet: CollectionGroup?

    enum SetNaming: Identifiable, Equatable {
        case create(including: String?)
        case rename(CollectionGroup)
        var id: String {
            switch self {
            case .create(let c): return "create-\(c ?? "")"
            case .rename(let g): return "rename-\(g.id)"
            }
        }
    }

    /// The set the chips have on, while it still exists.
    var selectedSet: CollectionGroup? { selectedSetID.flatMap { store.group($0) } }

    /// The collections the section shows: every one, or the selected set's.
    var shownCollections: [ShareCollection] {
        guard setsEnabled, let set = selectedSet else { return store.collections }
        return store.collections(in: set)
    }

    func copyAll(_ set: CollectionGroup, shell: ShellActions) {
        guard let text = store.linksText(in: set) else { return }
        Pasteboard.copy(text)
        shell.showStatus(Copy.Media.copied)
        copiedToken += 1
    }

    /// The name alert's `create` / `save`.
    func finishNaming(_ request: SetNaming, name: String, shell: ShellActions) {
        guard let clean = CollectionGroupRule.cleanName(name) else { return }
        Task {
            do {
                switch request {
                case .create(let collectionID):
                    let set = try await store.createGroup(name: clean, collectionIDs: collectionID.map { [$0] } ?? [])
                    selectedSetID = set.id
                    shell.showStatus(Copy.Sets.created)
                case .rename(let set):
                    try await store.renameGroup(set.id, to: clean)
                    shell.showStatus(Copy.Sets.renamed)
                }
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Sets.message(for: error))
                failedToken += 1
            }
        }
    }

    /// A collection's `sets` menu: in the set → take it out, not in it → put it in.
    func toggle(_ collection: ShareCollection, in set: CollectionGroup, shell: ShellActions) {
        Task {
            do {
                if set.contains(collection.id) {
                    try await store.removeCollection(collection.id, from: set.id)
                    shell.showStatus(Copy.Sets.removed)
                } else {
                    try await store.addCollection(collection.id, to: set.id)
                    shell.showStatus(Copy.Sets.added)
                }
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Sets.message(for: error))
                failedToken += 1
            }
        }
    }

    func delete(_ set: CollectionGroup, shell: ShellActions) {
        Task {
            do {
                try await store.deleteGroup(set.id)
                if selectedSetID == set.id { selectedSetID = nil }
                shell.showStatus(Copy.Sets.deleted)
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Sets.message(for: error))
                failedToken += 1
            }
        }
    }

    // MARK: links

    /// The usual copy: the link on the pasteboard and `copied` over the shell.
    func copy(_ link: ShareSet, shell: ShellActions) {
        Pasteboard.copy(link.url.absoluteString)
        shell.showStatus(Copy.Media.copied)
        copiedToken += 1
        copiedID = link.id
        let token = copiedToken
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedToken == token { copiedID = nil }
        }
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

    // MARK: private links (APP-API-CONTRACT 36)

    /// Badges and the privacy actions are offered only while the server has private links.
    var privateLinksEnabled: Bool { model.capabilities.privateLinks }

    /// `make private`: the link's private link goes on and is copied.
    func makePrivate(_ link: ShareSet, shell: ShellActions) {
        guard !privacyIDs.contains(link.id) else { return }
        privacyIDs.insert(link.id)
        Task {
            defer { privacyIDs.remove(link.id) }
            do {
                let key = try await store.makePrivate(link.id)
                copied(key.url, id: link.id, status: Copy.PrivateLinks.copiedPrivate, shell: shell)
            } catch {
                shell.showStatus(Copy.PrivateLinks.message(for: error))
                failedToken += 1
            }
        }
    }

    /// `make public…` (after the confirm): the private link stops and the public address opens again.
    func makePublic(_ link: ShareSet, shell: ShellActions) {
        guard !privacyIDs.contains(link.id) else { return }
        privacyIDs.insert(link.id)
        Task {
            defer { privacyIDs.remove(link.id) }
            do {
                try await store.makePublic(link.id)
                shell.showStatus(Copy.PrivateLinks.madePublic)
                doneToken += 1
            } catch {
                shell.showStatus(Copy.PrivateLinks.message(for: error))
                failedToken += 1
            }
        }
    }

    /// `rotate key…` (after the confirm): a new key, copied; the old one stops at once.
    func rotateKey(_ link: ShareSet, shell: ShellActions) {
        guard !privacyIDs.contains(link.id) else { return }
        privacyIDs.insert(link.id)
        Task {
            defer { privacyIDs.remove(link.id) }
            do {
                let key = try await store.rotate(link.id)
                copied(key.url, id: link.id, status: Copy.PrivateLinks.copiedNewKey, shell: shell)
            } catch {
                shell.showStatus(Copy.PrivateLinks.message(for: error))
                failedToken += 1
            }
        }
    }

    /// A collection's `privacy…`: every live link made private (no confirm: it can be undone and nothing breaks for
    /// anyone holding a private link), or, after the confirm, every key rotated or every link made public.
    func choosePrivacy(_ change: CollectionPrivacy, for collection: ShareCollection, shell: ShellActions) {
        if change == .makePrivate {
            setPrivacy(change, of: collection, shell: shell)
        } else {
            privacyRequest = CollectionPrivacyRequest(collection: collection, change: change)
        }
    }

    func setPrivacy(_ change: CollectionPrivacy, of collection: ShareCollection, shell: ShellActions) {
        guard !collectionPrivacyIDs.contains(collection.id) else { return }
        collectionPrivacyIDs.insert(collection.id)
        let ids = Set(collection.setIDs)
        privacyIDs.formUnion(ids)
        Task {
            defer {
                collectionPrivacyIDs.remove(collection.id)
                privacyIDs.subtract(ids)
            }
            do {
                let links = try await store.setPrivacy(of: collection.id, change)
                switch change {
                case .makePrivate: shell.showStatus(Copy.PrivateLinks.madeEveryPrivate(links.count))
                case .rotate: shell.showStatus(Copy.PrivateLinks.rotatedEvery(links.count))
                case .makePublic: shell.showStatus(Copy.PrivateLinks.madeEveryPublic)
                }
                doneToken += 1
            } catch {
                shell.showStatus(Copy.Collections.message(for: error))
                failedToken += 1
            }
        }
    }

    /// Whether the collection's `privacy…` choices are offered: it has loaded links and no change is running on it.
    func canChangePrivacy(_ collection: ShareCollection) -> Bool {
        store.linksText(in: collection) != nil && !collectionPrivacyIDs.contains(collection.id)
    }

    /// A private link that was just made or rotated: on the pasteboard, its row says "copied", the status and the
    /// success haptic.
    private func copied(_ url: URL, id: String, status: String, shell: ShellActions) {
        Pasteboard.copy(url.absoluteString)
        shell.showStatus(status)
        copiedToken += 1
        copiedID = id
        let token = copiedToken
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedToken == token { copiedID = nil }
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
    /// The set name being typed in the name alert.
    @State private var setName = ""

    func body(content: Content) -> some View {
        content
            .alert(
                namingTitle, isPresented: namingPresented, presenting: controller.naming
            ) { request in
                TextField(Copy.Sets.namePlaceholder, text: $setName)
                Button(isRename(request) ? Copy.Sets.save : Copy.Sets.create) {
                    controller.finishNaming(request, name: setName, shell: shell)
                }
                Button(Copy.cancel, role: .cancel) {}
            }
            .onChange(of: controller.naming) { _, request in
                if case .rename(let set) = request { setName = set.name } else if request != nil { setName = "" }
            }
            .confirmationDialog(
                controller.deletingSet.map { Copy.Sets.deleteTitle($0.name) } ?? "", isPresented: deletingSetPresented,
                titleVisibility: .visible, presenting: controller.deletingSet
            ) { set in
                Button(Copy.Sets.delete, role: .destructive) { controller.delete(set, shell: shell) }
                Button(Copy.Collections.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.Sets.deleteMessage)
            }
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
            .confirmationDialog(
                Copy.PrivateLinks.makePublicTitle, isPresented: makingPublicPresented, titleVisibility: .visible,
                presenting: controller.makingPublic
            ) { link in
                Button(Copy.PrivateLinks.makePublicConfirm, role: .destructive) { controller.makePublic(link, shell: shell) }
                Button(Copy.Links.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.PrivateLinks.makePublicMessage)
            }
            .confirmationDialog(
                Copy.PrivateLinks.rotateTitle, isPresented: rotatingKeyPresented, titleVisibility: .visible,
                presenting: controller.rotatingKey
            ) { link in
                Button(Copy.PrivateLinks.rotateConfirm, role: .destructive) { controller.rotateKey(link, shell: shell) }
                Button(Copy.Links.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.PrivateLinks.rotateMessage)
            }
            .confirmationDialog(
                privacyTitle, isPresented: privacyPresented, titleVisibility: .visible,
                presenting: controller.privacyRequest
            ) { request in
                Button(request.change == .rotate ? Copy.PrivateLinks.everyRotateConfirm : Copy.PrivateLinks.everyPublicConfirm,
                       role: .destructive) {
                    controller.setPrivacy(request.change, of: request.collection, shell: shell)
                }
                Button(Copy.Collections.keep, role: .cancel) {}
            } message: { request in
                Text(request.change == .rotate ? Copy.PrivateLinks.everyRotateMessage : Copy.PrivateLinks.everyPublicMessage)
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

    private var makingPublicPresented: Binding<Bool> {
        Binding(get: { controller.makingPublic != nil }, set: { if !$0 { controller.makingPublic = nil } })
    }

    private var rotatingKeyPresented: Binding<Bool> {
        Binding(get: { controller.rotatingKey != nil }, set: { if !$0 { controller.rotatingKey = nil } })
    }

    private var privacyPresented: Binding<Bool> {
        Binding(get: { controller.privacyRequest != nil }, set: { if !$0 { controller.privacyRequest = nil } })
    }

    private var privacyTitle: String {
        controller.privacyRequest?.change == .rotate ? Copy.PrivateLinks.everyRotateTitle : Copy.PrivateLinks.everyPublicTitle
    }

    private var rerollingPresented: Binding<Bool> {
        Binding(get: { controller.rerolling != nil }, set: { if !$0 { controller.rerolling = nil } })
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { controller.deleting != nil }, set: { if !$0 { controller.deleting = nil } })
    }

    private var deletingSetPresented: Binding<Bool> {
        Binding(get: { controller.deletingSet != nil }, set: { if !$0 { controller.deletingSet = nil } })
    }

    private var namingPresented: Binding<Bool> {
        Binding(get: { controller.naming != nil }, set: { if !$0 { controller.naming = nil } })
    }

    private var namingTitle: String {
        if case .rename = controller.naming { return Copy.Sets.renameTitle }
        return Copy.Sets.newTitle
    }

    private func isRename(_ request: LinksController.SetNaming) -> Bool {
        if case .rename = request { return true }
        return false
    }
}

extension View {
    func linkPresentations(_ controller: LinksController) -> some View {
        modifier(LinkPresentations(controller: controller))
    }
}
