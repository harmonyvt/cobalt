import Foundation

// The library's rows as an engine (8.17): a pure build from a copy of everything the rows read, run off the main
// thread, whose finished snapshot the main thread only assigns (`AppModel.libraryRows`, `LibraryView.swift`). Joining,
// filtering and sorting every post in a view body cost a 914 ms frame on the switch to the library (8.16).

/// Everything `AppModel.libraryRows` and `libraryKindCounts` are built from, copied out of the models. Value types
/// only, so a build can take it to another thread. Unchanged arrays compare in O(1) (same storage).
struct LibraryRowsInputs: Sendable, Equatable {
    var posts: [LibraryPost]
    var hiddenPosts: [LibraryPost]
    var showingHidden: Bool
    /// The server still offers the hidden album (`features.hidden`).
    var hiddenServed: Bool
    /// `LibraryModel.activeSearchResults`: the server's answer to the query, when it is in.
    var search: [LibraryPost]?
    var hiddenIndex: HiddenIndex
    var show: LibraryShow
    var kind: LibraryKindFilter
    /// The query, trimmed (`LibraryModel.trimmedQuery`).
    var query: String
    var sort: LibrarySort
    /// The device's media (`OfflineStore.media`).
    var media: [StoredMedia]
    var localTitles: [String: String]
}

/// One finished build: the rows the views show and the kind chips' counts.
struct LibraryRowsSnapshot: Sendable, Equatable {
    var rows: [LibraryRow]
    /// How many posts each kind chip has (`LibraryKindChips`): every post of the list the chips count (the album's while it
    /// is open), whatever the other filters say.
    var kindCounts: [LibraryKindFilter: Int]

    static let empty = LibraryRowsSnapshot(rows: [], kindCounts: [:])
}

enum LibraryRowsBuilder {
    /// The rows: the posts joined with the device's media, filtered by `show` and the kind chip, searched by the query,
    /// sorted by `sort`. While the server's search has answered the query, its posts come first in score order (the
    /// loaded copy of each when there is one), then the name matches it did not return, in `sort` order; `show` and the
    /// kind chip still apply. Pure: the same inputs give the same snapshot on any thread.
    static func build(_ inputs: LibraryRowsInputs) -> LibraryRowsSnapshot {
        let join = LibraryMediaJoin(media: inputs.media, localTitles: inputs.localTitles)
        return LibraryRowsSnapshot(rows: rows(inputs, join: join), kindCounts: kindCounts(inputs, join: join))
    }

    /// The engine's entry point off the main thread: guarded, timed, and compared with the snapshot on screen here, so
    /// the main actor only assigns (and assigns nothing when `changed` is false). Synchronous on purpose: the caller's
    /// detached task is the thread it runs on.
    static func buildOffMain(_ inputs: LibraryRowsInputs, against previous: LibraryRowsSnapshot) -> (LibraryRowsSnapshot, Bool) {
        MainThreadGuard.assertOffMain()
        let built = EngineClock.measure("library.rows") { interned(build(inputs), against: previous) }
        return (built, built != previous)
    }

