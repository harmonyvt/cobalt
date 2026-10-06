import CobaltKit
import SwiftUI

/// What both layouts draw: the media as it is now, the tab shown, and the controller.
@MainActor
struct DetailContext {
    let controller: DetailController
    let item: MediaItem
    let rendition: Rendition
    let selection: Binding<Rendition.ID>
    /// Pops the screen (the zoom back into the planet).
    let leave: () -> Void

    var model: AppModel { controller.model }

    /// A gallery or a single photo: the pager, the post's one switch and the gallery's buttons.
    var isGalleryLike: Bool { item.detailShape != .classic }
    /// The page of the pager on screen (nil on a made file's tab, and for a media with no pager).
    var page: GalleryPage? { controller.currentPage(in: item) }
    /// The item index of a page that was never saved, when that is the page on screen.
    var missingIndex: Int? { page.flatMap { $0.isMissing ? $0.index : nil } }
}

/// The width from which the detail goes two columns (iPad regular, a Mac sheet; CONTRACT-MEDIA 5).
enum DetailWidth {
    static let wide: CGFloat = 760
    /// From here a segmented control holds six tabs (iPad, Mac); under it four (iPhone).
    static let sixTabs: CGFloat = 600
}

// MARK: - the line under the hero

/// The meta line (Plex Mono caption) and, when the rendition is public, its link, selectable.
struct DetailInfo: View {
    let item: MediaItem
    let rendition: Rendition
    /// The page on screen was never saved: its meta line says so instead of describing a file.
    var missing: Int?

    var body: some View {
        if let missing {
            MissingInfo(item: item, index: missing)
        } else {
            info
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DetailMeta.line(rendition, in: item))
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let url = rendition.publicURL {
                Text(DetailMeta.linkText(url))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.linkBlue)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        // The row clips what sits within ~6 pt of its edge, and Plex Mono's first glyphs ("m", "1") reach the
        // edge of their box: 5 pt cut them ("nedia…", "'4.8 s"). 8 pt at the leading edge clears it.
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - compact: iPhone and narrow windows

/// One column: tabs, hero, meta, then the actions and the offline copy as grouped sections.
struct CompactDetail: View {
    let c: DetailContext
    var maxSegments = 4

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    RenditionTabs(item: c.item, selection: c.selection, maxSegments: maxSegments)
                    DetailHero(c: c, maxHeight: c.isGalleryLike ? 330 : 360)
                    DetailInfo(item: c.item, rendition: c.rendition, missing: c.missingIndex)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
            DetailControls(c: c)
        }
        .formStyle(.grouped)
        .motion(Motion.card, value: c.rendition.id)
    }
}

// MARK: - wide: iPad and the Mac

/// One surface, two columns: the tabs and the hero on the left, on the right the meta as rows, the link, the one
/// prominent button, the secondary row and the offline copy. Both columns are grouped forms on the same
/// background as the compact detail (no second pane, no divider), so the rows are the same light cards and the
/// margins are the form's own on both sides; the details column is a share of the width, never wider than it can
/// hold, so nothing meets the column's edge.
struct WideDetail: View {
    let c: DetailContext
    var maxSegments = 6
    @Environment(\.hapticsEnabled) private var haptics

    /// The details column: 40% of the width, between what its rows need and what they never use.
    private func detailsWidth(_ total: CGFloat) -> CGFloat { min(max(total * 0.4, 340), 440) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Form {
                    Section {
                        VStack(spacing: 16) {
                            RenditionTabs(item: c.item, selection: c.selection, maxSegments: maxSegments)
                            // the picture fits the column without scrolling it: tabs and form margins take ~150 pt (a gallery's
                            // strip takes ~70 more)
                            DetailHero(
                                c: c, maxHeight: min(560, max(280, geometry.size.height - (c.isGalleryLike ? 230 : 150))))
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                .formStyle(.grouped)
                Form {
                    if let missing = c.missingIndex {
                        Section { MissingInfo(item: c.item, index: missing) }
                    } else {
                        Section {
                            ForEach(DetailMeta.rows(c.rendition, in: c.item), id: \.label) { row in
                                LabeledContent(row.label) { Text(row.value).monospacedDigit() }
                                    .font(CobaltType.body)
                            }
                            if let url = c.rendition.publicURL { linkRow(url) }
                        }
                    }
                    DetailControls(c: c)
                }
                .formStyle(.grouped)
                .frame(width: detailsWidth(geometry.size.width))
            }
        }
        .motion(Motion.card, value: c.rendition.id)
    }

    /// The link with its two icon buttons: copy (bounces to a checkmark) and share.
    private func linkRow(_ url: URL) -> some View {
        let copied = c.controller.copiedID == c.rendition.id
        return LabeledContent(Copy.Media.link) {
            HStack(spacing: 6) {
                Text(DetailMeta.linkText(url))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.linkBlue)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button { c.controller.copy(url, for: c.rendition.id) } label: {
                    Image(systemName: copied ? Symbol.Media.copied : Symbol.Media.copyLink)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .symbolBounce(on: copied)
                .accessibilityLabel(Copy.copyLink)
                ShareLink(item: url) {
                    Image(systemName: Symbol.Media.share)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Copy.share)
            }
        }
        .font(CobaltType.body)
        .haptic(.success, trigger: copied, enabled: haptics) { $0 }
    }
}

/// What a page that was never saved says about itself.
struct MissingInfo: View {
    let item: MediaItem
    let index: Int

    var body: some View {
        Text(Copy.Gallery.itemName("photo", index + 1, of: item.galleryTotal))
            .font(CobaltType.captionSmall)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - the hero, and the controls under it

/// The picture of the tab: a gallery's or a photo's pager (with its strip), else the one rendition's hero.
struct DetailHero: View {
    let c: DetailContext
    var maxHeight: CGFloat

    var body: some View {
        if c.isGalleryLike, c.page != nil {
            GalleryPager(c: c, maxHeight: maxHeight)
        } else {
            RenditionHero(rendition: c.rendition, item: c.item, maxHeight: maxHeight)
        }
    }
}

/// Everything under the picture, in the contract's order: the public switch, the buttons, the make row and the offline copy.
/// A video's detail keeps today's sections; a gallery's and a photo's are the post's one switch and the gallery buttons.
struct DetailControls: View {
    let c: DetailContext

    var body: some View {
        if c.isGalleryLike {
            GalleryVisibilitySection(controller: c.controller, item: c.item, rendition: c.rendition)
            Section {
                GalleryActions(c: c, leave: c.leave)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if c.item.detailShape == .gallery { GalleryMakeRow(controller: c.controller, item: c.item) }
            if c.missingIndex == nil {
                OfflineCopySection(model: c.model, item: c.item, rendition: c.rendition)
            }
        } else {
            if c.controller.canSwitchVisibility(c.rendition) {
                VisibilitySection(controller: c.controller, rendition: c.rendition)
            }
            Section {
                DetailActions(controller: c.controller, item: c.item, rendition: c.rendition, leave: c.leave)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            OfflineCopySection(model: c.model, item: c.item, rendition: c.rendition)
        }
    }
}
