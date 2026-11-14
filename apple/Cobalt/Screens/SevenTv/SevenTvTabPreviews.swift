#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the 7tv tab on the preview server (`PreviewSevenTv.swift`): iPhone on sets, search and upload (linked as
// capybaraharmony, three channels; two uploads, one still processing), not linked (`.stageNotConnected`), signed out by 7TV
// (`.renditions`), the Mac's three columns, the studio's "7tv →" row, and the name clash sheet. Emote pictures come from
// 7TV's CDN and library pictures from the media host, so they stay blank in a canvas without network.

#Preview("7tv tab · sets", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact) }
    }
}
#Preview("7tv tab · sets, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact) }
    }
    .preferredColorScheme(.dark)
}
#Preview("7tv tab · search", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .search) }
    }
}
#Preview("7tv tab · upload", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .upload) }
    }
}
#Preview("7tv tab · not linked", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.stageNotConnected, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact) }
    }
}
#Preview("7tv tab · signed out", traits: .fixedLayout(width: 390, height: 500)) {
    PreviewHost(.renditions, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact) }
    }
}
#Preview("7tv tab · AX3 text", traits: .fixedLayout(width: 390, height: 1100)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact) }
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("7tv tab · mac", traits: .fixedLayout(width: 1180, height: 760)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .wide) }
    }
}
#Preview("7tv tab · mac shell", traits: .fixedLayout(width: 1380, height: 820)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        AppShell(model: model)
    }
}
#Preview("studio · 7tv row", traits: .fixedLayout(width: 390, height: 140)) {
    PreviewHost(.happy, tab: .stage) { model in
        StageSevenTvShortcut(model: model).padding(Metrics.gutter)
    }
}

/// The clash sheet for adding Clap (the 4th emote of `main`) under catJAM, the name of the first.
private struct LoadedClash: View {
    let model: AppModel
    @State private var found: (emoteSet: SevenTvSetModel, clash: SevenTvNameClash)?

    var body: some View {
        Group {
            if let found {
                SevenTvClashSheet(emoteSet: found.emoteSet, clash: found.clash)
            } else {
                Color.clear
            }
        }
        .task {
            await model.sevenTv.load()
            guard let channel = model.sevenTv.selectedChannel,
                  let main = model.sevenTv.sets(of: channel.id).first else { return }
            let emoteSet = model.sevenTv.openSet(main.id, channelID: channel.id)
            await emoteSet.load()
            guard emoteSet.all.count > 3,
                  let clash = emoteSet.localClash(adding: emoteSet.all[3].asHit, alias: emoteSet.all[0].alias) else { return }
            found = (emoteSet, clash)
        }
    }
}

#Preview("7tv · name clash", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedClash(model: model)
    }
}
#Preview("7tv · name clash, dark", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedClash(model: model)
    }
    .preferredColorScheme(.dark)
}
#endif
