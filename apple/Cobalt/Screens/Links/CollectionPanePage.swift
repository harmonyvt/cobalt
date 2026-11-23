import CobaltKit
import SwiftUI

// A collection in the screen pane (apple/CONTRACT-PANE.md section 5, `PaneItem.collection`). Opened from a folder card in
// the links tab. The hero is a file from each of its newest links; the big buttons copy every link, rename, reroll and
// delete (the confirms and the name sheet stay a dialog and a sheet); the body is its links as the tab's own cards, a tap
// opens the link in the pane. Privacy and the sets it is in are menus under the links.

struct CollectionPanePage: View {
    let model: AppModel
    let id: String

    @Environment(Pane.self) private var pane
    @Environment(\.shell) private var shell
    @State private var controller: LinksController

    init(model: AppModel, id: String) {
        self.model = model
        self.id = id
        _controller = State(initialValue: LinksController(model: model))
    }

    private var store: ShareSetStore { model.shareSets }
    private var collection: ShareCollection? { store.collection(id) }

    var body: some View {
        Group {
            if let collection {
                page(collection)
            } else if case .failed = store.state {
                PaneGonePage(message: Copy.LinksPane.cantLoad)
            } else if store.state == .loaded {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task { if store.collections.isEmpty { await store.refresh() } }
        // deleted here or elsewhere: nothing left to show, so the pane hides
        .onChange(of: collection == nil) { _, gone in
            if gone, store.state == .loaded { pane.close() }
        }
        .linkPresentations(controller)
    }

    private func page(_ collection: ShareCollection) -> some View {
        let links = store.sets(in: collection)
        let busy = controller.rerollingIDs.contains(collection.id) || controller.collectionPrivacyIDs.contains(collection.id)
        return PanePage(
            title: collection.name, subtitle: Copy.LinksPane.linksLine(links.count)
        ) {
            CollectionPaneHero(links: links)
        } controls: {
            CollectionPaneControls(actions: actions(collection, busy: busy))
        } body: {
            CollectionPaneLinks(collection: collection, links: links, controller: controller)
        }
    }

    private func actions(_ collection: ShareCollection, busy: Bool) -> [PaneAction] {
        [
            PaneAction(Copy.Collections.copyAll, systemImage: Symbol.collectionCopyAll,
                       disabled: controller.store.linksText(in: collection) == nil || busy) {
                controller.copyAll(collection, shell: shell)
            },
            PaneAction(Copy.Collections.rename, systemImage: Symbol.collectionRename, needsServer: true, disabled: busy) {
                controller.sheet = .rename(collection)
            },
            PaneAction(Copy.Collections.reroll, systemImage: Symbol.collectionReroll, needsServer: true,
                       disabled: !controller.canReroll(collection) || busy) {
                controller.rerolling = collection
            },
            PaneAction(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive,
                       needsServer: true, disabled: busy) {
                controller.deleting = collection
            },
        ]
    }
}

private struct CollectionPaneControls: View {
    let actions: [PaneAction]
    @Environment(\.paneShape) private var shape

    var body: some View {
        if shape != .bar { PaneActionGrid(actions) }
    }
}

/// A file from each of the newest links (the folder card's cover, big).
private struct CollectionPaneHero: View {
    let links: [ShareSet]

    @Environment(\.paneShape) private var shape
    @Environment(\.paneHeaderHeight) private var headerHeight

    private var items: [ShareSetItem] {
        links.prefix(4).compactMap { $0.items.first(where: \.isPublic) ?? $0.items.first }
    }

    var body: some View {
        switch shape {
        case .bar:
            LinkCover(items: items, side: 40)
        case .tall:
            grid.aspectRatio(1, contentMode: .fit)
        case .wide, .split:
            grid.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var grid: some View {
        if items.isEmpty {
            Image(systemName: Symbol.collection)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CobaltColor.collection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, headerHeight)
                .accessibilityHidden(true)
        } else {
            LinkTileGrid(count: items.count) { index, side in
                LinkThumb(item: items[index], side: side, radius: 12, maxPixel: 640)
            }
            .padding(.top, headerHeight)
            .padding([.horizontal, .bottom], 12)
            .accessibilityHidden(true)
        }
    }
}

/// The collection's links as the tab's cards, then its privacy and sets menus.
private struct CollectionPaneLinks: View {
    let collection: ShareCollection
    let links: [ShareSet]
    let controller: LinksController

    @Environment(Pane.self) private var pane: Pane?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: Copy.Collections.linksHeader)
            if links.isEmpty {
                VStack(spacing: 4) {
                    Text(Copy.Collections.emptyTitle).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text)
                    Text(Copy.Collections.emptyBody).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            } else {
                let lookup = LinkRowLookup(store: controller.store, collectionsEnabled: false)
                let copiedID = controller.copiedID
                ForEach(links) { link in
                    LinkRow(
                        link: link, collection: collection, controller: controller, lookup: lookup,
                        copied: copiedID == link.id, open: { pane?.open(.link(link.id)) })
                        .contextMenu { LinkMenu(link: link, collection: collection, controller: controller) }
                }
            }
            if controller.privateLinksEnabled || controller.setsEnabled {
                HStack(spacing: 8) {
                    if controller.privateLinksEnabled {
                        CollectionPrivacyMenu(collection: collection, controller: controller)
                    }
                    if controller.setsEnabled {
                        CollectionSetsMenu(collection: collection, controller: controller)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
    }
}

#if DEBUG
// MARK: - previews

private struct LoadedCollection<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: () -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready { content() } else { Color.clear }
        }
        .task {
            await model.shareSets.refresh()
            ready = true
        }
    }
}

private struct CollectionPaneShape<Content: View>: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    @ViewBuilder let content: Content
    @State private var pane = Pane(route: PaneRoute(item: .collection("PrEvIeWcoll00001"), state: .screen))

    var body: some View {
        NavigationStack { content }
            .environment(\.paneShape, shape)
            .environment(\.paneHinge, hinge)
            .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
            .background(CobaltColor.bg)
            .environment(pane)
    }
}

#Preview("collection pane · tall", traits: .fixedLayout(width: 440, height: 900)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedCollection(model: model) {
            CollectionPaneShape(shape: .tall) { CollectionPanePage(model: model, id: "PrEvIeWcoll00001") }
        }
    }
}
#Preview("collection pane · dark, AX3", traits: .fixedLayout(width: 440, height: 900)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedCollection(model: model) {
            CollectionPaneShape(shape: .tall) { CollectionPanePage(model: model, id: "PrEvIeWcoll00001") }
        }
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
#Preview("collection pane · spanned, tall duo", traits: .fixedLayout(width: 640, height: 900)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedCollection(model: model) {
            CollectionPaneShape(shape: .split(.media), hinge: PaneHinge(axis: .horizontal, position: 450)) {
                CollectionPanePage(model: model, id: "PrEvIeWcoll00001")
            }
        }
    }
}
#Preview("collection pane · gone", traits: .fixedLayout(width: 440, height: 600)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedCollection(model: model) {
            CollectionPaneShape(shape: .tall) { CollectionPanePage(model: model, id: "nope") }
        }
    }
}
#endif
