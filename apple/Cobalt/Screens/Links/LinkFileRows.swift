import CobaltKit
import SwiftUI

// The pieces of a gallery link's screen (APP-API-CONTRACT 41.4): one file as the screen shows it (`LinkFileEntry`),
// its row (read and edit), its thumbnail, the header, the "how discord shows it" preview and the save bar. Small views
// on purpose: the screen's list stays a short chain the type checker reads at once.

/// The library's posts by the ids of their files, so a link's file finds its post (its title, its picture, the post
/// a tap opens). Built once per draw of the link screen.
struct LinkFileLookup {
    private let posts: [String: LibraryPost]
    /// The library is all here: a file it does not list is deleted, not just on a page not loaded yet.
    let complete: Bool

    @MainActor
    init(model: AppModel) {
        var byFile: [String: LibraryPost] = [:]
        for post in model.library.posts {
            for file in post.files where byFile[file.id] == nil { byFile[file.id] = post }
        }
        posts = byFile
        complete = !model.library.hasMore
    }

    func post(for fileID: String) -> LibraryPost? { posts[fileID] }

    func file(_ fileID: String) -> LibraryFile? { posts[fileID]?.files.first { $0.id == fileID } }
}

/// One file of a link as the screen shows it, numbered in the order Discord shows them.
struct LinkFileEntry: Identifiable, Equatable {
    enum Warning: Equatable {
        /// Private now, in a public link.
        case privateNow
        case deleted
        case hidden
        /// Not public, and the library is not all loaded to say why.
        case unknown
    }

    enum Kind: Equatable { case video, image, webp, file }

    let id: String
    let number: Int
    /// The file as the link lists it; a stand-in made from the library for a file added in the draft.
    let item: ShareSetItem
    /// The post that holds it, when the library has it loaded.
    let post: LibraryPost?
    /// Added in the draft (not saved yet).
    let isNew: Bool
    let warning: Warning?
    let kind: Kind
    let duration: Double?

    /// It shows on the link's page (and so in Discord).
    var shows: Bool { warning == nil }

    static func == (a: LinkFileEntry, b: LinkFileEntry) -> Bool {
        a.id == b.id && a.number == b.number && a.isNew == b.isNew && a.warning == b.warning && a.item == b.item
            && a.post?.id == b.post?.id
    }

    /// The draft's (or the link's) files, in order.
    static func entries(_ ids: [String], link: ShareSet, lookup: LinkFileLookup) -> [LinkFileEntry] {
        let listed = Dictionary(link.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated().map { index, id in
            let post = lookup.post(for: id)
            let file = lookup.file(id)
            let known = listed[id]
            let item = known ?? ShareSetItem(
                id: id, url: file?.url, contentType: file?.contentType,
                posterURL: file?.posterURL ?? post?.posterURL, width: file?.width, height: file?.height,
                duration: file?.duration)
            return LinkFileEntry(
                id: id, number: index + 1, item: item, post: post, isNew: known == nil,
                warning: known.flatMap { warning(for: $0, isPrivate: link.isPrivate, post: post, lookup: lookup) },
                kind: kind(of: item.contentType), duration: item.duration ?? file?.duration)
        }
    }

    /// Why a file the link lists does not show, or nil when it does.
    private static func warning(for item: ShareSetItem, isPrivate: Bool, post: LibraryPost?, lookup: LinkFileLookup) -> Warning? {
        if item.hidden { return .hidden }
        guard !item.isPublic else { return nil }
        if isPrivate { return .deleted }                   // a private link shows any live file: null is a deleted one
        if post != nil { return .privateNow }
        return lookup.complete ? .deleted : .unknown
    }

    private static func kind(of contentType: String?) -> Kind {
        let type = contentType?.lowercased() ?? ""
        if type.hasPrefix("video/") { return .video }
        if type == "image/webp" { return .webp }
        if type.hasPrefix("image/") { return .image }
        return .file
    }

    var kindWord: String {
        switch kind {
        case .video: return Copy.LinkEdit.kindVideo
        case .image: return Copy.LinkEdit.kindImage
        case .webp: return Copy.LinkEdit.kindWebp
        case .file: return Copy.LinkEdit.kindFile
        }
    }

    /// "video · 0:14", "webp · 4s · new".
    var meta: String {
        var parts = [kindWord]
        if let duration, duration > 0, kind == .video || kind == .webp {
            parts.append(Copy.LinkEdit.length(duration, video: kind == .video))
        }
        if isNew { parts.append(Copy.LinkEdit.isNew) }
        return parts.joined(separator: " · ")
    }

    var warningText: String? {
        switch warning {
        case .privateNow: return Copy.LinkEdit.notShownPrivate
        case .deleted: return Copy.LinkEdit.notShownDeleted
        case .hidden: return Copy.LinkEdit.notShownHidden
        case .unknown: return Copy.LinkEdit.notShown
        case nil: return nil
        }
    }
}

// MARK: - a thumbnail

/// A file's picture: the link's own still while it shows (the exact file), else the post's face from the library (a
/// file just added), else the link's placeholder (a lock, a glyph).
struct LinkFileThumb: View {
    let entry: LinkFileEntry
    let side: CGFloat
    var radius: CGFloat = 8
    let model: AppModel

