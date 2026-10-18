import CobaltKit
import SwiftUI

/// A press only dims: the tile sits in a scroll view and nothing may scale or move.
private struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// One mosaic tile (CONTRACT-LIBRARY2 decision 12): the face's picture at its real aspect, filling the slot
/// `MasonryPlan` gave it, with badges (the face's type top right, a `globe` (public) or `lock.fill` (private) dot top left,
/// or in its place the blue link badge when the post is already in a share link,
/// the length bottom left on a video face tall enough to hold it) and a one-line title on a soft dark scrim.
/// A webp face moves while the budget lets it. A tile whose picture failed keeps its frame, badges and caption
/// with a glyph, and still opens. Tap opens, unless the library is selecting: then it ticks this post and the
/// context menu is not offered.
///
/// `Equatable` on what it draws, so a new page of tiles (or a refresh that changed nothing) re-evaluates none of
/// the tiles already there.
struct LibraryTile: View, Equatable {
    let row: LibraryRow
    let index: Int
    let size: CGSize
    /// The tile centre in the scroll content, for the animation budget.
    let centerY: Double
    let maxPixel: Int
    let showsCaption: Bool
    let lit: Bool
    let selected: Bool
    /// Select mode. Passed in (not read off the controller while drawing) so `.equatable()` redraws the tick.
    let selecting: Bool
    let ticked: Bool
    let reload: Int
    /// The links and collections the post is already in (the blue link badge and the amber folder dot).
    let share: ShareStatus

    // Not part of what the tile draws:
    let controller: LibraryController
    let budget: AnimationBudget
    var zoom: Namespace.ID?
    let nearEnd: Bool

