import CobaltKit
import SwiftUI

// A reply's scored list (APP-API-CONTRACT 34.6, `cobalt.rank`): the matches of "which videos in this collection are
// furry", best first, under the reply's text. A header with the title and "N ranked", a "within <label>" chip when the
// search was limited, then a row per post: its picture, its title, the words it matched as small chips, and its score with
// a bar. A tap opens the post exactly as a shown file does; a long press shows a bigger picture with open and share, as a
// collage tile does. A post the library no longer has is a quiet "removed" row.

struct ChatRankedView: View {
    let model: AppModel
    let ranked: ChatRanked
    let posts: [String: LibraryPost]
    /// A row was tapped (or "open" chosen in its menu): the same path a shown file takes.
    let open: (LibraryPost) -> Void

    private var title: String { ranked.title ?? ranked.query ?? Copy.Chat.rankedResults }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(spacing: 0) {
                let top = max(ranked.topScore ?? 0, 0.5)
                ForEach(Array(ranked.hits.enumerated()), id: \.element.id) { index, hit in
                    if index > 0 { Divider().overlay(CobaltColor.hairline) }
                    if let post = posts[hit.postID] {
                        ChatRankedRow(model: model, post: post, hit: hit, index: index, top: top) { open(post) }
                    } else {
                        ChatRankedGone()
                    }
                }
            }
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CobaltColor.border.opacity(0.5), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.rankedA11y(title: title, count: ranked.hits.count))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let within = ranked.within {
                Text(Copy.Chat.rankedWithin(within))
                    .font(CobaltType.pill)
                    .foregroundStyle(CobaltColor.collection)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CobaltColor.collectionBack, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Font.cobalt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.Chat.rankedCount(ranked.hits.count))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }
}

/// One post of the list.
struct ChatRankedRow: View {
    let model: AppModel
    let post: LibraryPost
    let hit: ChatRanked.Hit
    let index: Int
    /// The score the bars are measured against.
    let top: Double
    let open: () -> Void

    @Environment(\.displayScale) private var displayScale

    private static let side: CGFloat = 54

    var body: some View {
        let row = LibraryRow(item: model.mediaItem(for: post))
        let shareURL = row.item.face.publicURL.map { model.capabilities.shareLink(for: $0) }
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                FacePicture(item: row.item, maxPixel: Int(Self.side * displayScale * 2), gradient: FrameGradient.variant(forIndex: index))
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    LibraryTitleText(row: row, size: 12.5, weight: .semibold)
                        .lineLimit(1)
                    if !hit.why.isEmpty {
                        ChatRankedWhy(words: hit.why)
                    }
                    if let score = hit.score {
                        scoreBar(score)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RankedRowPress())
        .contextMenu {
            Button(Copy.Chat.collageOpen, systemImage: Symbol.Library.open, action: open)
            if let shareURL {
                ShareLink(item: shareURL) { Label(Copy.Chat.collageShare, systemImage: Symbol.Library.share) }
            }
        } preview: {
            LibraryPreviewCard(row: row)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Chat.rankedRowA11y(row.title, score: hit.score))
        .accessibilityValue(hit.why.joined(separator: ", "))
        .accessibilityHint(Copy.Chat.openPostA11yHint)
        .accessibilityAddTraits(.isButton)
    }

    private func scoreBar(_ score: Double) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(CobaltColor.elevated)
                Capsule()
                    .fill(CobaltColor.focus)
                    .scaleEffect(x: max(0.03, min(1, score / top)), y: 1, anchor: .leading)
            }
            .frame(height: 5)
            Text(Copy.Search.scoreText(score))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
        }
    }
}

/// The words a post matched, as small chips on one line (the rest drop off the end).
private struct ChatRankedWhy: View {
    let words: [String]

    var body: some View {
        AboutFlow(spacing: 4) {
            ForEach(words, id: \.self) { word in
                Text(word)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CobaltColor.elevated, in: Capsule())
            }
        }
        .frame(height: 18, alignment: .topLeading)
        .clipped()
    }
}

/// The row of a post the library no longer has.
private struct ChatRankedGone: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CobaltColor.elevated)
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: Symbol.chatRemoved)
                        .font(.system(size: 16))
                        .foregroundStyle(CobaltColor.caption)
                }
            Text(Copy.Chat.removed)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Chat.removedA11y)
    }
}

private struct RankedRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