    var body: some View {
        if entry.shows, !entry.item.isPublic, let post = entry.post {
            FacePicture(item: model.mediaItem(for: post), maxPixel: 240, showsGlyph: false)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            LinkThumb(item: entry.item, side: side, radius: radius)
        }
    }
}

// MARK: - a row

/// A file's row: its number, its picture, the post's title, kind and length, and "not shown: …" when it no longer
/// shows. Edit mode adds the minus in front (off at 2 files) and, on the Mac, the drag hint at the end.
struct LinkFileRow: View {
    let entry: LinkFileEntry
    let model: AppModel
    /// Edit mode: the minus. Nil in read mode.
    var remove: (() -> Void)? = nil
    var canRemove = true

    private var name: String {
        entry.post.map { model.mediaItem(for: $0).titleText } ?? entry.kindWord
    }

    var body: some View {
        HStack(spacing: 10) {
            if let remove {
                Button(action: remove) {
                    Label(Copy.LinkEdit.remove, systemImage: Symbol.LinkEdit.remove)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 20))
                        .foregroundStyle(canRemove ? CobaltColor.error : CobaltColor.disabledInk)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .disabled(!canRemove)
                .help(canRemove ? Copy.LinkEdit.remove : Copy.LinkEdit.removeOff)
            }
            Text("\(entry.number)")
                .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(CobaltColor.caption)
                .frame(minWidth: 18)
            LinkFileThumb(entry: entry, side: 48, radius: 10, model: model)
                .opacity(entry.shows ? 1 : 0.45)
            LinkFileText(name: name, entry: entry)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(rowBack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(newOutline)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: remove == nil ? .ignore : .contain)
        .accessibilityLabel(Copy.LinkEdit.fileA11y(number: entry.number, name: name, meta: entry.meta, warning: entry.warningText))
    }

    private var rowBack: Color { CobaltColor.surface }

    @ViewBuilder
    private var newOutline: some View {
        if entry.isNew {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CobaltColor.focus.opacity(0.7), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if remove != nil {
            #if os(macOS)
            Image(systemName: Symbol.LinkEdit.drag)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CobaltColor.caption)
                .help(Copy.LinkEdit.moveHint)
                .accessibilityHidden(true)
            #endif
        } else if entry.post != nil {
            Image(systemName: Symbol.LinkEdit.openPost)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
        }
    }
}

/// The title, the kind line and the warning of a file's row.
private struct LinkFileText: View {
    let name: String
    let entry: LinkFileEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
            Text(entry.meta)
                .font(CobaltType.captionSmall)
                .foregroundStyle(entry.isNew ? CobaltColor.focus : CobaltColor.caption)
                .lineLimit(1)
            if let warning = entry.warningText {
                Label(warning, systemImage: Symbol.LinkEdit.notShown)
                    .labelStyle(CollectionLineLabel())
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.errorText)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - the header

/// The top of the link screen. Read: the title, the short link with "copy share" and share, the public/private badge,
/// the collections it is in. Edit: the title as a field with its hint.
struct LinkHeader: View {
    let link: ShareSet
    let controller: LinksController
    /// Edit mode's title field; nil reads.
    var title: Binding<String>? = nil

    @Environment(\.shell) private var shell

    private var shortLink: String { (link.url.host ?? "") + link.url.path }

