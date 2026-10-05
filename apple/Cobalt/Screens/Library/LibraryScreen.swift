import CobaltKit
import SwiftUI

/// The library tab: one card per media (CONTRACT-MEDIA 1.13), as native lists. A card is the media, not the
/// post's files: its picture is the newest webp (else the video) at its real aspect, and its chips name what
/// exists (`video`, `webp ×3`). Tapping the card opens the same tabbed `MediaDetail` as the orbit, on that
/// picture's tab; tapping a chip opens that tab.
///
/// Compact (iPhone): an inset-grouped list that pushes the detail. Regular and wide (iPad, Mac): a list and the
/// detail side by side (a split view; an `HSplitView` on the Mac, whose own window already has the sidebar).
/// The cards are the server's posts in the server's order (latest activity first) and its counts; the device's
/// own copies join each one (`AppModel.mediaItem(for:)`).
struct LibraryScreen: View {
    let model: AppModel
    let tier: Tier

    private var library: LibraryModel { model.library }

    var body: some View {
        Group {
            if tier == .compact {
                #if os(macOS)
                NavigationStack { LibraryList(model: model).libraryChrome(model) }
                #else
                LibraryList(model: model).libraryChrome(model)
                #endif
            } else {
                LibrarySplit(model: model)
            }
        }
        .task {
            #if DEBUG
            if LibraryDebug.state != nil { return }
            #endif
            if library.posts.isEmpty { await library.refresh() }
        }
    }
}

/// The title, the "15 posts · 24 files" subtitle, and paste / file in the toolbar. On iPad it goes
/// on the list column of the split view, which owns its own navigation bar.
private struct LibraryChrome: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .navigationTitle(Copy.library)
            .navigationSubtitle(Copy.libraryCounts(posts: model.library.postCount, files: model.library.fileCount))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    PasteFileButtons(showsFile: model.capabilities.showsFileButton)
                }
            }
    }
}

private extension View {
    func libraryChrome(_ model: AppModel) -> some View { modifier(LibraryChrome(model: model)) }
}

// MARK: - the three states of an empty list

/// What the list shows in place of cards.
enum LibraryProblemState: Equatable {
    case failed, loading, empty
}

/// "can't load the library." + "try again", the loading spinner, or the quiet empty line.
struct LibraryProblem: View {
    let state: LibraryProblemState
    let retry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .failed:
                ContentUnavailableView {
                    Label(Copy.libraryFailed, systemImage: Symbol.error)
                        .font(CobaltType.body)
                } actions: {
                    Button(Copy.tryAgain, systemImage: Symbol.retry, action: retry)
                        .buttonStyle(.cobaltSecondary(fullWidth: false))
                }
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            case .empty:
                ContentUnavailableView {
                    Label(Copy.libraryEmpty, systemImage: Symbol.library)
                        .font(CobaltType.body)
                }
            }
        }
    }
}

/// What the screen shows for the library as it is now (debug builds can force a state for evidence).
@MainActor
private func problemState(_ library: LibraryModel) -> LibraryProblemState {
    #if DEBUG
    if let forced = LibraryDebug.state { return forced }
    #endif
    if library.failure != nil { return .failed }
    return library.isLoading ? .loading : .empty
}

/// The cards: the library's posts, each joined with the device's copies. Debug builds can empty the list.
@MainActor
private func libraryPosts(_ library: LibraryModel) -> [LibraryPost] {
    #if DEBUG
    if LibraryDebug.state != nil { return [] }
    #endif
    return library.posts
}

// MARK: - the card

/// The card's heading: the service in semibold, the reference in the caption colour ("x · 2105435404002562056").
private func cardTitle(_ item: MediaItem, size: CGFloat = 13) -> (text: Text, spoken: String) {
    let (service, ref) = Copy.libraryPostTitle(service: item.service, ref: item.ref)
    let head = Text(service).font(Font.cobalt(size, .semibold, relativeTo: .body)).foregroundStyle(.primary)
    let tail = Text(ref.map { " · \($0)" } ?? "").font(Font.cobalt(size, .regular, relativeTo: .body)).foregroundStyle(.secondary)
    return (Text("\(head)\(tail)"), LibraryCardCopy.spokenTitle(service: service, ref: ref))
}

