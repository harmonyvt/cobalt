#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the library's server search (apple/CONTRACT.md section 13): results in score order with the count,
// the index still catching up, the Space waking up, a failed search falling back to name matches, and the server
// with search turned off. All run on `AppModel.previewSearch(_:)`; nothing touches the network.

@MainActor
private struct LibrarySearchPreviewHost: View {
    @State private var model: AppModel
    private let tier: Tier

    init(_ mode: PreviewSearchMode, query: String, tier: Tier = .compact) {
        let model = AppModel.previewSearch(mode)
        model.selectedTab = .library
        model.library.viewMode = .mosaic
        model.library.sort = .newest
        model.library.show = .everything
        model.library.kindFilter = .all
        model.library.query = query                    // starts the debounce, then the preview server's answer
        _model = State(initialValue: model)
        self.tier = tier
    }

    var body: some View {
        LibraryScreen(model: model, tier: tier)
    }
}

#Preview("search · results") { LibrarySearchPreviewHost(.ready, query: "boats at sea") }
#Preview("search · still indexing") { LibrarySearchPreviewHost(.indexing, query: "coffee") }
#Preview("search · waking up") { LibrarySearchPreviewHost(.stillWaking, query: "night drive") }
#Preview("search · failed, name matches") { LibrarySearchPreviewHost(.failing, query: "kitchen") }
#Preview("search · off on the server") { LibrarySearchPreviewHost(.disabled, query: "dog") }
#Preview("search · regular") { LibrarySearchPreviewHost(.ready, query: "cat", tier: .regular) }

#Preview("search line · every state") {
    VStack(spacing: 8) {
        LibrarySearchLine(state: .searching)
        LibrarySearchLine(state: .results(count: 12, pending: 0))
        LibrarySearchLine(state: .results(count: 12, pending: 3))
        LibrarySearchLine(state: .waking)
        LibrarySearchLine(state: .failed)
        LibrarySearchLine(state: .off)
    }
}
#endif
