import CobaltKit
import SwiftUI

// A reply's collage (APP-API-CONTRACT 27.5): one big result set under the reply's text, as a masonry of the posts at their
// own aspect, read 30 at a time. A header with the title and "N results" (and "open in library" when the collage knows its
// search words), the grid, then "show 30 more" until the last page. A tap opens the post exactly as a shown file does; a
// long press shows a bigger picture with open and share. The grid lives in the message list and never scrolls it: loading
// more only makes the list longer.

struct ChatCollageView: View {
    let model: AppModel
    let threadID: String
    let messageID: String
    let collage: ChatCollage
    let tier: Tier
    /// A tile was tapped (or "open" chosen in its menu): the same path a shown file takes.
    let open: (LibraryPost) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0
    @State private var rows = ChatCollageRows()

    private static let gap: CGFloat = 6

    /// A tile is at most 1.4 times as tall as wide and at least 0.8: a "mini" collage (a tall clip fills 30 screens at the
    /// library's 9:16), the picture cropped to fill.
    private static func tileAspect(_ aspect: Double) -> Double { min(1.4, max(0.8, MasonryPlan.clampAspect(aspect))) }

    private var store: ChatStore { model.chat }
    private var state: ChatCollageState? { store.collagePages[messageID] }
    private var title: String { collage.title ?? Copy.Chat.collageResults }

    /// 2 columns on the phone (and at accessibility text sizes), 3 or 4 on the iPad and Mac by the room there is.
    private var columns: Int {
        if tier == .compact || typeSize.isAccessibilitySize { return 2 }
        return width >= 560 ? 4 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            grid
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // the first page; a replaced collage (another size) starts over, the store having dropped the old pages
        .task(id: collage) { await store.loadCollage(threadID: threadID, messageID: messageID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.collageA11y(title: title, count: collage.total))
    }

    // MARK: the header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Font.cobalt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.Chat.collageCount(collage.total))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            }
            Spacer(minLength: 8)
            if let query = collage.query {
                Button {
                    model.openInLibrary(search: query)
                } label: {
                    Label(Copy.Chat.openInLibrary, systemImage: Symbol.chatCollageLibrary)
                        .font(CobaltType.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
    }

    // MARK: the grid

    @ViewBuilder
    private var grid: some View {
        let posts = state?.loadedPosts ?? []
        if width <= 0 {
            Color.clear.frame(height: 1)
        } else if posts.isEmpty {
            if state?.failed == true {
                EmptyView()
            } else {
                skeleton
            }
        } else {
            let tiles = posts.map { rows.row(for: $0, model: model) }
            let plan = MasonryPlan.make(
                aspects: tiles.map { Self.tileAspect($0.faceAspect) }, width: Double(width), columns: columns, gap: Double(Self.gap), margin: 0)
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(0..<plan.columns, id: \.self) { column in
                    VStack(spacing: Self.gap) {
                        ForEach(plan.slots.filter { $0.column == column }, id: \.index) { slot in
                            ChatCollageTile(
                                model: model, post: posts[slot.index], row: tiles[slot.index], index: slot.index,
                                size: CGSize(width: plan.columnWidth, height: slot.height), open: open)
                        }
                    }
                    .frame(width: plan.columnWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityValue(Copy.Chat.collageShown(posts.count, of: collage.total))
        }
    }

    /// Grey tiles at mixed heights while the first page is on its way.
    private var skeleton: some View {
        let heights: [CGFloat] = [1.5, 1.0, 1.0, 1.4, 1.2, 0.8]
        let column = (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        return HStack(alignment: .top, spacing: Self.gap) {
            ForEach(0..<columns, id: \.self) { c in
                VStack(spacing: Self.gap) {
                    ForEach(0..<3, id: \.self) { r in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CobaltColor.surface)
                            .frame(width: column, height: column * heights[(c * 3 + r) % heights.count])
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: the foot

    @ViewBuilder
    private var footer: some View {
        if let state {
            if state.failed {
                Button {
                    Task { await store.loadMoreCollage(threadID: threadID, messageID: messageID) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Symbol.error).accessibilityHidden(true)
                        Text(Copy.Chat.collageFailed)
                        Spacer(minLength: 0)
                        Image(systemName: Symbol.retry).accessibilityHidden(true)
                    }
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CobaltColor.errorText.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.Chat.tryAgain)
            } else if state.loading, state.loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel(Copy.Chat.working)
            } else if state.loaded, state.hasMore {
                Button {
                    Task { await store.loadMoreCollage(threadID: threadID, messageID: messageID) }
                } label: {
                    Text(Copy.Chat.showMore(state.nextCount(total: collage.total)))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.cobaltSecondary())
            }
        }
    }
}

/// Keeps the `LibraryRow` of each post of a collage once it is built (a row joins the post with the device's copy, which is
/// not free for hundreds of posts the grid lays out again on every change). A plain reference: reading it is not observed.
@MainActor
final class ChatCollageRows {
    private var rows: [String: LibraryRow] = [:]

    func row(for post: LibraryPost, model: AppModel) -> LibraryRow {
        if let known = rows[post.id] { return known }
        let row = LibraryRow(item: model.mediaItem(for: post))
        rows[post.id] = row
        return row
    }
}

// MARK: - one tile

/// A post at its own aspect, with a play badge on a video; tap opens it, long press shows it bigger with open and share.
struct ChatCollageTile: View {
    let model: AppModel
    let post: LibraryPost
    let row: LibraryRow
    let index: Int
    let size: CGSize
    let open: (LibraryPost) -> Void

    @Environment(\.displayScale) private var displayScale
    /// The tile has been on screen once: only then is its picture asked for (the grid is not a lazy stack, which does not
    /// sit well inside the message list's own lazy stack, so a hundred pictures would otherwise load at once).
    @State private var seen = false

    /// The link to hand out: its private link (APP-API-CONTRACT 36.6), else its public one (the rich page when the server
    /// has them); nil when the post has neither.
    private var shareURL: URL? { model.capabilities.liveLink(for: row.item.face) }

    var body: some View {
        let pixels = Int(min(512, max(128, (max(size.width, size.height) * displayScale / 64).rounded(.up) * 64)))
        Button { open(post) } label: {
            Group {
                if seen {
                    FacePicture(item: row.item, maxPixel: pixels, gradient: FrameGradient.variant(forIndex: index))
                } else {
                    Rectangle().fill(FrameGradient.fill(FrameGradient.variant(forIndex: index)))
                }
            }
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottomLeading) { badge }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CollageTilePress())
        .onScrollVisibilityChange(threshold: 0.01) { if $0 { seen = true } }
        .contextMenu {
            Button(Copy.Chat.collageOpen, systemImage: Symbol.Library.open) { open(post) }
            if let shareURL {
                ShareLink(item: shareURL) { Label(Copy.Chat.collageShare, systemImage: Symbol.Library.share) }
            }
        } preview: {
            LibraryPreviewCard(row: row)
        }
        .accessibilityLabel(row.title)
        .accessibilityHint(Copy.Chat.openPostA11yHint)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var badge: some View {
        if row.kind == .video || row.kind == .gallery {
            Image(systemName: row.kind == .video ? Symbol.chatPlay : Symbol.Gallery.gallery)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(CobaltColor.badgeInk)
                .padding(6)
                .background(CobaltColor.badgeBack, in: Circle())
                .padding(6)
                .accessibilityHidden(true)
        }
    }
}

private struct CollageTilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}
