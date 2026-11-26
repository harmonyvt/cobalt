import CobaltKit
import SwiftUI

/// A press only dims: the tile sits in a scroll view and nothing may scale or move.
private struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.84 : 1)
    }
}

/// One mosaic tile: the face's picture at its real aspect filling the slot `MasonryPlan` gave it, with only
/// high-signal badges (private lock when private, consolidated shared pill, offline mark, gallery count or animated
/// webp pill, crisp bottom-trailing video duration pill, and a bottom caption scrim only when the post has a real
/// custom title). A webp face moves while the budget lets it.
///
/// On the iPhone (`holdOpens`, select mode or not) a hold previews the media in its true dimensions and lifting opens
/// the post in the pane; sliding off cancels. There is no context menu there (`attach: !holdOpens`); its actions are
/// on the post page and, for VoiceOver, custom actions on the tile (`LibraryTileActions`).
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
    /// iPhone: hold previews and release opens the pane; no context menu (`LibraryController.holdOpens`).
    var holdOpens = false
    let ticked: Bool
    /// Its place in the picks (1 is the first tapped), drawn on the tick.
    var pickNumber: Int? = nil
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
            && a.selecting == b.selecting && a.holdOpens == b.holdOpens && a.ticked == b.ticked && a.pickNumber == b.pickNumber && a.reload == b.reload
            && a.share == b.share && a.nearEnd == b.nearEnd
    }

    private var face: Rendition { row.item.face }
    private var narrow: Bool { size.width < 96 }
    private var radius: CGFloat { Metrics.thumbRadius }

    /// Only show a bottom caption overlay when the post has a real custom title (not raw `service · id` or `cobalt`).
    private var customTitle: String? {
        if case .custom(let title) = row.item.title { return title }
        return nil
    }

    private var showsCustomCaption: Bool { showsCaption && customTitle != nil }

    private var isPlayableVideo: Bool {
        !face.playsAsWebp && row.kind != .gallery && row.kind != .photo && !row.originalIsImage
    }

    /// The file a moving tile plays: this device's webp, else its public link.
    private var animationURL: URL? {
        guard face.playsAsWebp else { return nil }
        return face.local?.fileURL ?? face.publicURL
    }

    private var isRemote: Bool { face.local?.fileURL == nil }

    var body: some View {
        Button {
            // the touch that ended a hold-to-peek is not a tick (nor a second open)
            if controller.takeSwallowedTap() { return }
            // shift-click ticks a run, ⌘-click ticks this one (either starts select mode), as in Finder
            let click = LibraryController.Click.current(controller)
            if click == .plain, !selecting {
                controller.open(row)
            } else {
                withAnimation(Motion.rows) { controller.click(row, click) }
            }
        } label: { tile }
            .buttonStyle(TilePress())
            // while selecting, a hold shows the media full size (out of select mode the hold is the context menu); on the
            // iPhone the hold previews in both, and lifting the finger opens the post in the pane
            .peekOnHold(row, controller: controller, enabled: selecting || holdOpens, opensOnRelease: holdOpens, knownSize: size)
            // a gallery cannot be ticked (galleries are not shared): dimmer, and no tick
            .opacity(selecting ? (row.shareable ? (ticked ? 1 : 0.72) : 0.35) : 1)
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(LibraryRowMenu(row: row, controller: controller, attach: !holdOpens, enabled: !selecting && !holdOpens, removing: $removing))
            .modifier(LibraryTileActions(row: row, controller: controller, enabled: holdOpens, selecting: selecting, removing: $removing))
            .offlineRemoveConfirm($removing, model: controller.model)
            .zoomSource(id: row.id, in: zoom)
            // only a tile that can move watches its visibility: every tile doing so cost each one a tracker as it
            // scrolled in (8.15, scroll jitter)
            .modifier(TileVisibilityWatch(active: animationURL != nil) { visible in
                budget.setVisible(row.id, visible ? AnimationBudget.Candidate(y: centerY, remote: isRemote) : nil)
            })
            .onAppear { if nearEnd { controller.loadMoreIfNeeded() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
            .modifier(LibraryTileSpokenValue(row: row, share: share, failed: failed, model: controller.model))
            .accessibilityAddTraits(selected || ticked ? [.isButton, .isSelected] : .isButton)
            // the layout checks (apple/CobaltUITests) find the tiles by this, whatever their titles
            .accessibilityIdentifier("library.tile")
            // date order for VoiceOver, not column order
            .accessibilitySortPriority(Double(-index))
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            FacePicture(
                item: row.item, maxPixel: maxPixel, reload: reload, gradient: FrameGradient.variant(forIndex: index),
                failed: $failed)
            if let url = animationURL {
                TileAnimationSlot(id: row.id, url: url, budget: budget)
            }
            if showsCustomCaption {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.26), .black.opacity(0.68)],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: min(size.height * 0.45, 48))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
            overlays
            if lit { LitRing(radius: radius, reduceMotion: reduceMotion) }
            if selected || (selecting && ticked) {
                shape.strokeBorder(CobaltColor.focus, lineWidth: 2)
            } else {
                shape.strokeBorder(CobaltColor.hairline, lineWidth: 0.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
    }

    private var overlays: some View {
        ZStack {
            // top left: only high-signal status pills (hidden-by, private lock when private, shared links, offline)
            HStack(spacing: 4) {
                let showsShared = share.isShared && !narrow
                if let by = row.hiddenBy {
                    HiddenByBadge(by: by)
                } else if !row.isPublic {
                    Image(systemName: Symbol.Library.isPrivate)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(CobaltColor.badgeInk)
                        .frame(width: 20, height: 20)
                        .background(TileBadgeSurface.fill, in: Circle())
                        .overlay(Circle().strokeBorder(TileBadgeSurface.stroke, lineWidth: 0.5))
                }
                if showsShared {
                    SharedTileBadges(share: share)
                }
                OfflineBadge(item: row.item, model: controller.model, style: .tile)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // top right: select tick while selecting, otherwise only gallery count or animated webp
            if selecting {
                if row.shareable {
                    LibraryPickMark(ticked: ticked, onPhoto: true, number: pickNumber)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            } else {
                topRightBadge
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // bottom bar: custom title on the left (only when user-named), crisp duration pill on the right for videos
            if showsCustomCaption || (isPlayableVideo && size.height >= 68) {
                HStack(alignment: .bottom, spacing: 6) {
                    if let title = customTitle, showsCaption {
                        Text(title)
                            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if isPlayableVideo, size.height >= 68 {
                        durationPill
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var topRightBadge: some View {
        if row.kind == .gallery {
            GalleryCountBadge(count: row.itemCount, style: .tile)
        } else if face.playsAsWebp {
            if narrow || (share.isShared && size.width < 150) {
                Image(systemName: Symbol.Library.typeWebp)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .frame(width: 20, height: 20)
                    .background(TileBadgeSurface.fill, in: Circle())
                    .overlay(Circle().strokeBorder(TileBadgeSurface.stroke, lineWidth: 0.5))
            } else {
                Text(LibraryRowCopy.type(row))
                    .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6.5)
                    .frame(height: 20)
                    .background(TileBadgeSurface.fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(TileBadgeSurface.stroke, lineWidth: 0.5))
            }
        }
    }

    /// Quiet dark duration pill (bottom-trailing) for videos; shows a small play mark when duration is unknown.
    private var durationPill: some View {
        Group {
            if row.length > 0 {
                Text(Format.seconds(row.length))
                    .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 18, height: 18)
            }
        }
        .background(TileBadgeSurface.fill, in: Capsule())
        .fixedSize()
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

/// A grey tile of the skeleton (the first load). The mosaic draws one shimmer over all of them (`skeletonShimmer`).
struct LibraryGhostTile: View {
    let size: CGSize
    let index: Int

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
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

/// A tile's "already shared" badge: one unified dark pill holding the blue link count and (when in a collection) the
/// amber folder glyph, avoiding stacked multi-badge clutter.
struct SharedTileBadges: View {
    let share: ShareStatus

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                Image(systemName: Symbol.link)
                    .font(.system(size: 8.5, weight: .bold))
                Text("\(share.links)")
                    .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                    .monospacedDigit()
            }
            .foregroundStyle(CobaltColor.sharedInk)
            if share.collections > 0 {
                Image(systemName: Symbol.collection)
                    .symbolVariant(.fill)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(CobaltColor.collectionOnTile)
            }
        }
        .padding(.horizontal, 6.5)
        .frame(height: 20)
        .background(TileBadgeSurface.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(TileBadgeSurface.stroke, lineWidth: 0.5))
        .fixedSize()
    }
}

/// `onScrollVisibilityChange` (80 % visible) on the tiles that need it, nothing on the rest. `active` is fixed for a
/// row (whether its face plays as a webp), so the two branches never swap under a tile.
private struct TileVisibilityWatch: ViewModifier {
    let active: Bool
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        if active {
            content.onScrollVisibilityChange(threshold: 0.8, changed)
        } else {
            content
        }
    }
}
