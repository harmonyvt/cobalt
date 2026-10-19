#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the studio tab on the preview server: the connected stage on air (a collection pool, a spotlight a viewer
// summoned, four rewards, a few redemptions, the store locked), the stage before Twitch is connected, and a stage that cannot
// load. Compact (iPhone), regular and wide (iPad on its side, the Mac). The OBS preview is a live web view, so it stays blank
// in a canvas without network.

@MainActor
private func stageScreen(_ model: AppModel, _ tier: Tier) -> some View {
    NavigationStack { StageScreen(model: model, tier: tier) }
}

#Preview("studio · connected", traits: .fixedLayout(width: 390, height: 1100)) {
    PreviewHost(.happy, tab: .stage) { stageScreen($0, .compact) }
}
#Preview("studio · connected, dark", traits: .fixedLayout(width: 390, height: 1100)) {
    PreviewHost(.happy, tab: .stage) { stageScreen($0, .compact) }
        .preferredColorScheme(.dark)
}
#Preview("studio · AX3 text", traits: .fixedLayout(width: 390, height: 1400)) {
    PreviewHost(.happy, tab: .stage) { stageScreen($0, .compact) }
        .dynamicTypeSize(.accessibility3)
}
#Preview("studio · not connected", traits: .fixedLayout(width: 390, height: 1100)) {
    PreviewHost(.stageNotConnected, tab: .stage) { stageScreen($0, .compact) }
}
#Preview("studio · can't load", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.stageFail, tab: .stage) { stageScreen($0, .compact) }
}
#Preview("studio · iPad", traits: .fixedLayout(width: 820, height: 1000)) {
    PreviewHost(.happy, tab: .stage) { stageScreen($0, .regular) }
}
#Preview("studio · mac width", traits: .fixedLayout(width: 1180, height: 820)) {
    PreviewHost(.happy, tab: .stage) { stageScreen($0, .regular) }
}
#Preview("studio · mac width, not connected", traits: .fixedLayout(width: 1180, height: 820)) {
    PreviewHost(.stageNotConnected, tab: .stage) { stageScreen($0, .regular) }
}

// MARK: sheets

/// Loads the stage the way the tab does, then shows the content (a sheet does not load it itself).
private struct LoadedStage<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: (AppModel) -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready { content(model) } else { Color.clear }
        }
        .task {
            await model.stage.load()
            ready = true
        }
    }
}

#Preview("pick for the spotlight", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedStage(model: model) { StagePickSheet(controller: StageController(model: $0)) }
    }
}
#Preview("edit reward", traits: .fixedLayout(width: 390, height: 460)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedStage(model: model) { StageRewardSheet(controller: StageController(model: $0), kind: .summon) }
    }
}
#endif
