#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of a gallery link's screen (APP-API-CONTRACT 41.4) on the preview server: the harbour link (a video, a
// webp, a photo), the kitchen link with a file gone private ("not shown: private"), the same in the dark, at AX3 text and
// at Mac width, the add-files picker, and the library's link picker. The preview server holds at most 4 files a link,
// so the room reads small. The thumbnails are network pictures, so they stay blank in a preview.

/// Loads the links the way the tab does, then shows the content (a pushed screen does not refresh itself).
private struct LoadedLink<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: (AppModel) -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready { content(model) } else { Color.clear }
        }
        .task {
            await model.shareSets.refresh()
            ready = true
        }
    }
}

private let harbour = "9000000000000000001"
private let kitchen = "9000000000000000003"

#Preview("link · harbour", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLink(model: model) { model in NavigationStack { LinkScreen(model: model, setID: harbour) } }
    }
}
#Preview("link · a file gone private, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLink(model: model) { model in NavigationStack { LinkScreen(model: model, setID: kitchen) } }
    }
    .preferredColorScheme(.dark)
}
#Preview("link · AX3 text", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLink(model: model) { model in NavigationStack { LinkScreen(model: model, setID: harbour) } }
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("link · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLink(model: model) { model in NavigationStack { LinkScreen(model: model, setID: harbour) } }
    }
}
#Preview("link · add files", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLink(model: model) { model in
            LinkFilePicker(
                model: model, isPrivate: false,
                inLink: model.shareSets.set(harbour)?.items.map(\.id) ?? [], room: 1) { _ in }
        }
    }
}
#Preview("library · add to link", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .library) { model in
        LoadedLink(model: model) { model in
            let picks = model.library.posts.prefix(2).map { ShareSetPick(item: model.mediaItem(for: $0)) }
            LinkPickerSheet(
                store: model.shareSets, picks: picks, maximum: model.capabilities.limits.shareSetMax,
                showsBadges: true) { _, _ in }
        }
    }
}
#endif
