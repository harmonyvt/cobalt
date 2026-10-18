#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the links tab on the preview server: three sample links (a video + webp + photo, two webps, four
// files with one gone private) under two sample collections ("memes", "for discord"), none yet, and a listing that
// fails; a collection's screen (with links, and empty), and the new-collection sheet. The thumbnails are network
// pictures, so they stay blank in a preview.

#Preview("links · happy", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#Preview("links · happy, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
        .preferredColorScheme(.dark)
}
#Preview("links · AX3 text", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
        .dynamicTypeSize(.accessibility3)
}
#Preview("links · empty", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.shareLinksEmpty, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#Preview("links · listing fails", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.shareLinksFail, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#Preview("links · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}

// MARK: collections (APP-API-CONTRACT section 26)

/// Loads the store the way the tab does, then shows the content (a pushed screen or a sheet does not refresh itself).
private struct LoadedLinks<Content: View>: View {
    let model: AppModel
    /// Runs after the first refresh (makes the empty collection, for one).
    var prepare: (AppModel) async -> Void = { _ in }
    @ViewBuilder let content: (AppModel) -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready { content(model) } else { Color.clear }
        }
        .task {
            await model.shareSets.refresh()
            await prepare(model)
            ready = true
        }
    }
}

#Preview("links · collections, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
        .preferredColorScheme(.dark)
}
#Preview("collection · memes", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) { model in
            NavigationStack { CollectionScreen(model: model, collectionID: "PrEvIeWcoll00001") }
        }
    }
}
#Preview("collection · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) { model in
            NavigationStack { CollectionScreen(model: model, collectionID: "PrEvIeWcoll00001") }
        }
    }
}
#Preview("collection · empty", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model, prepare: { model in
            _ = try? await model.shareSets.createCollection(name: "later")
        }) { model in
            NavigationStack { CollectionScreen(model: model, collectionID: model.shareSets.collections.first?.id ?? "") }
        }
    }
}
#Preview("new collection · sheet", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) { model in
            CollectionSheet(model: model, request: .create(preselected: ["9000000000000000002"]))
        }
    }
}
#Preview("rename collection · sheet", traits: .fixedLayout(width: 390, height: 400)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) { model in
            CollectionSheet(model: model, request: .rename(model.shareSets.collections[0]))
        }
    }
}
#endif
