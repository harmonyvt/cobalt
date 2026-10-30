import CobaltKit
import SwiftUI

// The links tab (APP-API-CONTRACT section 24): every gallery share link the owner made, newest first, each as a card
// with its files as a 2x2 cover, its title and date, the collections it is in, and a copy button (share, revoke and
// collections by swipe or the long press). Revoke asks first. The list is
// `model.shareSets` (the library's select bar adds to it, a refresh on appear and a pull keep it honest). While the
// server has `features.share_collections` (section 26) a "collections" section sits at the top of the list: a grid of
// folder cards (a push to `CollectionScreen`) and a "new collection" card. The row menus gain "add to collection".
// With `features.share_groups` (section 28) chips over the folders pick a set (a group of collections).

struct LinksScreen: View {
    let model: AppModel

    @Environment(\.shell) private var shell
    @State private var controller: LinksController
    /// The collection a folder card opened (a button, not a `NavigationLink`: several links in one list row all fired
    /// on a tap).
    @State private var openedCollection: CollectionRoute?
    /// The link a card opened (APP-API-CONTRACT 41.4), the same way.
    @State private var openedLink: LinkRoute?

    init(model: AppModel) {
        self.model = model
        _controller = State(initialValue: LinksController(model: model))
    }

    private var store: ShareSetStore { model.shareSets }

    private enum Phase { case loading, failed, empty, list }

    private var phase: Phase {
        if !store.sets.isEmpty || (controller.collectionsEnabled && !store.collections.isEmpty) { return .list }
        switch store.state {
        case .idle, .loading: return .loading
        case .failed: return .failed
        case .loaded: return .empty
        }
    }

