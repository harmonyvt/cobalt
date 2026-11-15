#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the swarms screens on the preview server (`PreviewSwarms.swift`): the list, the one swarm screen in each state
// (waiting, running, ready, applying, done, failed, declined), its plain-lists detail, the agent sheet, the check screen and
// the results board. The preview server's story swarm takes the state `-previewSwarm` names; a canvas has no launch arguments,
// so the host sets it first.

/// Builds a preview model on the story state `state`, loads the list and shows the swarm `id`.
private struct SwarmPreviewHost<Content: View>: View {
    @State private var model: AppModel
    private let id: String?
    private let content: (AppModel) -> Content

    init(_ state: PreviewSwarmStart, id: String? = nil, @ViewBuilder content: @escaping (AppModel) -> Content) {
        UserDefaults.standard.set(state.rawValue, forKey: "previewSwarm")
        let model = AppModel.preview(.happy)
        model.selectedTab = .swarms
        _model = State(initialValue: model)
        self.id = id ?? state.swarmID
        self.content = content
    }

    var body: some View {
        content(model)
            .cobaltRoot(model: model)
            .task {
                await model.swarms.loadList()
                if let id { await model.swarms.show(id: id) }
            }
            .onDisappear { model.swarms.hide() }
    }
}

@MainActor
private func one(_ model: AppModel, id: String, step: SwarmStep? = nil) -> some View {
    NavigationStack { SwarmScreen(model: model, dest: SwarmDestination(id: id, step: step)) }
}

#Preview("swarms · list", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.running) { model in NavigationStack { SwarmsScreen(model: model, tier: .compact) } }
}
#Preview("swarms · list, light", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.awaiting) { model in NavigationStack { SwarmsScreen(model: model, tier: .compact) } }
        .preferredColorScheme(.light)
}
#Preview("swarms · waiting for you", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.awaiting) { one($0, id: PreviewSwarmIDs.story) }
}
#Preview("swarms · what it's told", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.awaiting) { one($0, id: PreviewSwarmIDs.story, step: .told) }
}
#Preview("swarms · running", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.running) { one($0, id: PreviewSwarmIDs.story) }
}
#Preview("swarms · running, AX3 text", traits: .fixedLayout(width: 390, height: 1100)) {
    SwarmPreviewHost(.running) { one($0, id: PreviewSwarmIDs.story) }
        .dynamicTypeSize(.accessibility3)
}
#Preview("swarms · ready to apply", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.review) { one($0, id: PreviewSwarmIDs.story) }
}
#Preview("swarms · applying", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.applying) { one($0, id: PreviewSwarmIDs.shorten) }
}
#Preview("swarms · done", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.done) { one($0, id: PreviewSwarmIDs.story) }
}
#Preview("swarms · failed", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.failed) { one($0, id: PreviewSwarmIDs.failed) }
}
#Preview("swarms · declined", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.declined) { one($0, id: PreviewSwarmIDs.declined) }
}
#Preview("swarms · agent sheet (asking)", traits: .fixedLayout(width: 390, height: 700)) {
    SwarmPreviewHost(.running) { model in
        SwarmAgentSheet(model: model, agent: .constant(3), wide: false, close: {})
    }
}
#Preview("swarms · agent sheet (done)", traits: .fixedLayout(width: 390, height: 700)) {
    SwarmPreviewHost(.review) { model in
        SwarmAgentSheet(model: model, agent: .constant(4), wide: false, close: {})
    }
}
#Preview("swarms · check changes", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.review) { model in NavigationStack { SwarmCheckScreen(model: model) } }
}
#Preview("swarms · results board", traits: .fixedLayout(width: 390, height: 844)) {
    SwarmPreviewHost(.board) { model in NavigationStack { SwarmBoardScreen(model: model) } }
}
#Preview("swarms · mac width", traits: .fixedLayout(width: 1100, height: 700)) {
    SwarmPreviewHost(.running, id: nil) { model in NavigationStack { SwarmsScreen(model: model, tier: .regular) } }
}
#endif