/// One media as a library card: preview, title, meta, and its rendition chips. `openFace` makes the head a
/// button (compact: it pushes the detail); without it the surrounding row owns the tap (the split's
/// selection). A chip always opens its own tab.
struct MediaCard: View {
    let item: MediaItem
    var previewSize: CGFloat = 64
    var openFace: (() -> Void)?
    let openTab: (Rendition.ID) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var title: (text: Text, spoken: String) { cardTitle(item) }
    private var meta: String { LibraryCardCopy.meta(item, now: Date()) }
    private var stacked: Bool { typeSize.isAccessibilitySize }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            title.text.lineLimit(stacked ? nil : 1).truncationMode(.middle)
            Text(meta)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
                .lineLimit(stacked ? nil : 2)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headContent: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    MediaPreview(item: item, size: previewSize)
                    details
                }
            } else {
                HStack(spacing: 12) {
                    MediaPreview(item: item, size: previewSize)
                    details
                    if openFace != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var head: some View {
        let label = Copy.Media.planetA11y(title: title.spoken, webps: item.webpCount, hasVideo: item.video != nil)
        if let openFace {
            Button(action: openFace) { headContent }
                .buttonStyle(CardPress())
                .accessibilityLabel(label)
                .accessibilityValue(meta)
        } else {
            headContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
                .accessibilityValue(meta)
        }
    }

    private var chipViews: some View {
        Group {
            if let video = item.video {
                RenditionChip(style: .video(hosted: video.hosted != nil || video.publicURL != nil,
                                            privateCopy: video.file != nil)) { openTab(video.id) }
            }
            if let newest = item.webps.last {
                RenditionChip(style: .webp(count: item.webpCount)) { openTab(newest.id) }
            }
        }
    }

    private var chips: some View {
        // side by side; stacked when huge text does not leave the room
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chipViews }
            VStack(alignment: .leading, spacing: 0) { chipViews }
        }
        // under the picture's title, or flush left when the picture sits above it
        .padding(.leading, stacked ? 0 : previewSize + 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            chips
        }
    }
}

// MARK: - compact: inset-grouped list that pushes the detail

/// What a card opened: the media as it was then (the detail keeps itself current) and the tab to start on.
private struct OpenedMedia: Identifiable, Hashable {
    let item: MediaItem
    let initial: Rendition.ID?

    var id: String { "\(item.id)|\(initial ?? "")" }
    static func == (a: OpenedMedia, b: OpenedMedia) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct LibraryList: View {
    let model: AppModel
    @State private var opened: OpenedMedia?
    /// The card "open in library" asked for: scrolled to, and lit for a moment.
    @State private var lit: String?
    private var library: LibraryModel { model.library }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = library.expandedPostID, library.posts.contains(where: { $0.id == id }) else { return }
        withAnimation(Motion.card) { proxy.scrollTo(id, anchor: .center) }
        lit = id
        library.expandedPostID = nil
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lit == id { withAnimation(Motion.card) { lit = nil } }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                let posts = libraryPosts(library)
                if posts.isEmpty {
                    Section {
                        LibraryProblem(state: problemState(library)) { Task { await library.refresh() } }
                            .listRowBackground(Color.clear)
                    }
                }
                // One section (one card) per media.
                ForEach(posts) { post in
                    let item = model.mediaItem(for: post)
                    Section {
                        MediaCard(
                            item: item,
                            openFace: { opened = OpenedMedia(item: item, initial: item.face.id) },
                            openTab: { opened = OpenedMedia(item: item, initial: $0) })
                            .id(post.id)
                    }
                    .listRowBackground(lit == post.id ? CobaltColor.focus.opacity(0.14) : nil)
                    .onAppear {
                        if post.id == library.posts.last?.id, library.hasMore { Task { await library.loadMore() } }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .refreshable { await library.refresh() }
            .accessibilityLabel(Copy.postsA11y)
            .onAppear { reveal(proxy) }
            .onChange(of: library.expandedPostID) { _, _ in reveal(proxy) }
        }
        .navigationDestination(item: $opened) { target in
            MediaDetail(model: model, item: target.item, initial: target.initial)
        }
    }
}

// MARK: - regular and wide: list + detail

private struct LibrarySplit: View {
    let model: AppModel
    /// A chip's tab, for the post it was tapped on; a card tap (the list's own selection) clears it.
    @State private var chosen: (post: String, tab: Rendition.ID)?
    private var library: LibraryModel { model.library }

