#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of 7TV in the studio tab on the preview server (`PreviewSevenTv.swift`): the card linked (three channels, five
// days left), not linked (`.stageNotConnected`) and signed out by 7TV (`.renditions`); the set screen on both tabs; the link
// sheet; the emote sheet. Emote pictures come from 7TV's CDN, so they stay blank in a canvas without network.

@MainActor
private func card(_ model: AppModel) -> some View {
    NavigationStack {
        ScrollView {
            StageSevenTvCard(model: model).padding(Metrics.gutter)
        }
        .background(CobaltColor.bg)
    }
}

#Preview("7tv card · linked", traits: .fixedLayout(width: 390, height: 520)) {
    PreviewHost(.happy, tab: .stage) { card($0) }
}
#Preview("7tv card · linked, dark", traits: .fixedLayout(width: 390, height: 520)) {
    PreviewHost(.happy, tab: .stage) { card($0) }
        .preferredColorScheme(.dark)
}
#Preview("7tv card · not linked", traits: .fixedLayout(width: 390, height: 260)) {
    PreviewHost(.stageNotConnected, tab: .stage) { card($0) }
}
#Preview("7tv card · signed out", traits: .fixedLayout(width: 390, height: 300)) {
    PreviewHost(.renditions, tab: .stage) { card($0) }
}
#Preview("7tv card · AX3 text", traits: .fixedLayout(width: 390, height: 900)) {
    PreviewHost(.happy, tab: .stage) { card($0) }
        .dynamicTypeSize(.accessibility3)
}
#Preview("studio with 7tv · mac width", traits: .fixedLayout(width: 1180, height: 900)) {
    PreviewHost(.happy, tab: .stage) { model in NavigationStack { StageScreen(model: model, tier: .regular) } }
}

// MARK: the set screen and the sheets

/// Loads the account and the own channel's sets the way the card does, then shows the content.
private struct LoadedSevenTv<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: (AppModel, SevenTvSetRoute) -> Content
    @State private var route: SevenTvSetRoute?

    var body: some View {
        Group {
            if let route { content(model, route) } else { Color.clear }
        }
        .task {
            await model.sevenTv.load()
            guard let channel = model.sevenTv.selectedChannel, let emoteSet = model.sevenTv.sets(of: channel.id).first else { return }
            route = SevenTvSetRoute(setID: emoteSet.id, channelID: channel.id)
        }
    }
}

#Preview("7tv set · in this set", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedSevenTv(model: model) { model, route in
            NavigationStack { SevenTvSetScreen(model: model, route: route) }
        }
    }
}
#Preview("7tv set · iPad", traits: .fixedLayout(width: 820, height: 1000)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedSevenTv(model: model) { model, route in
            NavigationStack { SevenTvSetScreen(model: model, route: route) }
        }
    }
}
#Preview("7tv · link sheet", traits: .fixedLayout(width: 390, height: 760)) {
    PreviewHost(.stageNotConnected, tab: .stage) { model in
        SevenTvLinkSheet(store: model.sevenTv)
    }
}

/// The emote sheet for the second emote of `main` (peepoHey, renamed liaWave).
private struct LoadedEmote: View {
    let model: AppModel
    let route: SevenTvSetRoute
    @State private var emoteSet: SevenTvSetModel?

    var body: some View {
        Group {
            if let emoteSet, emoteSet.all.count > 1 { SevenTvEmoteSheet(emoteSet: emoteSet, emote: emoteSet.all[1]) } else { Color.clear }
        }
        .task {
            let emoteSet = model.sevenTv.openSet(route.setID, channelID: route.channelID)
            await emoteSet.load()
            self.emoteSet = emoteSet
        }
    }
}

#Preview("7tv · emote sheet", traits: .fixedLayout(width: 390, height: 360)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedSevenTv(model: model) { model, route in LoadedEmote(model: model, route: route) }
    }
}
#endif
