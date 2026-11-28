import CobaltKit
import SwiftUI

// The links tab (APP-API-CONTRACT section 24): every gallery share link the owner made, newest first, each as a card
// with its files as a 2x2 cover, its title and date, the collections it is in, and a copy button (share, revoke and
// collections by swipe or the long press). Revoke asks first. The list is
// `model.shareSets` (the library's select bar adds to it, a refresh on appear and a pull keep it honest). While the
// server has `features.share_collections` (section 26) a "collections" section sits at the top of the list: a grid of
// folder cards (a push to `CollectionScreen`) and a "new collection" card. The row menus gain "add to collection".
// With `features.share_groups` (section 28) chips over the folders pick a set (a group of collections).
//
// A card's tap and a folder's tap open the link / collection in the screen pane (`pane.open(.link(id))`,
// `.collection(id)`; apple/CONTRACT-PANE.md section 5): the list keeps its whole width, the pane sits beside it (a sheet
// on the iPhone), and spanned it shows the link's files across both screens.

struct LinksScreen: View {
    let model: AppModel

    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?
    @State private var controller: LinksController

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
                        .labelStyle(.iconOnly)
                        .disabled(store.state == .loading)
                        #if os(macOS)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(Copy.Links.refresh)
                        #endif
                }
            }
            .task { await store.refresh() }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if case .failed = store.state {
                    Text(Copy.Links.staleLine)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                }

                if controller.collectionsEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        collectionsHeader
                        if controller.setsEnabled {
                            CollectionSetChips(store: store, controller: controller)
                        }
                        CollectionFolderGrid(store: store, controller: controller) { pane?.open(.collection($0.id)) }
                    }
                    .motion(Motion.rows, value: store.collections.map(\.id))
                }

                // looked up once for the list, not once per row; only the copied row changes on a copy
                let lookup = LinkRowLookup(store: store, collectionsEnabled: controller.collectionsEnabled)
                let copiedID = controller.copiedID
                VStack(alignment: .leading, spacing: 10) {
                    if controller.collectionsEnabled {
                        HStack(spacing: 6) {
                            SectionLabel(text: Copy.Collections.linksHeader)
                            SectionCountPill(count: store.sets.count)
                        }
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(store.sets) { link in
                            LinkRow(
                                link: link, collection: nil, controller: controller, lookup: lookup,
                                copied: copiedID == link.id, open: opener(link))
                                .contextMenu { LinkMenu(link: link, collection: nil, controller: controller) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .motion(Motion.rows, value: store.sets.map(\.id))
        .refreshable { await store.refresh() }
    }

    private var collectionsHeader: some View {
        HStack(spacing: 6) {
            SectionLabel(text: Copy.Collections.section)
            SectionCountPill(count: controller.shownCollections.count)
            Spacer(minLength: 8)
            if controller.selectedSet == nil {
                Button { controller.newCollection(including: nil) } label: {
                    Label(Copy.Collections.new, systemImage: Symbol.collectionNew)
                        .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.collection)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(CobaltColor.collection.opacity(0.14)).interactive(), in: .capsule)
                .overlay(
                    Capsule()
                        .strokeBorder(CobaltColor.collection.opacity(0.3), lineWidth: 0.6)
                        .allowsHitTesting(false)
                )
            }
        }
    }
}

/// Subtle monospaced count badge next to a section label.
struct SectionCountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
            .monospacedDigit()
            .foregroundStyle(CobaltColor.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(CobaltColor.elevated.opacity(0.75), in: Capsule())
            .accessibilityHidden(true)
    }
}