    var body: some View {
        content
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Links.title)
            .toolbar {
                #if os(iOS)
                QueueToolbarItem(model: model)
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button(Copy.Links.refresh, systemImage: Symbol.retry) { Task { await store.refresh() } }
                        .disabled(store.state == .loading)
                        #if os(macOS)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(Copy.Links.refresh)
                        #endif
                }
            }
            .task { await store.refresh() }
            .navigationDestination(for: CollectionRoute.self) { route in
                CollectionScreen(model: model, collectionID: route.id)
            }
            .navigationDestination(item: $openedCollection) { route in
                CollectionScreen(model: model, collectionID: route.id)
            }
            .navigationDestination(item: $openedLink) { route in
                LinkScreen(model: model, setID: route.id)
            }
            .linkPresentations(controller)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(Copy.Links.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed:
            ContentUnavailableView {
                Label(Copy.Links.failedTitle, systemImage: Symbol.error).font(CobaltType.body)
            } actions: {
                Button(Copy.Links.retry, systemImage: Symbol.retry) { Task { await store.refresh() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .empty:
            ScrollView {
                ContentUnavailableView {
                    Label(Copy.Links.emptyTitle, systemImage: Symbol.linksEmpty).font(CobaltType.body)
                } description: {
                    Text(Copy.Links.emptyBody).font(CobaltType.caption)
                }
                .padding(.top, 60)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh() }
        case .list:
            list
        }
    }

    // MARK: the list

    private var list: some View {
        List {
            if case .failed = store.state {
                Text(Copy.Links.staleLine)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if controller.collectionsEnabled {
                Section {
                    // the sets over the folders: a chip on shows only that set's collections
                    if controller.setsEnabled {
                        CollectionSetChips(store: store, controller: controller)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                    }
                    // the collections as folders, two to a row, then "new collection"
                    CollectionFolderGrid(store: store, controller: controller) { openedCollection = CollectionRoute(id: $0.id) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                } header: {
                    SectionLabel(text: Copy.Collections.section)
                }
                .motion(Motion.rows, value: store.collections.map(\.id))
            }
            Section {
                ForEach(store.sets) { link in
                    LinkItemRow(link: link, collection: nil, controller: controller, open: opener(link))
                        .listRowSeparator(.hidden)
                }
            } header: {
                if controller.collectionsEnabled { SectionLabel(text: Copy.Collections.linksHeader) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .motion(Motion.rows, value: store.sets.map(\.id))
        .refreshable { await store.refresh() }
    }
}

extension LinksScreen {
    /// What a card's tap does: open the link's screen, only while the server edits links (`features.share_set_edit`).
    fileprivate func opener(_ link: ShareSet) -> (() -> Void)? {
        guard model.capabilities.shareSetEdit else { return nil }
        let id = link.id
        return { openedLink = LinkRoute(id: id) }
    }
}

/// A small caption over a list section (lowercase, in the caption colour).
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - one link as a list row

/// A link's row with everything a list gives it: copy and revoke by swipe (iPhone, iPad), the context menu, and, inside
/// a collection, "remove from collection". `collection` is nil in the main list.
struct LinkItemRow: View {
    let link: ShareSet
    let collection: ShareCollection?
    let controller: LinksController
    /// A tap on the card (APP-API-CONTRACT 41.4): opens the link's screen. Nil while the server cannot edit links.
    var open: (() -> Void)? = nil

    @Environment(\.shell) private var shell

    var body: some View {
        LinkRow(link: link, collection: collection, controller: controller, open: open)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: collection != nil) {
                if let collection {
                    Button(Copy.Collections.removeFrom, systemImage: Symbol.collectionRemove) {
                        controller.remove(link, from: collection, shell: shell)
                    }
                    .tint(CobaltColor.focus)
                }
                Button(Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive) { controller.revoking = link }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button(Copy.Links.copyLink, systemImage: Symbol.copyLink) { controller.copy(link, shell: shell) }
                    .tint(CobaltColor.focus)
                if controller.privateLinksEnabled {
                    // a public link goes private at once (and is copied); a private one gets a new key, after the confirm
                    if link.isPrivate {
                        Button(Copy.PrivateLinks.rotateKey, systemImage: Symbol.PrivateLinks.rotate) { controller.rotatingKey = link }
                    } else {
                        Button(Copy.PrivateLinks.makePrivate, systemImage: Symbol.PrivateLinks.makePrivate) {
                            controller.makePrivate(link, shell: shell)
                        }
                    }
                }
            }
            #endif
            .contextMenu { LinkMenu(link: link, collection: collection, controller: controller) }
    }
}

// MARK: - the context menu (iPhone, iPad and Mac)

struct LinkMenu: View {
    let link: ShareSet
    let collection: ShareCollection?
    let controller: LinksController

    @Environment(\.shell) private var shell

    var body: some View {
        Button(Copy.Links.copyLink, systemImage: Symbol.copyLink) { controller.copy(link, shell: shell) }
        ShareLink(item: link.url) { Label(Copy.Links.share, systemImage: Symbol.share) }
        if controller.privateLinksEnabled {
            Divider()
            LinkPrivacyItems(link: link, controller: controller)
        }
        if controller.collectionsEnabled {
            Divider()
            CollectionMenu(link: link, controller: controller)
            if let collection {
                Button(Copy.Collections.removeFrom, systemImage: Symbol.collectionRemove) {
                    controller.remove(link, from: collection, shell: shell)
                }
            }
        }
        Divider()
        Button(Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive) { controller.revoking = link }
    }
}

/// A link's private-link actions (APP-API-CONTRACT 36.6), in its context menu and the Mac row's lock menu: a public link
/// can be made private (copied at once); a private one can get a new key or be made public again (both ask first).
struct LinkPrivacyItems: View {
    let link: ShareSet
    let controller: LinksController

    @Environment(\.shell) private var shell

    var body: some View {
        if link.isPrivate {
            Button(Copy.PrivateLinks.rotateKey, systemImage: Symbol.PrivateLinks.rotate) { controller.rotatingKey = link }
            Button(Copy.PrivateLinks.makePublic, systemImage: Symbol.PrivateLinks.makePublic) { controller.makingPublic = link }
        } else {
            Button(Copy.PrivateLinks.makePrivate, systemImage: Symbol.PrivateLinks.makePrivate) {
                controller.makePrivate(link, shell: shell)
            }
        }
    }
}

/// The `public` / `private` badge of a gallery link (APP-API-CONTRACT 36.6).
struct LinkPrivacyBadge: View {
    let isPrivate: Bool

    var body: some View {
        Label(isPrivate ? Copy.PrivateLinks.badgePrivate : Copy.PrivateLinks.badgePublic,
              systemImage: isPrivate ? Symbol.PrivateLinks.lock : Symbol.PrivateLinks.publicLink)
            .labelStyle(CollectionLineLabel())
            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
            .foregroundStyle(isPrivate ? CobaltColor.text : CobaltColor.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(CobaltColor.elevated))
            .fixedSize()
            .accessibilityLabel(Copy.PrivateLinks.rowA11y(isPrivate: isPrivate))
    }
}

/// "add to collection": a submenu listing the collections, a check on the ones the link is in (a tap puts it in or takes
/// it out), then "new collection…" (opens the sheet with this link ticked). In a context menu it nests as a submenu; on
/// the Mac the row shows it as its own icon button.
struct CollectionMenu: View {
    let link: ShareSet
    let controller: LinksController

    @Environment(\.shell) private var shell

    var body: some View {
        let store = controller.store
        Menu {
            ForEach(store.collections) { collection in
                Toggle(collection.name, isOn: Binding(
                    get: { store.collection(collection.id)?.contains(link.id) ?? false },
                    set: { _ in controller.toggle(link, in: collection, shell: shell) }))
            }
            if !store.collections.isEmpty { Divider() }
            Button(Copy.Collections.newEllipsis, systemImage: Symbol.collectionNew) {
                controller.newCollection(including: link)
            }
        } label: {
            Label(Copy.Collections.addTo, systemImage: Symbol.collectionAdd)
        }
    }
}

// MARK: - a row

/// A card: the files as a 2x2 cover, then the title, the file count and date, the short link, a note when files went
/// private and (in the main list) the collections it is in. iPhone: a labelled copy button at the end (share, revoke and
/// collections by swipe or the long press); Mac: copy, share, a collections menu and revoke buttons.
struct LinkRow: View {
    let link: ShareSet
    let collection: ShareCollection?
    let controller: LinksController
    /// A tap on the card opens the link's screen (APP-API-CONTRACT 41.4); the copy and Mac buttons keep their own taps.
    var open: (() -> Void)? = nil

    @Environment(\.shell) private var shell
    private var busy: Bool { controller.revokingIDs.contains(link.id) || controller.privacyIDs.contains(link.id) }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var privateCount: Int { link.items.count - link.publicItemCount }

    private var note: String? {
        // a private link serves its files whatever their own state (APP-API-CONTRACT 36.2): no "private now" note
        if link.isPrivate { return nil }
        if link.publicItemCount == 0 { return Copy.Links.allPrivate }
        if privateCount > 0 { return Copy.Links.privateNow(privateCount) }
        return nil
    }

    private var shortLink: String {
        let host = link.url.host ?? ""
        return host + link.url.path
    }

    /// The collections the link is in, in the main list only ("memes · for discord"); nil when none.
    private var collectionsLine: String? {
        guard collection == nil, controller.collectionsEnabled else { return nil }
        let names = controller.store.collections(containing: link.id).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private var copied: Bool { controller.copiedID == link.id }

    private func rowLabel(_ when: String) -> String {
        let base = Copy.Links.rowA11y(title: link.displayTitle, files: link.items.count, when: when)
        guard controller.privateLinksEnabled else { return base }
        return "\(base), \(Copy.PrivateLinks.rowA11y(isPrivate: link.isPrivate))"
    }

    var body: some View {
        let when = Format.when(link.createdAt, now: Date())
        HStack(alignment: .center, spacing: 12) {
            LinkCover(items: link.items, side: Platform.isMac ? 64 : 60)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.displayTitle)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    HStack(spacing: 6) {
                        if controller.privateLinksEnabled { LinkPrivacyBadge(isPrivate: link.isPrivate) }
                        Text("\(Copy.Links.fileCount(link.items.count)) · \(when)")
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                    }
                    Text(shortLink)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if link.isPrivate, let opened = controller.store.privateLink(forSet: link.id)?.opened {
                        Text(Copy.PrivateLinks.openedLine(opened))
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .monospacedDigit()
                    }
                    if let note {
                        Text(note)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(link.publicItemCount == 0 ? CobaltColor.errorText : CobaltColor.caption)
                    }
                    if let collectionsLine {
                        Label(collectionsLine, systemImage: Symbol.collection)
                            .labelStyle(CollectionLineLabel())
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.collection)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(rowLabel(when))
                .accessibilityAddTraits(open == nil ? [] : .isButton)
                .accessibilityHint(open == nil ? "" : Copy.LinkEdit.openA11yHint)
                .accessibilityAction { open?() }
                Spacer(minLength: 4)
                buttons
            }
        }
        .padding(10)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { open?() }
        .opacity(busy ? 0.4 : 1)
        .disabled(busy)
        .animation(Motion.fade, value: busy)
    }

    @ViewBuilder
    private var buttons: some View {
        #if os(iOS)
        // copy is what a link is for: a labelled button on every row, not only in the swipe and the menu
        Button { controller.copy(link, shell: shell) } label: {
            Text(copied ? Copy.Media.copied : Copy.Links.copy)
                .font(CobaltType.buttonSmall.weight(.semibold))
                .foregroundStyle(copied ? CobaltColor.text : CobaltColor.onText)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(copied ? CobaltColor.elevated : CobaltColor.text, in: Capsule())
                .contentTransition(.opacity)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(copied ? Copy.Media.copied : Copy.Links.copyLink)
        .animation(Motion.fade, value: copied)
        #else
        HStack(spacing: 2) {
            Button(Copy.Links.copyLink, systemImage: Symbol.copyLink) { controller.copy(link, shell: shell) }
            ShareLink(item: link.url) { Label(Copy.Links.share, systemImage: Symbol.share) }
            if controller.privateLinksEnabled {
                Menu {
                    LinkPrivacyItems(link: link, controller: controller)
                } label: {
                    Label(Copy.PrivateLinks.privacy,
                          systemImage: link.isPrivate ? Symbol.PrivateLinks.lock : Symbol.PrivateLinks.makePrivate)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Copy.PrivateLinks.privacy)
            }
            if controller.collectionsEnabled {
                CollectionMenu(link: link, controller: controller)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                if let collection {
                    Button(Copy.Collections.removeFrom, systemImage: Symbol.collectionRemove) {
                        controller.remove(link, from: collection, shell: shell)
                    }
                }
            }
            Button(Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive) { controller.revoking = link }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(CobaltColor.text)
        .help(Copy.Links.copyLink)
        #endif
    }
}

// MARK: - the cover

/// A set's files, up to four, as a 2x2 square cover (the library's shelf cards, the links tab's cards and collection
/// folders). Empty cells are plain tiles, so a 2-file link still reads as a square.
struct LinkCover: View {
    let items: [ShareSetItem]
    let side: CGFloat
    private let gap: CGFloat = 2

    var body: some View {
        let cell = (side - gap) / 2
        let shown = Array(items.prefix(4))
        VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if index < shown.count {
                            LinkThumb(item: shown[index], side: cell, radius: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(CobaltColor.elevated)
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct LinkThumb: View {
    let item: ShareSetItem
    let side: CGFloat
    var radius: CGFloat = 8

    /// The still to draw: the poster or the image itself; a video with no poster draws a frame of the file.
    private var poster: RemotePoster? {
        if let still = item.thumbnailURL { return RemotePoster(url: still, isVideo: false) }
        if item.isPublic, item.contentType?.lowercased().hasPrefix("video/") == true, let url = item.url {
            return RemotePoster(url: url, isVideo: true)
        }
        return nil
    }

    private var isVideo: Bool { item.contentType?.lowercased().hasPrefix("video/") == true }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(CobaltColor.elevated)
            if !item.isPublic {
                Image(systemName: Symbol.linkFilePrivate)
                    .font(.system(size: side * 0.28))
                    .foregroundStyle(CobaltColor.caption)
            } else if let poster {
                RemoteStill(poster: poster, maxPixel: 240)
            } else {
                Image(systemName: isVideo ? Symbol.typeVideo : Symbol.typeImage)
                    .font(.system(size: side * 0.28))
                    .foregroundStyle(CobaltColor.caption)
            }
            if isVideo, item.isPublic {
                Image(systemName: Symbol.linkFilePlay)
                    .font(.system(size: side * 0.22, weight: .bold))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .padding(side * 0.12)
                    .background(CobaltColor.badgeBack, in: Circle())
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