    var body: some View {
        if let title {
            VStack(alignment: .leading, spacing: 6) {
                TextField(Copy.LinkEdit.titlePlaceholder, text: title)
                    .font(Font.cobalt(17, .semibold, relativeTo: .headline))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: Metrics.hit)
                    .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                    .accessibilityLabel(Copy.LinkEdit.titleField)
                Text(Copy.LinkEdit.titleHint)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(link.displayTitle)
                    .font(Font.cobalt(20, .semibold, relativeTo: .title3))
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                urlRow
                LinkHeaderTags(link: link, controller: controller)
            }
        }
    }

    private var urlRow: some View {
        let copied = controller.copiedID == link.id
        return HStack(spacing: 8) {
            Text(shortLink)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(copied ? Copy.Media.copied : Copy.LinkEdit.copyShare) { controller.copy(link, shell: shell) }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                .accessibilityLabel(copied ? Copy.Media.copied : Copy.Links.copyLink)
            ShareLink(item: link.url) {
                Label(Copy.Links.share, systemImage: Symbol.share).labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(CobaltColor.text)
        }
    }
}

/// The badge and the collection chips under a link's title.
private struct LinkHeaderTags: View {
    let link: ShareSet
    let controller: LinksController

    var body: some View {
        let names = controller.collectionsEnabled ? controller.store.collections(containing: link.id).map(\.name) : []
        if controller.privateLinksEnabled || !names.isEmpty {
            HStack(spacing: 6) {
                if controller.privateLinksEnabled { LinkPrivacyBadge(isPrivate: link.isPrivate) }
                if !names.isEmpty {
                    Label(names.joined(separator: " · "), systemImage: Symbol.collection)
                        .labelStyle(CollectionLineLabel())
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.collection)
                        .lineLimit(1)
                        .accessibilityLabel(Copy.LinkEdit.inCollections(names))
                }
            }
        }
    }
}

// MARK: - how discord shows it

/// A small picture of the link's message in Discord: the title (else "the ai caption") over the files that show, laid
/// out as Discord's media gallery does (one; two side by side; three as one big and two stacked; four as 2x2; more in
/// rows of three).
struct LinkDiscordPreview: View {
    let heading: String
    let entries: [LinkFileEntry]
    let model: AppModel

    private let width: CGFloat = 258
    private let gap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(CobaltType.captionSmall.weight(.semibold))
                .foregroundStyle(CobaltColor.text)
                .lineLimit(2)
            if entries.isEmpty {
                Text(Copy.LinkEdit.nothingShown)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            } else {
                grid
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: width + 24, alignment: .leading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(CobaltColor.linkBlue).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Copy.LinkEdit.discordSection): \(heading), \(Copy.Links.fileCount(entries.count))")
    }

    @ViewBuilder
    private var grid: some View {
        let n = entries.count
        if n == 1 {
            tile(entries[0], width)
        } else if n == 3 {
            let small = ((width - gap) / 3).rounded(.down)
            HStack(spacing: gap) {
                tile(entries[0], small * 2 + gap)
                VStack(spacing: gap) {
                    tile(entries[1], small)
                    tile(entries[2], small)
                }
            }
        } else {
            let columns = (n == 2 || n == 4) ? 2 : 3
            let side = ((width - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            VStack(spacing: gap) {
                ForEach(Array(stride(from: 0, to: n, by: columns)), id: \.self) { start in
                    HStack(spacing: gap) {
                        ForEach(start..<min(start + columns, n), id: \.self) { index in
                            tile(entries[index], side)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ entry: LinkFileEntry, _ side: CGFloat) -> some View {
        LinkFileThumb(entry: entry, side: side, radius: 2, model: model)
    }
}

// MARK: - the save bar

/// Edit mode's bar at the bottom: what changed ("2 added · 1 out · new order"), then cancel and save (⌘S).
struct LinkSaveBar: View {
    let draft: ShareSetEdit
    let saving: Bool
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.LinkEdit.summary(draft.changes))
                .font(CobaltType.captionSmall)
                .foregroundStyle(draft.hasChanges ? CobaltColor.text : CobaltColor.caption)
                .contentTransition(.opacity)
            if !draft.titleFits {
                Text(Copy.LinkEdit.titleTooLong)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            }
            HStack(spacing: 10) {
                Button(Copy.LinkEdit.cancel, action: cancel)
                    .buttonStyle(.cobaltSecondary())
                Button(saving ? Copy.LinkEdit.saving : Copy.LinkEdit.save, action: save)
                    .buttonStyle(.cobaltPrimary())
                    .disabled(!draft.canSave || saving)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .animation(Motion.fade, value: draft.changes)
    }
}
