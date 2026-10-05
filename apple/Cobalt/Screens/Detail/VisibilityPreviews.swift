#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the public/private switch (CONTRACT-VISIBILITY 6.2) over `AppModel.previewVisibility`: the
// `.renditions` media listed the way `GET /library?v=2` lists it (one file per rendition; the first video is public,
// the instagram video is private with two public webps and one private), and a server whose switch works, fails
// once per file, or always fails. Interactive: the switch really changes the preview server's state.

@MainActor
private struct VisibilityDetailHost: View {
    @State private var model: AppModel
    private let post: String
    private let tab: Int?

    init(_ mode: VisibilityPreviewMode = .working, post: String, tab: Int? = nil) {
        _model = State(initialValue: AppModel.previewVisibility(mode))
        self.post = post
        self.tab = tab
    }

    var body: some View {
        if let found = model.library.posts.first(where: { $0.id == post }) {
            let item = model.mediaItem(for: found)
            NavigationStack {
                MediaDetail(
                    model: model, item: item,
                    initial: tab.flatMap { item.renditions.indices.contains($0) ? item.renditions[$0].id : nil })
            }
        }
    }
}

@MainActor
private struct VisibilityLibraryHost: View {
    @State private var model: AppModel
    private let tier: Tier

    init(tier: Tier = .compact, mode: LibraryViewMode = .mosaic) {
        let model = AppModel.previewVisibility(.working)
        model.selectedTab = .library
        model.library.viewMode = mode
        _model = State(initialValue: model)
        self.tier = tier
    }

    var body: some View {
        let screen = LibraryScreen(model: model, tier: tier)
        if tier == .compact {
            NavigationStack { screen }
        } else {
            screen
        }
    }
}

#Preview("visibility · public video (switch on, link, copy)") {
    VisibilityDetailHost(post: "Dd55fEyN1Yy")
}
#Preview("visibility · private video (switch off)") {
    VisibilityDetailHost(post: "Dd7P496wolG")
}
#Preview("visibility · private webp (lock, not on this device)") {
    VisibilityDetailHost(post: "Dd7P496wolG", tab: 3)
}
#Preview("visibility · switch fails once, then works") {
    VisibilityDetailHost(.failsOnce, post: "Dd7P496wolG")
}
#Preview("visibility · switch always fails") {
    VisibilityDetailHost(.failing, post: "Dd55fEyN1Yy")
}
#Preview("visibility · wide", traits: .fixedLayout(width: 1100, height: 760)) {
    VisibilityDetailHost(post: "Dd7P496wolG", tab: 1)
}
#Preview("visibility · dark") {
    VisibilityDetailHost(post: "Dd55fEyN1Yy").preferredColorScheme(.dark)
}
#Preview("visibility · library mosaic: globe and lock", traits: .fixedLayout(width: 390, height: 844)) {
    VisibilityLibraryHost()
}
#Preview("visibility · library list", traits: .fixedLayout(width: 390, height: 844)) {
    VisibilityLibraryHost(mode: .table)
}
#Preview("visibility · library table (iPad)", traits: .fixedLayout(width: 1100, height: 760)) {
    VisibilityLibraryHost(tier: .regular, mode: .table)
}
#endif