    private var selected: LibraryPost? {
        let posts = libraryPosts(library)
        return posts.first { $0.id == library.expandedPostID } ?? posts.first
    }

    private var selection: Binding<String?> {
        Binding(get: { selected?.id }, set: { library.expandedPostID = $0; chosen = nil })
    }

    private var list: some View {
        List(selection: selection) {
            let posts = libraryPosts(library)
            if posts.isEmpty {
                Section {
                    LibraryProblem(state: problemState(library)) { Task { await library.refresh() } }
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(posts) { post in
                MediaCard(item: model.mediaItem(for: post), previewSize: 52, openTab: { tab in
                    library.expandedPostID = post.id
                    chosen = (post.id, tab)
                })
                .padding(.bottom, 2)
                .tag(post.id)
                .onAppear {
                    if post.id == library.posts.last?.id, library.hasMore { Task { await library.loadMore() } }
                }
            }
        }
        .refreshable { await library.refresh() }
        .accessibilityLabel(Copy.postsA11y)
    }

    @ViewBuilder
    private var detail: some View {
        if let post = selected {
            let item = model.mediaItem(for: post)
            let initial = chosen.flatMap { $0.post == post.id ? $0.tab : nil }
            NavigationStack {
                MediaDetail(model: model, item: item, initial: initial ?? item.face.id)
            }
            // a different card or chip is a fresh screen: its tab, its own state
            .id("\(post.id)|\(initial ?? "")")
        } else {
            LibraryProblem(state: problemState(library)) { Task { await library.refresh() } }
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    var body: some View {
        #if os(macOS)
        HSplitView {
            list.frame(minWidth: 250, idealWidth: 320, maxWidth: 420)
            detail.frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .libraryChrome(model)
        #else
        NavigationSplitView {
            list.navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440).libraryChrome(model)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        #endif
    }
}

#if DEBUG
/// `-previewLibraryState empty|failed|loading` (simulator evidence): the library shows that state with no
/// cards, whatever the scenario holds, and does not load.
enum LibraryDebug {
    static let state: LibraryProblemState? = {
        switch UserDefaults.standard.string(forKey: "previewLibraryState") {
        case "empty": return .empty
        case "failed": return .failed
        case "loading": return .loading
        default: return nil
        }
    }()
}

#Preview("library · compact, renditions") {
    PreviewHost(.renditions, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .compact) }
    }
}
#Preview("library · compact, plain cobalt (no library)") {
    PreviewHost(.plainCobalt, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .compact) }
    }
}
#Preview("library · compact, empty") {
    List { Section { LibraryProblem(state: .empty) {} } }
}
#Preview("library · compact, can't load") {
    List { Section { LibraryProblem(state: .failed) {} } }
}
#Preview("library · compact, loading") {
    List { Section { LibraryProblem(state: .loading) {} } }
}
#Preview("library · compact, AX3 text", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.renditions, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .compact) }
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("library · regular", traits: .fixedLayout(width: 820, height: 760)) {
    PreviewHost(.renditions, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .regular) }
    }
}
#Preview("library · wide list and detail", traits: .fixedLayout(width: 1280, height: 780)) {
    PreviewHost(.renditions, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .wide) }
    }
}
#endif
