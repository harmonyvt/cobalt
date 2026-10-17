import CobaltKit
import SwiftUI

// The links tab (APP-API-CONTRACT section 24): every gallery share link the owner made, newest first, each with its
// files as a strip of thumbnails, its title and date, and copy / share / revoke. Revoke asks first. The list is
// `model.shareSets` (the library's select bar adds to it, a refresh on appear and a pull keep it honest).

struct LinksScreen: View {
    let model: AppModel

    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics
    /// The link the owner chose `revoke` for: the confirm is open on it.
    @State private var revoking: ShareSet?
    /// Links whose DELETE is in flight (dimmed; a second tap does nothing).
    @State private var revokingIDs: Set<String> = []
    @State private var copiedToken = 0

    private var store: ShareSetStore { model.shareSets }

    private enum Phase { case loading, failed, empty, list }

    private var phase: Phase {
        if !store.sets.isEmpty { return .list }
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
            .confirmationDialog(
                Copy.Links.revokeTitle, isPresented: revokingPresented, titleVisibility: .visible, presenting: revoking
            ) { link in
                Button(Copy.Links.revoke, role: .destructive) { revoke(link) }
                Button(Copy.Links.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.Links.revokeMessage)
            }
            .haptic(.success, trigger: copiedToken, enabled: haptics)
    }

    private var revokingPresented: Binding<Bool> {
        Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })
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
            ForEach(store.sets) { link in
                LinkRow(
                    link: link, busy: revokingIDs.contains(link.id),
                    copy: { copy(link) }, revoke: { revoking = link }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                #if os(iOS)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive) { revoking = link }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(Copy.Links.copyLink, systemImage: Symbol.copyLink) { copy(link) }
                        .tint(CobaltColor.focus)
                }
                #endif
                .contextMenu { LinkMenu(link: link, copy: { copy(link) }, revoke: { revoking = link }) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .motion(Motion.rows, value: store.sets.map(\.id))
        .refreshable { await store.refresh() }
    }

    // MARK: actions

    /// The usual copy: the link on the pasteboard and `copied` over the shell.
    private func copy(_ link: ShareSet) {
        Pasteboard.copy(link.url.absoluteString)
        shell.showStatus(Copy.Media.copied)
        copiedToken += 1
    }

    private func revoke(_ link: ShareSet) {
        guard !revokingIDs.contains(link.id) else { return }
        revokingIDs.insert(link.id)
        Task {
            defer { revokingIDs.remove(link.id) }
            do {
                try await store.revoke(link.id)
                shell.showStatus(Copy.Links.revoked)
            } catch {
                shell.showStatus(Copy.actionFailed)
            }
        }
    }
}

// MARK: - the context menu (iPhone, iPad and Mac)

private struct LinkMenu: View {
    let link: ShareSet
    let copy: () -> Void
    let revoke: () -> Void

    var body: some View {
        Button(Copy.Links.copyLink, systemImage: Symbol.copyLink, action: copy)
        ShareLink(item: link.url) { Label(Copy.Links.share, systemImage: Symbol.share) }
        Divider()
        Button(Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive, action: revoke)
    }
}

// MARK: - a row

/// Up to four thumbnails, then the title, the file count and date, the short link, and a note when files went private.
/// iPhone: copy button at the end (share and revoke by swipe or the long press); Mac: copy, share and revoke buttons.
private struct LinkRow: View {
    let link: ShareSet
    let busy: Bool
    let copy: () -> Void
    let revoke: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var privateCount: Int { link.items.count - link.publicItemCount }

    private var note: String? {
        if link.publicItemCount == 0 { return Copy.Links.allPrivate }
        if privateCount > 0 { return Copy.Links.privateNow(privateCount) }
        return nil
    }

    private var shortLink: String {
        let host = link.url.host ?? ""
        return host + link.url.path
    }

    var body: some View {
        let when = Format.when(link.createdAt, now: Date())
        VStack(alignment: .leading, spacing: 10) {
            LinkStrip(items: link.items)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.displayTitle)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Text("\(Copy.Links.fileCount(link.items.count)) · \(when)")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                    Text(shortLink)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note {
                        Text(note)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(link.publicItemCount == 0 ? CobaltColor.errorText : CobaltColor.caption)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Copy.Links.rowA11y(title: link.displayTitle, files: link.items.count, when: when))
                Spacer(minLength: 4)
                buttons
            }
        }
        .padding(.vertical, 4)
        .opacity(busy ? 0.4 : 1)
        .disabled(busy)
        .animation(Motion.fade, value: busy)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 2) {
            Button(Copy.Links.copyLink, systemImage: Symbol.copyLink, action: copy)
            #if os(macOS)
            ShareLink(item: link.url) { Label(Copy.Links.share, systemImage: Symbol.share) }
            Button(Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive, action: revoke)
            #endif
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(CobaltColor.text)
        #if os(macOS)
        .help(Copy.Links.copyLink)
        #else
        .frame(minHeight: Metrics.hit)
        #endif
    }
}

// MARK: - the strip

/// The set's files, up to four, as squares in a row (the server caps a set at four). A file that is private now draws
/// as a locked tile; a video carries a play glyph.
struct LinkStrip: View {
    let items: [ShareSetItem]
    var side: CGFloat = Platform.isMac ? 64 : 72

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(4)) { item in
                LinkThumb(item: item, side: side)
            }
        }
        .accessibilityHidden(true)
    }
}

struct LinkThumb: View {
    let item: ShareSetItem
    let side: CGFloat

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
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CobaltColor.elevated)
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
