import CobaltKit
import SwiftUI

/// What both layouts draw: the media as it is now, the tab shown, and the controller.
struct DetailContext {
    let controller: DetailController
    let item: MediaItem
    let rendition: Rendition
    let selection: Binding<Rendition.ID>
    /// Pops the screen (the zoom back into the planet).
    let leave: () -> Void

    var model: AppModel { controller.model }
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

    var body: some View {
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
                    RenditionHero(rendition: c.rendition, item: c.item, maxHeight: 360)
                    DetailInfo(item: c.item, rendition: c.rendition)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
            if c.controller.canSwitchVisibility(c.rendition) {
                VisibilitySection(controller: c.controller, rendition: c.rendition)
            }
            Section {
                DetailActions(controller: c.controller, item: c.item, rendition: c.rendition, leave: c.leave)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let local = c.rendition.local {
                OfflineCopySection(model: c.model, video: local)
            }
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
                            // the picture fits the column without scrolling it: tabs and form margins take ~150 pt
                            RenditionHero(
                                rendition: c.rendition, item: c.item, maxHeight: min(560, max(280, geometry.size.height - 150)))
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                .formStyle(.grouped)
                Form {
                    Section {
                        ForEach(DetailMeta.rows(c.rendition, in: c.item), id: \.label) { row in
                            LabeledContent(row.label) { Text(row.value).monospacedDigit() }
                                .font(CobaltType.body)
                        }
                        if let url = c.rendition.publicURL { linkRow(url) }
                    }
                    if c.controller.canSwitchVisibility(c.rendition) {
                        VisibilitySection(controller: c.controller, rendition: c.rendition)
                    }
                    Section {
                        DetailActions(controller: c.controller, item: c.item, rendition: c.rendition, leave: c.leave)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    if let local = c.rendition.local {
                        OfflineCopySection(model: c.model, video: local)
                    }
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