extension LinksScreen {
    /// What a card's tap does: open the link in the pane (its files, copy, privacy, collections; editing needs
    /// `features.share_set_edit`, which the page checks itself).
    fileprivate func opener(_ link: ShareSet) -> (() -> Void)? {
        guard let pane else { return nil }
        let id = link.id
        return { pane.open(.link(id)) }
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

/// What the rows look up in the store, worked out once per list.
struct LinkRowLookup {
    /// A link's collection names (main list only).
    var collectionNames: [String: [String]] = [:]
    var privateLinks: [String: PrivateLink] = [:]

    @MainActor
    init(store: ShareSetStore, collectionsEnabled: Bool) {
        collectionNames = collectionsEnabled ? store.collectionNamesBySet() : [:]
        privateLinks = store.privateLinksBySet()
    }
}

/// A link's row with everything a list gives it: copy and revoke by swipe (iPhone, iPad), the context menu, and, inside
/// a collection, "remove from collection". `collection` is nil in the main list.
struct LinkItemRow: View {
    let link: ShareSet
    let collection: ShareCollection?
    let controller: LinksController
    let lookup: LinkRowLookup
    let copied: Bool
    /// A tap on the card (APP-API-CONTRACT 41.4): opens the link's screen. Nil while the server cannot edit links.
    var open: (() -> Void)? = nil

    @Environment(\.shell) private var shell

    var body: some View {
        LinkRow(link: link, collection: collection, controller: controller, lookup: lookup, copied: copied, open: open)
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
    let lookup: LinkRowLookup
    let copied: Bool
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
        let names = lookup.collectionNames[link.id] ?? []
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private func rowLabel(_ when: String) -> String {
        let base = Copy.Links.rowA11y(title: link.displayTitle, files: link.items.count, when: when)
        guard controller.privateLinksEnabled else { return base }
        return "\(base), \(Copy.PrivateLinks.rowA11y(isPrivate: link.isPrivate))"
    }

    var body: some View {
        let when = Format.when(link.createdAt, now: Date())
        HStack(alignment: .center, spacing: 12) {
            LinkCover(items: link.items, side: Platform.isMac ? 66 : 62, totalCount: link.items.count)
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
                    if link.isPrivate, let opened = lookup.privateLinks[link.id]?.opened {
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
                            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                            .foregroundStyle(CobaltColor.collection)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(CobaltColor.collectionBack.opacity(0.75), in: Capsule())
                            .padding(.top, 1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(rowLabel(when))
                .accessibilityAddTraits(open == nil ? [] : .isButton)
                .accessibilityHint(open == nil ? "" : Copy.LinkEdit.openA11yHint)
                .accessibilityAction { open?() }
                .accessibilityIdentifier("links.row")
                Spacer(minLength: 4)
                buttons
            }
        }
        .padding(10)
        .glassEffect(.regular.tint(CobaltColor.surface.opacity(0.55)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CobaltColor.hairline, lineWidth: 0.7)
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { open?() }
        .opacity(busy ? 0.4 : 1)
        .disabled(busy)
        .animation(Motion.fade, value: busy)
    }

    @ViewBuilder
    private var buttons: some View {
        #if os(iOS)
        // copy is what a link is for: the row's one filled icon, on every row, not only in the swipe and the menu; a copy
        // turns it into the green tick (the name stays "copy share link")
        Button { controller.copy(link, shell: shell) } label: {
            Label(Copy.Links.copyLink, systemImage: copied ? Symbol.Library.copied : Symbol.copyLink)
        }
        .buttonStyle(.cobaltIcon(.small, prominent: true, state: copied ? .done : .idle))
        #else
        IconRow(spacing: 6, alignment: .trailing) {
            Button { controller.copy(link, shell: shell) } label: {
                Label(Copy.Links.copyLink, systemImage: copied ? Symbol.Library.copied : Symbol.copyLink)
            }
            .buttonStyle(.cobaltIcon(.small, prominent: true, state: copied ? .done : .idle))
            ShareLink(item: link.url) { Label(Copy.Links.share, systemImage: Symbol.share) }
                .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.linkBlue))
            if controller.privateLinksEnabled {
                Menu {
                    LinkPrivacyItems(link: link, controller: controller)
                } label: {
                    Label(Copy.PrivateLinks.privacy,
                          systemImage: link.isPrivate ? Symbol.PrivateLinks.lock : Symbol.PrivateLinks.makePrivate)
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(CobaltColor.text)
                .iconName(Copy.PrivateLinks.privacy)
            }
            if controller.collectionsEnabled {
                // the menu's label is shared with the context menu's submenu (words there), so the icon-only style goes
                // on the menu here
                CollectionMenu(link: link, controller: controller)
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(CobaltColor.collection)
                    .iconName(Copy.Collections.addTo)
                if let collection {
                    Button { controller.remove(link, from: collection, shell: shell) } label: {
                        Label(Copy.Collections.removeFrom, systemImage: Symbol.collectionRemove)
                    }
                    .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.collection))
                }
            }
            Button(role: .destructive) { controller.revoking = link } label: {
                Label(Copy.Links.revoke, systemImage: Symbol.revokeLink)
            }
            .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.errorText))
        }
        .fixedSize()
        #endif
    }
}