    /// `built` with every row that equals the previous snapshot's row of the same id replaced by that previous row, so
    /// an unchanged row shares its storage (title, files, renditions) with the one on screen. The views that hold
    /// `[LibraryRow]` are compared by SwiftUI on the main thread at every update: a shared row compares in O(1) (array
    /// and string storage identity) instead of field by field through every file and rendition, which cost a 5.5 s
    /// frame on opening a video in 8.17 (120). The deep compare runs here, off the main thread, once per build.
    static func interned(_ built: LibraryRowsSnapshot, against previous: LibraryRowsSnapshot) -> LibraryRowsSnapshot {
        guard !previous.rows.isEmpty, !built.rows.isEmpty else { return built }
        if built.rows == previous.rows { return LibraryRowsSnapshot(rows: previous.rows, kindCounts: built.kindCounts) }
        let old = Dictionary(previous.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = built.rows.map { row in
            if let kept = old[row.id], kept == row { return kept }
            return row
        }
        return LibraryRowsSnapshot(rows: rows, kindCounts: built.kindCounts)
    }

    private static func rows(_ inputs: LibraryRowsInputs, join: LibraryMediaJoin) -> [LibraryRow] {
        // The hidden chip shows the album (name search only: the server's search never lists a hidden post); every other
        // view leaves hidden posts out, whatever list they came in (APP-API-CONTRACT 37.2).
        // The album is served only while the server still has `features.hidden`.
        let album = inputs.showingHidden && inputs.hiddenServed
        if !album, let results = inputs.search { return searchRows(results, inputs: inputs, join: join) }
        let known = inputs.hiddenIndex
        let source = album ? inputs.hiddenPosts : inputs.posts.filter { !$0.hidden && !known.contains(post: $0.id) }
        var rows = source.map { LibraryRow(item: join.item(for: $0)) }
        if inputs.show != .everything { rows = rows.filter { $0.passes(inputs.show) } }
        let kind = inputs.kind
        rows = rows.filter { kind.passes(kind: $0.kind, emote: $0.emote, hasWebp: $0.hasWebp) }
        if !inputs.query.isEmpty {
            let folded = inputs.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            rows = rows.filter { $0.matches(folded: folded) }
        }
        let sort = inputs.sort
        return rows.sorted { LibraryRow.areInIncreasingOrder($0, $1, by: sort) }
    }

    /// The rows while the server's results are in.
    private static func searchRows(_ results: [LibraryPost], inputs: LibraryRowsInputs, join: LibraryMediaJoin) -> [LibraryRow] {
        let known = inputs.hiddenIndex
        let results = results.filter { !$0.hidden && !known.contains(post: $0.id) }
        let loaded = Dictionary(inputs.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let show = inputs.show
        let kind = inputs.kind
        func keeps(_ row: LibraryRow) -> Bool {
            (show == .everything || row.passes(show)) && kind.passes(kind: row.kind, emote: row.emote, hasWebp: row.hasWebp)
        }
        var seen = Set<String>()
        var rows: [LibraryRow] = []
        for post in results where seen.insert(post.id).inserted {
            let row = LibraryRow(item: join.item(for: loaded[post.id] ?? post))
            if keeps(row) { rows.append(row) }
        }
        let folded = inputs.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let sort = inputs.sort
        let extra = inputs.posts
            .filter { !seen.contains($0.id) && !$0.hidden && !known.contains(post: $0.id) }
            .map { LibraryRow(item: join.item(for: $0)) }
            .filter { keeps($0) && $0.matches(folded: folded) }
            .sorted { LibraryRow.areInIncreasingOrder($0, $1, by: sort) }
        return rows + extra
    }

    /// The kind chips' counts, as `LibraryKindChips` counted them in its body before 8.17: the album's posts while the
    /// hidden chip is on, else the loaded posts; an emote counts only under emotes.
    private static func kindCounts(_ inputs: LibraryRowsInputs, join: LibraryMediaJoin) -> [LibraryKindFilter: Int] {
        var out: [LibraryKindFilter: Int] = [:]
        for post in inputs.showingHidden ? inputs.hiddenPosts : inputs.posts {
            if post.isEmote {
                out[.emotes, default: 0] += 1
                continue
            }
            let item = join.item(for: post)
            out[.all, default: 0] += 1
            for chip in LibraryKindFilter.chips(kind: item.kind, hasWebp: item.hasMadeWebp) { out[chip, default: 0] += 1 }
        }
        return out
    }
}

/// `AppModel.mediaItem(for: LibraryPost)` without the models: the device's media by the keys `MediaItem.joins` matches
/// on, each key to its lowest index (the same answers as `OfflineStore.media(joining:)` and `media(id:)`), built once per
/// build from the copy the build holds, and the device's renames laid over.
struct LibraryMediaJoin: Sendable {
    let media: [StoredMedia]
    let localTitles: [String: String]
    private var byID: [String: Int] = [:]
    private var bySession: [String: Int] = [:]
    private var byWebpURL: [URL: Int] = [:]
    private var byWebpName: [String: Int] = [:]

    init(media: [StoredMedia], localTitles: [String: String]) {
        self.media = media
        self.localTitles = localTitles
        for (i, m) in media.enumerated() {
            if byID[m.id] == nil { byID[m.id] = i }
            for sid in m.sessionIDs where bySession[sid] == nil { bySession[sid] = i }
            for webp in m.webps {
                guard let url = webp.remoteURL else { continue }
                if byWebpURL[url] == nil { byWebpURL[url] = i }
                if let name = MediaItem.mediaName(of: url), byWebpName[name] == nil { byWebpName[name] = i }
            }
        }
    }

    /// The first media (in `media` order) that `MediaItem.joins` to `post`.
    func media(joining post: LibraryPost) -> StoredMedia? {
        var best: Int?
        func take(_ i: Int?) { if let i, i < (best ?? .max) { best = i } }
        take(bySession[post.id])
        if let sid = post.session?.id { take(bySession[sid]) }
        for file in post.files {
            if let url = file.url { take(byWebpURL[url]); continue }
            // `MediaItem.isSameWebp`: a webp file with no link matches by the name its link ends in
            if file.role == .webp, let name = file.mediaName { take(byWebpName[name]) }
        }
        return best.map { media[$0] }
    }

    func media(id: String) -> StoredMedia? { byID[id].map { media[$0] } }

    /// The post joined with the device's media for it; the device's own rename wins over the copy the media carries.
    func item(for post: LibraryPost) -> MediaItem {
        var item = MediaItem.merge(local: media(joining: post), post: post)!     // `post` is non-nil: never nil
        if let local = item.local, let current = media(id: local.id) { item.localTitle = current.customTitle }
        if let title = localTitles[item.id] { item.localTitle = title }
        return item
    }
}
