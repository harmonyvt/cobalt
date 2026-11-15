import Foundation
import Testing
@testable import CobaltKit

// 8.17: the library's rows as an engine (`LibraryRowsBuilder`, `AppModel.libraryRows`). The pure build gives the rows the
// old in-model build gave; off the main thread a snapshot is assigned only when it changed, and a stale build is dropped.

/// The rows as `AppModel.buildLibraryRows` made them before 8.17, through the models' own join (`mediaItem(for:)`, the
/// store's lookups): the reference the builder's own join must match.
@MainActor
private func referenceRows(_ app: AppModel) -> [LibraryRow] {
    let library = app.library
    let album = library.showingHidden && app.capabilities.hidden
    let known = app.hiddenIndex
    let show = library.show
    let kind = library.kindFilter
    let folded = library.trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let sort = library.sort
    if !album, let results = library.activeSearchResults {
        let loaded = Dictionary(library.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func keeps(_ row: LibraryRow) -> Bool {
            (show == .everything || row.passes(show)) && kind.passes(kind: row.kind, emote: row.emote, hasWebp: row.hasWebp)
        }
        var seen = Set<String>()
        var rows: [LibraryRow] = []
        for post in results.filter({ !$0.hidden && !known.contains(post: $0.id) }) where seen.insert(post.id).inserted {
            let row = LibraryRow(item: app.mediaItem(for: loaded[post.id] ?? post))
            if keeps(row) { rows.append(row) }
        }
        let extra = library.posts
            .filter { !seen.contains($0.id) && !$0.hidden && !known.contains(post: $0.id) }
            .map { LibraryRow(item: app.mediaItem(for: $0)) }
            .filter { keeps($0) && $0.matches(folded: folded) }
            .sorted { LibraryRow.areInIncreasingOrder($0, $1, by: sort) }
        return rows + extra
    }
    let source = album ? library.hiddenPosts : library.posts.filter { !$0.hidden && !known.contains(post: $0.id) }
    var rows = source.map { LibraryRow(item: app.mediaItem(for: $0)) }
    if show != .everything { rows = rows.filter { $0.passes(show) } }
    rows = rows.filter { kind.passes(kind: $0.kind, emote: $0.emote, hasWebp: $0.hasWebp) }
    if !library.trimmedQuery.isEmpty { rows = rows.filter { $0.matches(folded: folded) } }
    return rows.sorted { LibraryRow.areInIncreasingOrder($0, $1, by: sort) }
}

/// The kind chips' counts as `LibraryKindChips` made them in its body before 8.17.
@MainActor
private func referenceCounts(_ app: AppModel) -> [LibraryKindFilter: Int] {
    var out: [LibraryKindFilter: Int] = [:]
    for post in app.library.showingHidden ? app.library.hiddenPosts : app.library.posts {
        if post.isEmote { out[.emotes, default: 0] += 1; continue }
        let item = app.mediaItem(for: post)
        out[.all, default: 0] += 1
        for chip in LibraryKindFilter.chips(kind: item.kind, hasWebp: item.hasMadeWebp) { out[chip, default: 0] += 1 }
    }
    return out
}

@MainActor
private func offMainApp(_ scenario: PreviewScenario = .renditions) -> AppModel {
    let app = AppModel.makePreview(scenario, timeScale: 1, clock: SystemClock())
    app.library.sort = .newest
    app.library.show = .everything
    app.library.kindFilter = .all
    app.libraryRowsEngine.inline = false
    return app
}

/// Waits (a bounded while) for the main actor to have run the input watch and its build.
@MainActor
private func waitForPublishes(_ app: AppModel, atLeast n: Int) async throws {
    for _ in 0..<400 where app.libraryRowsEngine.publishes < n {
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct LibraryRowsBuilderTests {
    @Test(arguments: [PreviewScenario.renditions, .happy, .offline, .hidden, .galleryMixed])
    func theBuilderGivesTheRowsTheModelsGave(_ scenario: PreviewScenario) {
        let app = AppModel.makePreview(scenario, timeScale: 1, clock: SystemClock())
        app.library.posts += PreviewData.uploadPosts(now: SystemClock().now())
        let views: [(LibraryModel) -> Void] = [
            { $0.sort = .newest },
            { $0.sort = LibrarySort(key: .title, ascending: true) },
            { $0.sort = LibrarySort(key: .size, ascending: false); $0.show = .publicOnly },
            { $0.show = .uploads; $0.sort = LibrarySort(key: .kind, ascending: true) },
            { $0.show = .everything; $0.kindFilter = .webps },
            { $0.kindFilter = .all; $0.query = "  kitchen " },
            { $0.query = ""; $0.showingHidden = true },
        ]
        for set in views {
            set(app.library)
            let built = LibraryRowsBuilder.build(app.libraryRowsInputs)
            #expect(built.rows == referenceRows(app))
            #expect(built.kindCounts == referenceCounts(app))
            #expect(app.libraryRows == built.rows)                          // the inline path (previews, tests) is the same
        }
    }

    @Test func theServersSearchResultsComeFirstThenTheNameMatches() {
        let app = AppModel.makePreview(.renditions, timeScale: 1, clock: SystemClock())
        app.library.query = "x"
        let posts = app.library.posts
        app.library.searchResults = Array(posts.suffix(2).reversed())
        #expect(app.library.activeSearchResults?.count == 2)
        #expect(LibraryRowsBuilder.build(app.libraryRowsInputs).rows == referenceRows(app))
    }

    @Test func aRenameOnThisDeviceIsLaidOver() throws {
        let app = AppModel.makePreview(.renditions, timeScale: 1, clock: SystemClock())
        let first = try #require(app.libraryRows.first)
        app.library.localTitles[first.item.id] = "my own name"
        let built = LibraryRowsBuilder.build(app.libraryRowsInputs)
        #expect(built.rows == referenceRows(app))
        #expect(built.rows.first { $0.id == first.id }?.item.localTitle == "my own name")
    }
}

@MainActor
struct LibraryRowsSnapshotTests {
    @Test func theFirstReadIsBuiltAtOnceAndLaterOnesOffTheMainThread() async throws {
        let app = offMainApp()
        let first = app.libraryRows                                       // synchronous: the first frame is not empty
        #expect(first.count == 6 && app.libraryRowsEngine.started && app.libraryRowsEngine.publishes == 1)
        #expect(first == referenceRows(app))

        app.library.posts.removeLast()
        // nothing ran yet: the snapshot is still the one on screen until the build lands
        #expect(app.libraryRows == first)
        try await waitForPublishes(app, atLeast: 2)                       // the input watch started the build by itself
        #expect(app.libraryRows.count == 5 && app.libraryRows == referenceRows(app))
        #expect(await app.settledLibraryRows() == referenceRows(app))
    }

    @Test func aChangeThatMovesNoRowPublishesNothing() async {
        let app = offMainApp()
        _ = app.libraryRows
        _ = await app.settledLibraryRows()
        let before = app.libraryRowsEngine.publishes
        let rows = app.libraryRows

        // an input changed (a rename of a media no row shows), but the rows did not
        app.library.localTitles["nobody-has-this-id"] = "x"
        let settled = await app.settledLibraryRows()
        #expect(settled == rows)
        #expect(app.libraryRowsEngine.publishes == before)
        #expect(app.libraryRowsEngine.wanted == app.libraryRowsInputs)   // the build ran, its result was not assigned
        #expect(app.libraryRowsEngine.task == nil)
    }

    @Test func aStaleBuildIsDropped() async {
        let app = offMainApp()
        _ = app.libraryRows
        _ = await app.settledLibraryRows()
        let before = app.libraryRowsEngine.publishes

        app.library.sort = LibrarySort(key: .title, ascending: true)
        let stale = app.scheduleLibraryRows(app.libraryRowsInputs)
        let staleGeneration = app.libraryRowsEngine.generation
        app.library.posts.removeLast()
        let fresh = app.scheduleLibraryRows(app.libraryRowsInputs)
        #expect(stale != nil && fresh != nil && app.libraryRowsEngine.generation == staleGeneration + 1)

        await stale?.value
        await fresh?.value
        _ = await app.settledLibraryRows()
        // only the newest build was assigned, and it holds both changes
        #expect(app.libraryRowsEngine.publishes == before + 1)
        #expect(app.libraryRows == referenceRows(app) && app.libraryRows.count == 5)
    }

    @Test func theSameInputsAreNotBuiltTwice() async {
        let app = offMainApp()
        _ = app.libraryRows
        _ = await app.settledLibraryRows()
        let generation = app.libraryRowsEngine.generation
        #expect(app.scheduleLibraryRows(app.libraryRowsInputs) == nil)
        #expect(app.libraryRowsEngine.generation == generation)
    }

    @Test func theKindCountsComeWithTheRows() async {
        let app = offMainApp(.galleryMixed)
        _ = app.libraryRows
        _ = await app.settledLibraryRows()
        #expect(app.libraryKindCounts == referenceCounts(app))
    }
}
