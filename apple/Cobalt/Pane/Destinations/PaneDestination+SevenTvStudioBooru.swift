import CobaltKit
import SwiftUI

// 7TV, studio and booru pages in the pane (apple/CONTRACT-PANE.md section 5). OWNED BY THE 7TV/STUDIO/BOORU LANE.
//
// Each function receives the item's payload, the window's `AppModel` and the window's `Pane`, and returns the page
// (a `PanePage`; `PaneLoadingPage` while loading, `PaneGonePage` for a deleted item). It is drawn inside the pane's own
// `NavigationStack` with `\.paneShape` set; read anything else from the environment.
//
// - emote(id):          a 7TV emote id (`SevenTvEmotePage`): the emote, its actions and its variants. The set screen
//                       gives the pane its set model first (`pane.provide(emoteSet)`), so the page can rename, copy and remove.
// - emoteAddToSet(id):  the add-to-set flow for an emote id (`SevenTvAddToSetPage`; 7TV login stays a system sheet). Finds
//                       the emote among the account's own, those a screen remembered with `SevenTvEmoteHits.remember`, and
//                       the open set's.
// - reward(id):         a studio channel-point reward (`StageRewardKind` raw value). `keepsRunning` (on air): the page
//                       reports `pane.setRunning(onAir, for: .reward(id))` in every shape (the bar included).
// - poolVideo(id):      a studio pool video (`StageItem` id), same report.
// - booruPost(id):      a booru post id; spanned, the picture (`BooruPostPage`).
// - booruFilters:       the booru filters page (`BooruFiltersPage`).
extension PaneDestination {
    @MainActor @ViewBuilder
    static func emote(_ id: String, model: AppModel, pane: Pane) -> some View {
        SevenTvEmotePage(model: model, id: id)
    }

    @MainActor @ViewBuilder
    static func emoteAddToSet(_ id: String, model: AppModel, pane: Pane) -> some View {
        SevenTvAddToSetPage(model: model, id: id)
    }

    @MainActor @ViewBuilder
    static func reward(_ id: String, model: AppModel, pane: Pane) -> some View {
        StageRewardPage(model: model, id: id)
    }

    @MainActor @ViewBuilder
    static func poolVideo(_ id: String, model: AppModel, pane: Pane) -> some View {
        StagePoolVideoPage(model: model, id: id)
    }

    @MainActor @ViewBuilder
    static func booruPost(_ id: Int, model: AppModel, pane: Pane) -> some View {
        BooruPostPage(model: model, id: id)
    }

    @MainActor @ViewBuilder
    static func booruFilters(model: AppModel, pane: Pane) -> some View {
        BooruFiltersPage(model: model)
    }
}

#if DEBUG
// `#Preview`s of the pages, drawn by the real host on the preview server (`PreviewClient` data, no network): an iPhone (the
// sheet), an iPad column, spanned, and the studio's bar.

/// The whole host with `item` open over the area's tab. `gives` makes the 7tv set model the emote page needs.
private struct AreaHost: View {
    let item: PaneItem
    let tab: AppTab
    var spanned = false
    var givesSet = false

    @State private var pane = Pane()
    @State private var held: SevenTvSetModel?

    var body: some View {
        PreviewHost(.happy, tab: tab) { model in
            PaneHost(model: model) {
                NavigationStack {
                    switch tab {
                    case .booru: BooruScreen(model: model, tier: .regular)
                    case .sevenTv: SevenTvScreen(model: model, tier: .regular)
                    default: StageScreen(model: model, tier: .regular)
                    }
                }
            }
            .task {
                if givesSet { await giveSet(model) }
                pane.open(item)
                if spanned { pane.span() }
            }
        }
        .environment(pane)
    }

    /// What the set screen does before it opens an emote: gives the pane its set (the second emote of the first one).
    private func giveSet(_ model: AppModel) async {
        await model.sevenTv.load()
        guard let channel = model.sevenTv.selectedChannel, let row = model.sevenTv.sets(of: channel.id).first else { return }
        let emoteSet = model.sevenTv.openSet(row.id, channelID: channel.id)
        await emoteSet.load()
        held = emoteSet
        pane.provide(emoteSet)
    }
}

/// A page alone in the bar's shape.
private struct BarHost<Content: View>: View {
    @ViewBuilder let content: (AppModel) -> Content
    @State private var pane = Pane()

    var body: some View {
        PreviewHost(.happy, tab: .stage) { model in
            content(model)
                .environment(\.paneShape, .bar)
                .environment(pane)
        }
    }
}

#Preview("booru post · iphone sheet", traits: .fixedLayout(width: 402, height: 874)) {
    AreaHost(item: .booruPost(1000), tab: .booru)
}
#Preview("booru post · ipad column", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .booruPost(1001), tab: .booru)
}
#Preview("booru post · spanned", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .booruPost(1000), tab: .booru, spanned: true)
}
#Preview("booru filters · iphone sheet", traits: .fixedLayout(width: 402, height: 874)) {
    AreaHost(item: .booruFilters, tab: .booru)
}
#Preview("booru filters · ipad column, dark", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .booruFilters, tab: .booru)
        .preferredColorScheme(.dark)
}

#Preview("7tv emote · ipad column", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .emote("01F6MQ33FG000FFJ97ZB8MWV52"), tab: .sevenTv, givesSet: true)
}
#Preview("7tv emote · iphone sheet", traits: .fixedLayout(width: 402, height: 874)) {
    AreaHost(item: .emote("01F6MQ33FG000FFJ97ZB8MWV52"), tab: .sevenTv, givesSet: true)
}
#Preview("7tv emote · spanned", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .emote("01F6MQ33FG000FFJ97ZB8MWV52"), tab: .sevenTv, spanned: true, givesSet: true)
}
#Preview("7tv add to a set · ipad column", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .emoteAddToSet("01F6MQ33FG000FFJ97ZB8MWV52"), tab: .sevenTv, givesSet: true)
}
#Preview("7tv add to a set · iphone sheet", traits: .fixedLayout(width: 402, height: 874)) {
    AreaHost(item: .emoteAddToSet("01F6MQ33FG000FFJ97ZB8MWV52"), tab: .sevenTv, givesSet: true)
}

#Preview("studio reward · iphone sheet", traits: .fixedLayout(width: 402, height: 874)) {
    AreaHost(item: .reward("summon"), tab: .stage)
}
#Preview("studio reward · spanned", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .reward("chaos"), tab: .stage, spanned: true)
}
#Preview("studio pool video · ipad column", traits: .fixedLayout(width: 1376, height: 1032)) {
    AreaHost(item: .poolVideo("PrEvIeWstage00002"), tab: .stage)
}
#Preview("studio bar", traits: .fixedLayout(width: 402, height: 64)) {
    BarHost { StageRewardPage(model: $0, id: "summon") }
}
#endif