// MARK: - adaptive covers (0 / 1 / 2 / 3 / 4-up)

/// A set's files as an adaptive square cover (0 = icon placeholder, 1 = full bleed, 2 = 2-up split,
/// 3 = 1 hero + 2 stacked, 4+ = 2x2 mosaic with optional `+N` overflow badge). Zero empty gray cells.
struct LinkCover: View {
    let items: [ShareSetItem]
    let side: CGFloat
    var totalCount: Int? = nil
    private let gap: CGFloat = 2

    private var overflow: Int {
        max(0, (totalCount ?? items.count) - 4)
    }

    var body: some View {
        let shown = Array(items.prefix(4))
        let outerRadius: CGFloat = side <= 44 ? 8 : 11
        Group {
            switch shown.count {
            case 0:
                ZStack {
                    CobaltColor.elevated
                    Image(systemName: Symbol.typeImage)
                        .font(.system(size: side * 0.3, weight: .medium))
                        .foregroundStyle(CobaltColor.caption.opacity(0.8))
                }
            case 1:
                LinkMediaTile(item: shown[0], radius: outerRadius, maxPixel: 260, iconSize: side * 0.24)
            case 2:
                HStack(spacing: gap) {
                    LinkMediaTile(item: shown[0], radius: 4, maxPixel: 220, iconSize: side * 0.16)
                    LinkMediaTile(item: shown[1], radius: 4, maxPixel: 220, iconSize: side * 0.16)
                }
            case 3:
                let leadW = ((side - gap) * 0.56).rounded(.down)
                let trailW = side - gap - leadW
                let smallH = (side - gap) / 2
                HStack(spacing: gap) {
                    LinkMediaTile(item: shown[0], radius: 4, maxPixel: 240, iconSize: side * 0.18)
                        .frame(width: leadW, height: side)
                    VStack(spacing: gap) {
                        LinkMediaTile(item: shown[1], radius: 4, maxPixel: 180, iconSize: side * 0.14)
                            .frame(width: trailW, height: smallH)
                        LinkMediaTile(item: shown[2], radius: 4, maxPixel: 180, iconSize: side * 0.14)
                            .frame(width: trailW, height: smallH)
                    }
                }
            default:
                let cell = (side - gap) / 2
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        LinkMediaTile(item: shown[0], radius: 4, maxPixel: 180, iconSize: cell * 0.28)
                            .frame(width: cell, height: cell)
                        LinkMediaTile(item: shown[1], radius: 4, maxPixel: 180, iconSize: cell * 0.28)
                            .frame(width: cell, height: cell)
                    }
                    HStack(spacing: gap) {
                        LinkMediaTile(item: shown[2], radius: 4, maxPixel: 180, iconSize: cell * 0.28)
                            .frame(width: cell, height: cell)
                        LinkMediaTile(item: shown[3], radius: 4, maxPixel: 180, iconSize: cell * 0.28)
                            .frame(width: cell, height: cell)
                            .overlay {
                                if overflow > 0 {
                                    ZStack {
                                        Color.black.opacity(0.52)
                                        Text("+\(overflow)")
                                            .font(Font.cobalt(max(9.5, side * 0.17), .semibold, relativeTo: .caption2))
                                            .monospacedDigit()
                                            .foregroundStyle(.white)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                            }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .accessibilityHidden(true)
    }
}

/// Rectangular 16:10 adaptive media cover for Glassy Bento collection folder cards:
/// 0 = sleek amber folder canvas, 1 = full-bleed hero, 2 = 50/50 split, 3 = hero + 2 stacked,
/// 4+ = 2x2 mosaic with Clear Liquid Glass `+N` overflow badge.
struct BentoMediaCover: View {
    let items: [ShareSetItem]
    let totalCount: Int
    var cornerRadius: CGFloat = 12
    private let gap: CGFloat = 2

    private var overflow: Int { max(0, totalCount - 4) }

    var body: some View {
        let shown = Array(items.prefix(4))
        Color.clear
            .aspectRatio(1.6, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    let h = max(1, geo.size.height)
                    Group {
                        switch shown.count {
                        case 0:
                            ZStack {
                                LinearGradient(
                                    colors: [CobaltColor.collectionBack.opacity(0.7), CobaltColor.elevated.opacity(0.5)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: Symbol.collection)
                                    .symbolVariant(.fill)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(CobaltColor.collection.opacity(0.65))
                            }
                        case 1:
                            LinkMediaTile(item: shown[0], radius: cornerRadius, maxPixel: 360, iconSize: 22)
                                .frame(width: w, height: h)
                        case 2:
                            let half = (w - gap) / 2
                            HStack(spacing: gap) {
                                LinkMediaTile(item: shown[0], radius: 5, maxPixel: 280, iconSize: 18)
                                    .frame(width: half, height: h)
                                LinkMediaTile(item: shown[1], radius: 5, maxPixel: 280, iconSize: 18)
                                    .frame(width: half, height: h)
                            }
                        case 3:
                            let leadW = ((w - gap) * 0.58).rounded(.down)
                            let trailW = max(1, w - gap - leadW)
                            let smallH = (h - gap) / 2
                            HStack(spacing: gap) {
                                LinkMediaTile(item: shown[0], radius: 5, maxPixel: 320, iconSize: 18)
                                    .frame(width: leadW, height: h)
                                VStack(spacing: gap) {
                                    LinkMediaTile(item: shown[1], radius: 5, maxPixel: 220, iconSize: 13)
                                        .frame(width: trailW, height: smallH)
                                    LinkMediaTile(item: shown[2], radius: 5, maxPixel: 220, iconSize: 13)
                                        .frame(width: trailW, height: smallH)
                                }
                            }
                        default:
                            let cellW = (w - gap) / 2
                            let cellH = (h - gap) / 2
                            VStack(spacing: gap) {
                                HStack(spacing: gap) {
                                    LinkMediaTile(item: shown[0], radius: 5, maxPixel: 220, iconSize: 13)
                                        .frame(width: cellW, height: cellH)
                                    LinkMediaTile(item: shown[1], radius: 5, maxPixel: 220, iconSize: 13)
                                        .frame(width: cellW, height: cellH)
                                }
                                HStack(spacing: gap) {
                                    LinkMediaTile(item: shown[2], radius: 5, maxPixel: 220, iconSize: 13)
                                        .frame(width: cellW, height: cellH)
                                    LinkMediaTile(item: shown[3], radius: 5, maxPixel: 220, iconSize: 13)
                                        .frame(width: cellW, height: cellH)
                                        .overlay(alignment: .bottomTrailing) {
                                            if overflow > 0 {
                                                Text("+\(overflow)")
                                                    .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                                                    .monospacedDigit()
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .mediaGlassCapsule(interactive: false)
                                                    .padding(4)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .frame(width: w, height: h)
                }
            }
            .overlay(alignment: .bottom) {
                if !shown.isEmpty {
                    MediaEdgeVignette(edge: .bottom, height: 28, intensity: 0.24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .accessibilityHidden(true)
    }
}

/// Flexible media cell that fills any aspect ratio frame cleanly (used by `LinkCover`, `BentoMediaCover`, and `LinkThumb`).
struct LinkMediaTile: View {
    let item: ShareSetItem
    var radius: CGFloat = 8
    var maxPixel = 240
    var iconSize: CGFloat = 16

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
            CobaltColor.elevated
            if !item.isPublic {
                Image(systemName: Symbol.linkFilePrivate)
                    .font(.system(size: iconSize))
                    .foregroundStyle(CobaltColor.caption)
            } else if let poster {
                RemoteStill(poster: poster, maxPixel: maxPixel)
            } else {
                Image(systemName: isVideo ? Symbol.typeVideo : Symbol.typeImage)
                    .font(.system(size: iconSize))
                    .foregroundStyle(CobaltColor.caption)
            }
            if isVideo, item.isPublic {
                Image(systemName: Symbol.linkFilePlay)
                    .font(.system(size: max(8, iconSize * 0.72), weight: .bold))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .padding(max(4, iconSize * 0.36))
                    .background(CobaltColor.badgeBack, in: Circle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct LinkThumb: View {
    let item: ShareSetItem
    let side: CGFloat
    var radius: CGFloat = 8
    /// The picture's decode size: the 2x2 covers need little, the pane's big tiles more.
    var maxPixel = 240

    var body: some View {
        LinkMediaTile(item: item, radius: radius, maxPixel: maxPixel, iconSize: side * 0.28)
            .frame(width: side, height: side)
    }
}
