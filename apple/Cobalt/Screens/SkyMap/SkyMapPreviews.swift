#if DEBUG
import CobaltKit
import SwiftUI

// Previews of the sky map on `AppModel.preview(.skyMap)`: about 150 mock posts in eight clusters (cats, minecraft, anime,
// cooking, coffee, the harbour, guitar, skate) that the model lays out for real, so the stars do settle in the canvas. Night and day,
// laying out, empty, failed, a post's card, the iPad and the Mac. Nothing touches the network.

/// A preview model, loaded to the settled sky before the first frame when `settled` (else the screen loads it itself,
/// and the preview shows the stars arranging).
@MainActor
private struct SkyMapPreviewHost: View {
    @State private var model: AppModel
    @State private var shown: Bool
    private let settled: Bool

    init(_ scenario: PreviewScenario = .skyMap, settled: Bool = true) {
        _model = State(initialValue: AppModel.preview(scenario))
        _shown = State(initialValue: !settled)
        self.settled = settled
    }

    var body: some View {
        Group {
            if shown {
                SkyMapScreen(model: model, onOpen: { _ in }, onClose: {})
            } else {
                Color.black
            }
        }
        .task {
            guard settled, !shown else { return }
            await model.skyMap.load()
            shown = true
        }
    }
}

/// The bare sky behind a message (the empty state needs a server with no posts, which the preview server has no
/// scenario for).
private struct SkyMessagePreview: View {
    let kind: SkyMapMessage.Kind
    let dark: Bool

    var body: some View {
        let theme = dark ? SkyTheme.night : SkyTheme.day
        ZStack {
            LinearGradient(colors: [theme.top.color(), theme.bottom.color()], startPoint: .top, endPoint: .bottom)
            SkyMapMessage(kind: kind, theme: theme, retry: {})
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

#Preview("ready · dark", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMapPreviewHost().preferredColorScheme(.dark)
}
#Preview("ready · light", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMapPreviewHost().preferredColorScheme(.light)
}
#Preview("laying out · dark", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMapPreviewHost(settled: false).preferredColorScheme(.dark)
}
#Preview("laying out · light", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMapPreviewHost(settled: false).preferredColorScheme(.light)
}
#Preview("empty · dark", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMessagePreview(kind: .empty, dark: true)
}
#Preview("empty · light", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMessagePreview(kind: .empty, dark: false)
}
// `.coldStart` has no `GET /library/map`: the server answers 404 and the model fails.
#Preview("failed · dark", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMapPreviewHost(.coldStart, settled: false).preferredColorScheme(.dark)
}
#Preview("failed · message", traits: .fixedLayout(width: 390, height: 844)) {
    SkyMessagePreview(kind: .failed("Can't reach the server."), dark: false)
}
#Preview("iPad width", traits: .fixedLayout(width: 1024, height: 768)) {
    SkyMapPreviewHost().preferredColorScheme(.dark)
}
#Preview("Mac width · light", traits: .fixedLayout(width: 1120, height: 780)) {
    SkyMapPreviewHost().preferredColorScheme(.light)
}

private let sampleCardPost: MapPost = {
    let vector = (0..<256).map { Float(sin(Double($0) * 0.37) * cos(Double($0) * 0.11)) }
    return MapPost(
        id: "PrEvIeWmap0001", title: "cat sofa jump", text: "cat_sofa_jump.mp4 · instagram.com/reel/PrEvIeWmap0001",
        imageURL: nil, latest: Date(), vector: vector)
}()

#Preview("card · dark", traits: .fixedLayout(width: 320, height: 420)) {
    ZStack {
        SkyTheme.night.bottom.color()
        SkyPostCard(post: sampleCardPost, near: ["cat", "sofa", "kitten", "whiskers"], theme: .night, showsOpen: true) {}
    }
    .preferredColorScheme(.dark)
}
#Preview("card · light", traits: .fixedLayout(width: 320, height: 420)) {
    ZStack {
        SkyTheme.day.bottom.color()
        SkyPostCard(post: sampleCardPost, near: ["cat", "sofa", "kitten", "whiskers"], theme: .day, showsOpen: true) {}
    }
    .preferredColorScheme(.light)
}
#endif
