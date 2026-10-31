import CobaltKit
import SwiftUI

/// The select panel's `add to link` opens this (APP-API-CONTRACT 41.4, mockup step 7): every gallery link as a row with
/// its cover, its title, its badge and what adding would do ("6 → 8 files"). A link that cannot take the picks is dimmed
/// with the reason: "already in it" (it holds every pick), "room for 1", "has a private file" (a public link and a pick
/// with no public file). A tap on a link that can closes the sheet and appends the picks (`choose`). iPhone and iPad: a
/// sheet; Mac: the same view, 420 pt wide.
struct LinkPickerSheet: View {
    let store: ShareSetStore
    let picks: [ShareSetPick]
    let maximum: Int
    let showsBadges: Bool
    /// The link chosen and the file ids to append to it.
    let choose: (ShareSet, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.sets.isEmpty {
                Text(Copy.LinkEdit.noLinksYet)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.sets) { link in
                            LinkPickerRow(
                                link: link, verdict: ShareSetRule.addVerdict(picks, to: link, maximum: maximum),
                                showsBadge: showsBadges
                            ) {
                                let ids = ShareSetRule.fileIDs(adding: picks, to: link)
                                dismiss()
                                choose(link, ids)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                #if os(macOS)
                .frame(maxHeight: 400)
                #endif
                Text(Copy.LinkEdit.pickLinkFoot)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.LinkEdit.pickLinkTitle(picks.count))
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(Copy.LinkEdit.pickLinkTitle(picks.count))
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            CloseButton(cancels: true) { dismiss() }
        }
    }
}

/// One link in the picker.
private struct LinkPickerRow: View {
    let link: ShareSet
    let verdict: ShareSetAddVerdict
    let showsBadge: Bool
    let pick: () -> Void

    private var ready: Bool {
        if case .ready = verdict { return true }
        return false
    }

    private var line: String { Copy.LinkEdit.verdict(verdict, count: link.items.count) }

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                LinkCover(items: link.items, side: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.displayTitle)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(line)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(ready ? CobaltColor.caption : CobaltColor.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if showsBadge { LinkPrivacyBadge(isPrivate: link.isPrivate) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(ready ? 1 : 0.45)
        }
        .buttonStyle(.borderless)
        .disabled(!ready)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(link.displayTitle), \(line)")
        .accessibilityAddTraits(.isButton)
    }
}