    @State private var failed = false
    @State private var removing: MediaItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: LibraryTile, b: LibraryTile) -> Bool {
        a.row == b.row && a.index == b.index && a.size == b.size && a.centerY == b.centerY && a.maxPixel == b.maxPixel
            && a.showsCaption == b.showsCaption && a.lit == b.lit && a.selected == b.selected
            && a.selecting == b.selecting && a.ticked == b.ticked && a.reload == b.reload
            && a.share == b.share && a.nearEnd == b.nearEnd
    }

    private var face: Rendition { row.item.face }
    private var narrow: Bool { size.width < 90 }
    private var radius: CGFloat { 10 }

    /// The file a moving tile plays: this device's webp, else its public link.
    private var animationURL: URL? {
        guard face.playsAsWebp else { return nil }
        return face.local?.fileURL ?? face.publicURL
    }

    private var isRemote: Bool { face.local?.fileURL == nil }

    /// The meta line, whether the link is public, and (when it is true) that the picture did not load.
    private var accessibilityValue: String {
        var parts = [LibraryRowCopy.meta(row, now: Date()), row.isPublic ? Copy.Library2.publicBadgeA11y : Copy.Library2.privateBadgeA11y]
        if let offline = OfflineMark(item: row.item, model: controller.model).spoken { parts.append(offline) }
        if let shared = Copy.Library2.sharedA11y(share) { parts.append(shared) }
        if failed { parts.append(Copy.Library2.pictureFailed) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button {
            if selecting { controller.togglePick(row) } else { controller.open(row) }
        } label: { tile }
            .buttonStyle(TilePress())
            // a gallery cannot be ticked (galleries are not shared): dimmer, and no tick
            .opacity(selecting ? (row.shareable ? (ticked ? 1 : 0.7) : 0.35) : 1)
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(LibraryRowMenu(row: row, controller: controller, enabled: !selecting, removing: $removing))
            .offlineRemoveConfirm($removing, model: controller.model)
            .zoomSource(id: row.id, in: zoom)
            .onScrollVisibilityChange(threshold: 0.8) { visible in
                guard animationURL != nil else { return }
                budget.setVisible(row.id, visible ? AnimationBudget.Candidate(y: centerY, remote: isRemote) : nil)
            }
            .onAppear { if nearEnd { controller.loadMoreIfNeeded() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(selected || ticked ? [.isButton, .isSelected] : .isButton)
            // date order for VoiceOver, not column order
            .accessibilitySortPriority(Double(-index))
    }

    private var tile: some View {
        ZStack {
            FacePicture(
                item: row.item, maxPixel: maxPixel, reload: reload, gradient: FrameGradient.variant(forIndex: index),
                failed: $failed)
            if let url = animationURL {
                TileAnimationSlot(id: row.id, url: url, budget: budget)
            }
            if showsCaption {
                LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(size.height, 38))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
            overlays
            if lit { LitRing(radius: radius, reduceMotion: reduceMotion) }
            if selected {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(CobaltColor.focus, lineWidth: 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var overlays: some View {
        ZStack {
            // top left: the video's switch (CONTRACT-VISIBILITY decision 13): a globe while its link is public, a lock
            // while it is private; never "some webp is public". Beside it the offline badge (CONTRACT-OFFLINE
            // decision 11): filled when all is kept, outline for some, a ring while it downloads, nothing otherwise.
            HStack(spacing: 4) {
                // Already shared: the link badge (how many links hold the post, then a folder when one of them is in a
                // collection). A shared post that is public needs no globe beside it (the link says so), which keeps
                // a 3-column iPhone tile clear of the type badge.
                let showsShared = share.isShared && !narrow
                if !(showsShared && row.isPublic) {
                    Image(systemName: row.isPublic ? Symbol.Library.isPublic : Symbol.Library.isPrivate)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CobaltColor.badgeInk)
                        .frame(width: 20, height: 20)
                        .background(CobaltColor.badgeBack, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
                }
                if showsShared {
                    SharedTileBadges(share: share)
                }
                OfflineBadge(item: row.item, model: controller.model, style: .tile)
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // top right: the select tick, or the face's type. While selecting the type moves to the bottom right, so
            // what is being ticked (a video, a photo, a webp) stays clear. A gallery gets no tick.
            if selecting {
                if row.shareable {
                    LibraryPickMark(ticked: ticked, onPhoto: true)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                kindDot
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } else {
                typeBadge
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            // bottom: the length, then the caption
            VStack(alignment: .leading, spacing: 1) {
                if !face.playsAsWebp, row.kind != .gallery, row.length > 0, size.height >= 80 {
                    Text(Format.seconds(row.length))
                        .font(Font.cobalt(9.5, .regular, relativeTo: .caption2))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                }
                if showsCaption {
                    Text(row.title)
                        .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 6)
            .padding(.trailing, selecting ? 22 : 0)                   // clear of the kind dot
            .padding(.bottom, showsCaption ? 5 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    /// The face's kind as one symbol in a dot (film, photo, sparkles, stack): the narrow tile's badge, and every tile's
    /// while selecting.
    private var kindDot: some View {
        Image(systemName: LibraryRowCopy.typeSymbol(row))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: 20, height: 20)
            .background(CobaltColor.badgeBack, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
    }

    @ViewBuilder
    private var typeBadge: some View {
        if row.kind == .gallery {
            // a gallery: the stack and how many items it holds, however narrow the tile
            GalleryCountBadge(count: row.itemCount, style: .tile)
        } else if narrow || (share.isShared && size.width < 150) {
            // a narrow tile, or one whose top left holds the link badges: the dot, so the two never meet
            kindDot
        } else {
            Text(LibraryRowCopy.type(row))
                .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.badgeInk)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(CobaltColor.badgeBack, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
        }
    }
}

/// The 2 pt focus ring "open in library" lights: a pulse from a wider, fainter ring while it settles; under
/// Reduce Motion, no pulse, only the ring.
private struct LitRing: View {
    let radius: CGFloat
    let reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(CobaltColor.focus.opacity(settled || reduceMotion ? 1 : 0.5), lineWidth: settled || reduceMotion ? 2 : 6)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.0)) { settled = true }
            }
    }
}

/// A grey tile of the skeleton (the first load): static, no shimmer.
struct LibraryGhostTile: View {
    let size: CGSize
    let index: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CobaltColor.elevated)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The zoom transition's source (iPhone): the tile the detail opens from. Nothing on the Mac.
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
        #else
        self
        #endif
    }
}

/// A tile's "already shared" badges: a blue link capsule with how many links hold the post, then an amber folder dot
/// when one of those links is in a collection. Same back and ring as the tile's other badges.
struct SharedTileBadges: View {
    let share: ShareStatus

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                Image(systemName: Symbol.link)
                    .font(.system(size: 9, weight: .bold))
                Text("\(share.links)")
                    .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                    .monospacedDigit()
            }
            .foregroundStyle(CobaltColor.sharedInk)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(CobaltColor.badgeBack, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            if share.collections > 0 {
                Image(systemName: Symbol.collection)
                    .symbolVariant(.fill)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CobaltColor.collectionOnTile)
                    .frame(width: 20, height: 20)
                    .background(CobaltColor.badgeBack, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            }
        }
        .fixedSize()
    }
}
