import CobaltKit
import SwiftUI

// A collection's screen (APP-API-CONTRACT section 26): its links as the same rows the links tab has (copy, share,
// revoke), plus "remove from collection" (swipe on iPhone and iPad, the context menu and a button on the Mac). The
// toolbar menu renames, rerolls all its links and deletes it. Deleting and rerolling ask first; removing a link does not
// (it is reversible). Pushed on a `NavigationStack` on every platform, so the Mac sidebar gets no child rows.

struct CollectionScreen: View {
    let model: AppModel
    let collectionID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @State private var controller: LinksController
    /// The link a card opened (APP-API-CONTRACT 41.4).
    @State private var openedLink: LinkRoute?

    init(model: AppModel, collectionID: String) {
        self.model = model
        self.collectionID = collectionID
        _controller = State(initialValue: LinksController(model: model))
    }

    private var store: ShareSetStore { model.shareSets }
    private var collection: ShareCollection? { store.collection(collectionID) }

    var body: some View {
        Group {
            if let collection {
                content(collection)
            } else {
                Color.clear      // deleted (here or elsewhere): the pop below is on its way
            }
        }
        .background(CobaltColor.bg)
        .navigationTitle(collection?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let collection {
                ToolbarItem(placement: .primaryAction) {
                    if controller.rerollingIDs.contains(collection.id) || controller.collectionPrivacyIDs.contains(collection.id) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Copy.Collections.rerolling)
                    } else {
                        Button(Copy.Collections.copyAll, systemImage: Symbol.collectionCopyAll) {
                            controller.copyAll(collection, shell: shell)
                        }
                        .labelStyle(.iconOnly)
                        .disabled(controller.store.linksText(in: collection) == nil)
                        .help(Copy.Collections.copyAll)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(Copy.Collections.rename, systemImage: Symbol.collectionRename) {
                            controller.sheet = .rename(collection)
                        }
                        Button(Copy.Collections.reroll, systemImage: Symbol.collectionReroll) {
                            controller.rerolling = collection
                        }
                        .disabled(!controller.canReroll(collection))
                        if controller.privateLinksEnabled {
                            CollectionPrivacyMenu(collection: collection, controller: controller)
                        }
                        Divider()
                        Button(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive) {
                            controller.deleting = collection
                        }
                    } label: {
                        Label(Copy.Collections.menu, systemImage: Symbol.collectionMenu)
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(Copy.Collections.menu)
                    #if os(macOS)
                    .help(Copy.Collections.menu)
                    #endif
                }
            }
        }
        .onChange(of: collection == nil) { _, gone in
            if gone { dismiss() }
        }
        .navigationDestination(item: $openedLink) { route in
            LinkScreen(model: model, setID: route.id)
        }
        .linkPresentations(controller)
    }

    @ViewBuilder
    private func content(_ collection: ShareCollection) -> some View {
        let links = store.sets(in: collection)
        if links.isEmpty {
            ScrollView {
                ContentUnavailableView {
                    Label(Copy.Collections.emptyTitle, systemImage: Symbol.collection).font(CobaltType.body)
                } description: {
                    Text(Copy.Collections.emptyBody).font(CobaltType.caption)
                }
                .padding(.top, 60)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh() }
        } else {
            // no collections line inside a collection: only the private links are looked up
            let lookup = LinkRowLookup(store: store, collectionsEnabled: false)
            let copiedID = controller.copiedID
            List {
                ForEach(links) { link in
                    LinkItemRow(
                        link: link, collection: collection, controller: controller, lookup: lookup, copied: copiedID == link.id,
                        open: opener(link))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .motion(Motion.rows, value: links.map(\.id))
            .refreshable { await store.refresh() }
        }
    }
}

extension CollectionScreen {
    /// What a card's tap does: open the link's screen, only while the server edits links (`features.share_set_edit`).
    fileprivate func opener(_ link: ShareSet) -> (() -> Void)? {
        guard model.capabilities.shareSetEdit else { return nil }
        let id = link.id
        return { openedLink = LinkRoute(id: id) }
    }
}
