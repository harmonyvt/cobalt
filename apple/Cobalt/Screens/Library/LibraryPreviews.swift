#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of CONTRACT-LIBRARY2 section 9 L: mosaic compact, regular and wide, AX3, one failing picture,
// the skeleton, the table on the iPhone, the iPad's Table with the inspector, the Mac's, the sort menu, the
// context menu, the rename alert, a search with no match, empty, failed, the loading-all line, plain cobalt.
// All run on `AppModel.preview(.renditions)` (the fixture's six posts) plus synthetic media with pictures drawn
// into a temp folder (`LibraryPreviewData`); nothing touches the network.

/// A preview model, set up before the first frame (the view mode, search, sort and show are remembered state
/// of the library model, so they are set on it rather than faked).
@MainActor
private struct LibraryPreviewHost: View {
    @State private var model: AppModel
    private let tier: Tier
    private let extra: [LibraryRow]

    init(
        _ scenario: PreviewScenario = .renditions, tier: Tier = .compact, mode: LibraryViewMode = .mosaic,
        query: String = "", sort: LibrarySort = .newest, show: LibraryShow = .everything, extra: Int = 36,
        failing: Bool = false
    ) {
        UserDefaults.standard.removeObject(forKey: "library.inspector")
        let model = AppModel.preview(scenario)
        model.selectedTab = .library
        model.library.viewMode = mode
        model.library.sort = sort
        model.library.show = show
        model.library.query = query
        _model = State(initialValue: model)
        self.tier = tier
        self.extra = extra > 0 ? LibraryPreviewData.rows(count: extra, failing: failing) : []
    }

    var body: some View {
        let screen = LibraryScreen(model: model, tier: tier).environment(\.libraryDebugRows, extra)
        if tier == .compact {
            NavigationStack { screen }
        } else {
            screen
        }
    }
}

#Preview("mosaic · compact", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost()
}
#Preview("mosaic · compact, dark", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost().preferredColorScheme(.dark)
}
#Preview("mosaic · AX3 text", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost().dynamicTypeSize(.accessibility3)
}
#Preview("mosaic · one picture fails", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost(failing: true)
}
/// The first load: nine grey tiles at mixed aspects, static.
@MainActor
private struct SkeletonPreview: View {
    @State private var model = AppModel.preview(.renditions)

    var body: some View {
        NavigationStack {
            LibraryMosaic(rows: [], controller: LibraryController(model: model), tier: .compact, footer: .none, skeleton: true)
                .navigationTitle(Copy.library)
        }
    }
}
#Preview("mosaic · skeleton", traits: .fixedLayout(width: 390, height: 844)) {
    SkeletonPreview()
}
#Preview("mosaic · regular (iPad portrait)", traits: .fixedLayout(width: 820, height: 1000)) {
    LibraryPreviewHost(tier: .regular)
}
#Preview("mosaic · wide with inspector", traits: .fixedLayout(width: 1280, height: 780)) {
    LibraryPreviewHost(tier: .wide)
}
#Preview("table · iPhone", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost(mode: .table)
}
#Preview("table · iPhone, AX3 text", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost(mode: .table).dynamicTypeSize(.accessibility3)
}
#Preview("table · iPad 1194, inspector open", traits: .fixedLayout(width: 1194, height: 834)) {
    LibraryPreviewHost(tier: .regular, mode: .table)
}
#Preview("table · Mac", traits: .fixedLayout(width: 1100, height: 700)) {
    LibraryPreviewHost(tier: .regular, mode: .table, sort: LibrarySort(key: .size, ascending: false))
}
#Preview("search · no match", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost(query: "zzz", extra: 0)
}
#Preview("search · a few matches", traits: .fixedLayout(width: 390, height: 844)) {
    LibraryPreviewHost(mode: .table, query: "x · ", extra: 0)
}
#Preview("empty", traits: .fixedLayout(width: 390, height: 600)) {
    List { Section { LibraryProblem(state: .empty) {} } }
}
#Preview("can't load", traits: .fixedLayout(width: 390, height: 600)) {
    List { Section { LibraryProblem(state: .failed) {} } }
}
#Preview("loading the whole library", traits: .fixedLayout(width: 390, height: 120)) {
    LibraryLoadingLine(loaded: 60, total: 140)
}
#Preview("plain cobalt (no library tab)", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.plainCobalt, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .compact) }
    }
}

/// The context menu's items and the face preview above them, as a plain list (a `Menu` cannot be opened in a
/// preview).
@MainActor
private struct LibraryMenuPreview: View {
    @State private var model = AppModel.preview(.renditions)
    private let rows = LibraryPreviewData.rows(count: 3)

    var body: some View {
        let controller = LibraryController(model: model)
        VStack(spacing: 16) {
            if let row = rows.first { LibraryPreviewCard(row: row).clipShape(RoundedRectangle(cornerRadius: 14)) }
            if let row = rows.first {
                VStack(alignment: .leading, spacing: 0) { LibraryMenuItems(row: row, controller: controller) }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
#Preview("context menu", traits: .fixedLayout(width: 390, height: 640)) {
    LibraryMenuPreview()
}

/// The sort and show menu's content (the same buttons the toolbar menu holds), as a list.
#Preview("sort and show menu", traits: .fixedLayout(width: 300, height: 520)) {
    List {
        Section(Copy.Library2.sort) {
            ForEach(LibrarySortKey.allCases, id: \.self) { key in
                if key == .date {
                    Label(Copy.Library2.name(key), systemImage: Symbol.Library.descending)
                } else {
                    Text(Copy.Library2.name(key))
                }
            }
        }
        Section(Copy.Library2.show) {
            ForEach(LibraryShow.allCases, id: \.self) { show in
                HStack {
                    Text(Copy.Library2.name(show))
                    Spacer()
                    if show == .everything { Image(systemName: Symbol.checkmark) }
                }
            }
        }
    }
}

@MainActor
private struct RenamePreview: View {
    @State private var model = AppModel.preview(.renditions)
    @State private var open = true

    var body: some View {
        let item = model.library.posts.first.map { model.mediaItem(for: $0) }
        return Color.clear.overlay {
            if let item { Text(item.titleText).font(CobaltType.body) }
        }
        .task { if model.library.posts.isEmpty { await model.library.refresh() } }
        .modifier(RenameHost(model: model, open: $open))
    }
}

@MainActor
private struct RenameHost: ViewModifier {
    let model: AppModel
    @Binding var open: Bool

    func body(content: Content) -> some View {
        if let post = model.library.posts.first {
            content.renameAlert(item: model.mediaItem(for: post), isPresented: $open, model: model)
        } else {
            content
        }
    }
}
#Preview("rename alert", traits: .fixedLayout(width: 390, height: 600)) {
    RenamePreview()
}
#endif
