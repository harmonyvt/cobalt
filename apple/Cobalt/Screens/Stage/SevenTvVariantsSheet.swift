import CobaltKit
import SwiftUI

// "variants" (APP-API-CONTRACT 20.2): a long press on an emote of a set opens every emote on 7TV with that emote's own name
// (its 7TV name, never the alias it has in this set), most used first. The held one says "this one", another that is already
// in the set wears ✓, and the next page loads at the last tile. A tap on another one swaps it in for the held one, under the
// held one's alias (the word in chat stays), then the sheet closes. Without the right to edit the set a tap opens it on
// 7tv.app instead; "open on 7tv" is in every tile's menu either way.

struct SevenTvVariantsSheet: View {
    let variants: SevenTvVariantsModel
    let emoteSet: SevenTvSetModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.shell) private var shell
    @State private var openTick = 0
    @State private var swapping: String?
    @State private var doneTick = 0
    @State private var failTick = 0

    private var emote: SevenTvSetItem { variants.emote }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            caption
            grid
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        #if os(macOS)
        .frame(width: 520, height: 560)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .task { if variants.state != .loaded { await variants.load() } }
        .haptic(.selection, trigger: openTick)
        .haptic(.success, trigger: doneTick)
        .haptic(.error, trigger: failTick)
    }

    private var canSwap: Bool { emoteSet.can.manageSets }

    private func pick(_ hit: EmoteHit) {
        guard canSwap else { return open(hit) }
        guard hit.id != emote.emoteID, swapping == nil else { return }
        swapping = hit.id
        Task {
            do {
                try await emoteSet.swap(emote, for: hit)
                swapping = nil
                shell.showStatus(Copy.SevenTv.swapped(hit.name, as: emote.alias))
                doneTick += 1
                dismiss()
            } catch {
                swapping = nil
                shell.showStatus(Copy.SevenTv.message(for: error))
                failTick += 1
            }
        }
    }

    private func open(_ hit: EmoteHit) {
        openTick += 1
        openURL(SevenTvEmoteRule.pageURL(hit.id))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            EmotePicture(url: emote.previewURL, animated: emote.animated, side: 52)
                .padding(4)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.SevenTv.variantsOf(variants.name))
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if emote.renamed {
                    Text(Copy.SevenTv.tileA11y(emote.alias, name: emote.name, renamed: true))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch variants.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.SevenTv.variantsHint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        case .failed:
            HStack(spacing: 8) {
                Text(Copy.SevenTv.variantsDown)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { Task { await variants.load() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        case .loaded:
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.SevenTv.variantsCount(variants.othersCount, more: variants.hasMore))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.text)
                    .contentTransition(.numericText())
                Text(canSwap ? Copy.SevenTv.variantsSwapHint : Copy.SevenTv.variantsHint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 12) {
                ForEach(variants.items) { hit in
                    SevenTvVariantTile(
                        hit: hit, held: hit.id == emote.emoteID, inSet: emoteSet.memberIDs.contains(hit.id),
                        swaps: canSwap, swapping: swapping == hit.id, dimmed: swapping != nil && swapping != hit.id,
                        pick: { pick(hit) }, open: { open(hit) })
                    .onAppear {
                        if hit.id == variants.items.last?.id { Task { await variants.loadMore() } }
                    }
                }
            }
            .padding(.top, 6)
            if variants.loadingMore {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            }
        }
        .motion(Motion.rows, value: variants.items.map(\.id))
    }
}

/// One variant: its picture and name, "this one" under the held emote, ✓ on another already in the set.
private struct SevenTvVariantTile: View {
    let hit: EmoteHit
    let held: Bool
    let inSet: Bool
    /// A tap swaps it in (else it opens on 7tv.app).
    let swaps: Bool
    let swapping: Bool
    let dimmed: Bool
    let pick: () -> Void
    let open: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    EmotePicture(url: hit.previewURL, animated: hit.animated)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(held || inSet ? CobaltColor.elevated : CobaltColor.surface))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(held ? CobaltColor.focus : Color.clear, lineWidth: 2)
                        }
                    if swapping {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if inSet && !held {
                        Image(systemName: Symbol.SevenTv.inSet)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(CobaltColor.success))
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                Text(held ? Copy.SevenTv.thisOne : hit.name)
                    .font(Font.cobalt(11.5, held ? .semibold : .regular, relativeTo: .caption))
                    .foregroundStyle(held ? CobaltColor.text : CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.45 : 1)
        .disabled(dimmed)
        .contextMenu {
            Button(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website, action: open)
        }
        .accessibilityLabel(Copy.SevenTv.variantA11y(hit.name, held: held, inSet: inSet, animated: hit.animated))
        .accessibilityHint(swaps && !held ? Copy.SevenTv.variantSwapHintA11y : Copy.SevenTv.variantHintA11y)
        .accessibilityAction(named: Copy.SevenTv.openOn7tv, open)
    }
}
