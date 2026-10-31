import Foundation
import Synchronization

// Search names in previews (APP-API-CONTRACT 48). Every preview server with `features.search` (`AppModel.previewSearch(_:)`,
// `AppModel.previewNames()`, the sky map) also has `features.names` and starts with three names: "Lia" (also called
// `lia-chan`, `my model`; the pink cat girl: two examples, one not), "capy" (a plain "same as" word for capybara, no
// examples) and "the ramen place" (switched off). Scores are a deterministic stand-in for the server's cosines: the meaning's
// words found in what a post "shows" (`PreviewData.searchMeaning`) or its text, mixed with how close the post is to the
// examples, by `strength`. The routes behave like the server's: words normalized, a bad name `400 error.names.bad`, a word
// another name has `409 error.names.taken`, the 101st `409 error.names.too_many`, an unknown id `404 error.names.not_found`.

extension PreviewData {
    /// The ids of the sample names (16 base62 characters, as the server's).
    static let nameIDs = ["PrEvIeWname00001", "PrEvIeWname00002", "PrEvIeWname00003"]

    /// The three sample names, oldest first (`posts` is filled in when listed).
    static func searchNames(now: Date) -> [TaughtName] {
        [
            TaughtName(
                id: nameIDs[0], name: "Lia", aliases: ["lia-chan", "my model"],
                meaning: "pink-haired cat girl with cat ears, my vtuber model", strength: 0.6, cutoff: 0.45, enabled: true,
                yes: ["2105432512428445875", "Dd5JFkMDt4N"], no: ["Dd7P496wolG"], embedded: true,
                createdAt: now.addingTimeInterval(-12 * 86_400), updatedAt: now.addingTimeInterval(-2 * 3_600)),
            TaughtName(
                id: nameIDs[1], name: "capy", meaning: "capybara", strength: 0.5, cutoff: 0.5, enabled: true, embedded: true,
                createdAt: now.addingTimeInterval(-8 * 86_400), updatedAt: now.addingTimeInterval(-8 * 86_400)),
            TaughtName(
                id: nameIDs[2], name: "the ramen place", aliases: ["ramen spot"], meaning: "Ichiran Shibuya, the booth one",
                strength: 0.5, cutoff: 0.55, enabled: false, embedded: true,
                createdAt: now.addingTimeInterval(-3 * 86_400), updatedAt: now.addingTimeInterval(-1 * 86_400)),
        ]
    }

    private static func nameWords(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// What a post "shows", as words: its stand-in meaning and its text.
    private static func shows(_ post: LibraryPost) -> Set<String> {
        Set(nameWords((searchMeaning[post.id] ?? "") + " " + searchText(post)))
    }

    /// The stand-in cosine of two posts: how many of what they show they share.
    private static func closeness(_ a: LibraryPost, _ b: LibraryPost) -> Double {
        let x = Set(nameWords(searchMeaning[a.id] ?? "")), y = Set(nameWords(searchMeaning[b.id] ?? ""))
        guard !x.isEmpty || !y.isEmpty else { return 0.2 }
        return 0.2 + 0.6 * Double(x.intersection(y).count) / Double(max(1, x.union(y).count))
    }

    /// The stand-in for `dot(vector, point)` (48.2): the meaning's words against what the post shows, mixed by `strength`
    /// with its closeness to the examples (less a quarter of its closeness to the not posts). 4 places.
    static func nameScore(_ post: LibraryPost, meaning: String, strength: Double, yes: [String], no: [String], in posts: [LibraryPost]) -> Double {
        let want = nameWords(meaning).filter { $0.count > 2 }
        let shown = shows(post)
        let found = want.filter { w in shown.contains { $0.hasPrefix(w) || w.hasPrefix($0) && $0.count > 2 } }.count
        let m = 0.12 + (want.isEmpty ? 0 : 0.6 * Double(found) / Double(want.count))
        let examples = posts.filter { yes.contains($0.id) }
        let nots = posts.filter { no.contains($0.id) }
        var score = m
        if !examples.isEmpty {
            var c = examples.map { closeness(post, $0) }.reduce(0, +) / Double(examples.count)
            if !nots.isEmpty { c -= 0.25 * nots.map { closeness(post, $0) }.reduce(0, +) / Double(nots.count) }
            score = (1 - strength) * m + strength * c
        }
        return (min(1, max(-1, score)) * 10_000).rounded() / 10_000
    }

    /// Whether `post` carries the name (48.2): marked `yes`, or not marked `no` and at or over the cut-off.
    static func carries(_ post: LibraryPost, _ name: TaughtName, in posts: [LibraryPost]) -> (score: Double, carries: Bool) {
        let score = nameScore(post, meaning: name.meaning, strength: name.strength, yes: name.yes, no: name.no, in: posts)
        if name.yes.contains(post.id) { return (score, true) }
        if name.no.contains(post.id) { return (score, false) }
        return (score, score >= name.cutoff)
    }

    /// The enabled names a query says, as whole words, longest first, one word in the query for one name (48.3).
    static func namesSaid(in query: String, names: [TaughtName]) -> [TaughtName] {
        var q = " " + nameWords(query).joined(separator: " ") + " "
        var said: [TaughtName] = []
        var candidates: [(word: String, name: TaughtName)] = []
        for name in names where name.enabled {
            for raw in [TaughtName.normalize(name.name)] + name.aliases {
                let word = nameWords(raw).joined(separator: " ")
                if !word.isEmpty { candidates.append((word: word, name: name)) }
            }
        }
        candidates.sort { $0.word.count > $1.word.count }
        for (word, name) in candidates where q.contains(" \(word) ") {
            q = q.replacingOccurrences(of: " \(word) ", with: "  ")
            if !said.contains(where: { $0.id == name.id }) { said.append(name) }
        }
        return said
    }
}

/// The names the preview "server" holds, and every call made (`"NAME add Lia"`, `"NAME preview"`).
final class PreviewNamesState: Sendable {
    private struct State {
        var names: [TaughtName] = []
        var seeded = false
        var counter = 0
        var calls: [String] = []
    }

    private let state = Mutex(State())

    func seedIfNeeded(now: Date) {
        state.withLock { s in
            guard !s.seeded else { return }
            s.seeded = true
            s.names = PreviewData.searchNames(now: now)
        }
    }

    var names: [TaughtName] { state.withLock { $0.names } }
    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    /// A word of `name` another name already has (48.1), or nil.
    private static func clash(_ name: TaughtName, among names: [TaughtName]) -> String? {
        let mine = [TaughtName.normalize(name.name)] + name.aliases
        for other in names where other.id != name.id {
            let theirs = Set([TaughtName.normalize(other.name)] + other.aliases)
            if let word = mine.first(where: { theirs.contains($0) }) { return word }
        }
        return nil
    }

    /// The draft's values as the server stores them, or `400 error.names.bad`.
    private static func clean(_ name: inout TaughtName) throws {
        name.name = name.name.trimmingCharacters(in: .whitespacesAndNewlines)
        name.meaning = name.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TaughtName.normalize(name.name)
        var aliases: [String] = []
        for alias in name.aliases.map(TaughtName.normalize) where !alias.isEmpty && alias != key && !aliases.contains(alias) {
            aliases.append(alias)
        }
        name.aliases = aliases
        let marks = Set(name.yes).intersection(name.no)
        guard (1...TaughtName.maxNameLength).contains(name.name.count),
              (1...TaughtName.maxMeaningLength).contains(name.meaning.count),
              aliases.count <= TaughtName.maxAliases, aliases.allSatisfy({ $0.count <= TaughtName.maxNameLength }),
              (0...1).contains(name.strength), (0...1).contains(name.cutoff), marks.isEmpty,
              name.yes.count + name.no.count <= TaughtName.maxMarks
        else { throw CobaltError.api(code: "error.names.bad", httpStatus: 400) }
    }

    func add(_ draft: SearchNameDraft, now: Date) throws -> TaughtName {
        try state.withLock { s in
            guard s.names.count < TaughtName.maxNames else { throw CobaltError.api(code: "error.names.too_many", httpStatus: 409) }
            s.counter += 1
            var name = TaughtName(
                id: "PrEvIeWname\(String(format: "%05d", 100 + s.counter))", name: draft.name, aliases: draft.aliases,
                meaning: draft.meaning, strength: draft.strength, cutoff: draft.cutoff, enabled: draft.enabled,
                yes: draft.yes, no: draft.no, embedded: true, createdAt: now, updatedAt: now)
            try Self.clean(&name)
            if let word = Self.clash(name, among: s.names) { throw SearchNameTaken(word: word) }
            s.names.append(name)
            return name
        }
    }

    func update(id: String, _ patch: SearchNamePatch, now: Date) throws -> TaughtName {
        try state.withLock { s in
            guard let i = s.names.firstIndex(where: { $0.id == id }) else {
                throw CobaltError.api(code: "error.names.not_found", httpStatus: 404)
            }
            var name = s.names[i]
            if let v = patch.name { name.name = v }
            if let v = patch.meaning { name.meaning = v }
            if let v = patch.aliases { name.aliases = v }
            if let v = patch.strength { name.strength = v }
            if let v = patch.cutoff { name.cutoff = v }
            if let v = patch.enabled { name.enabled = v }
            if let v = patch.yes { name.yes = v }
            if let v = patch.no { name.no = v }
            for change in patch.mark {
                name.yes.removeAll { $0 == change.postKey }
                name.no.removeAll { $0 == change.postKey }
                switch change.kind {
                case .yes?: name.yes.insert(change.postKey, at: 0)
                case .no?: name.no.insert(change.postKey, at: 0)
                case nil: break
                }
            }
            try Self.clean(&name)
            if let word = Self.clash(name, among: s.names) { throw SearchNameTaken(word: word) }
            name.updatedAt = now
            s.names[i] = name
            return name
        }
    }

    func remove(id: String) throws {
        try state.withLock { s in
            guard s.names.contains(where: { $0.id == id }) else { throw CobaltError.api(code: "error.names.not_found", httpStatus: 404) }
            s.names.removeAll { $0.id == id }
        }
    }
}

extension PreviewClient {
    /// The preview server has `features.names` (every one with search).
    private var hasNames: Bool { searchMode != .off }

    /// The posts names are scored against: the library as listed now (no hidden post carries a name, 48.2).
    private func namePosts() async throws -> [LibraryPost] {
        try await library(cursor: nil, limit: 50).posts.filter { !$0.hidden }
    }

    /// `name` with `posts`: how many posts carry it now.
    private func counted(_ name: TaughtName, in posts: [LibraryPost]) -> TaughtName {
        var n = name
        n.posts = posts.filter { PreviewData.carries($0, name, in: posts).carries }.count
        return n
    }

    private func namesReady() throws -> PreviewNamesState {
        guard hasNames else { throw CobaltError.api(code: "error.api.generic", httpStatus: 503) }
        searchState.names.seedIfNeeded(now: clock.now())
        return searchState.names
    }

    public func searchNames() async throws -> [TaughtName] {
        let state = try namesReady()
        try await clock.sleep(seconds: 0.15 * timeScale)
        let posts = try await namePosts()
        return state.names.map { counted($0, in: posts) }
    }

    public func createSearchName(_ draft: SearchNameDraft) async throws -> TaughtName {
        let state = try namesReady()
        state.record("NAME add \(draft.trimmedName)")
        try await clock.sleep(seconds: 0.25 * timeScale)
        let name = try state.add(draft, now: clock.now())
        let posts = try await namePosts()
        return counted(name, in: posts)
    }

    public func updateSearchName(id: String, _ patch: SearchNamePatch) async throws -> TaughtName {
        let state = try namesReady()
        state.record("NAME update \(id)")
        try await clock.sleep(seconds: 0.2 * timeScale)
        let name = try state.update(id: id, patch, now: clock.now())
        let posts = try await namePosts()
        return counted(name, in: posts)
    }

    public func deleteSearchName(id: String) async throws {
        let state = try namesReady()
        state.record("NAME delete \(id)")
        try await clock.sleep(seconds: 0.15 * timeScale)
        try state.remove(id: id)
    }

    /// `POST /library/names/preview`: the name with these values against the preview posts; examples first, then not, then
    /// the rest by score.
    public func previewSearchName(_ request: SearchNamePreviewRequest) async throws -> SearchNamePreview {
        let state = try namesReady()
        state.record("NAME preview")
        try await clock.sleep(seconds: 0.2 * timeScale)
        let saved = request.id.flatMap { id in state.names.first { $0.id == id } }
        if request.id != nil, saved == nil { throw CobaltError.api(code: "error.names.not_found", httpStatus: 404) }
        guard let meaning = request.meaning ?? saved?.meaning, !meaning.isEmpty else {
            throw CobaltError.api(code: "error.names.bad", httpStatus: 400)
        }
        let name = TaughtName(
            id: saved?.id ?? "preview", name: request.name ?? saved?.name ?? "", meaning: meaning,
            strength: request.strength ?? saved?.strength ?? TaughtName.defaultStrength,
            cutoff: request.cutoff ?? saved?.cutoff ?? TaughtName.defaultCutoff,
            yes: request.yes ?? saved?.yes ?? [], no: request.no ?? saved?.no ?? [])
        let posts = try await namePosts()
        let entries = posts.map { post -> SearchNamePreview.Entry in
            let (score, carries) = PreviewData.carries(post, name, in: posts)
            return SearchNamePreview.Entry(postKey: post.id, score: score, mark: name.mark(of: post.id), carries: carries, post: post)
        }
        func rank(_ e: SearchNamePreview.Entry) -> Int {
            switch e.mark {
            case .yes?: return 0
            case .no?: return 1
            case nil: return 2
            }
        }
        let ordered = entries.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.score > $1.score }
        return SearchNamePreview(
            embedded: true, carries: entries.filter(\.carries).count, indexed: posts.count,
            posts: Array(ordered.prefix(max(1, min(100, request.limit ?? 60)))))
    }

    /// `GET /library/names/post`: the enabled names the post carries or is marked for, best first.
    public func searchNames(forPost postKey: String) async throws -> [PostName] {
        let state = try namesReady()
        try await clock.sleep(seconds: 0.15 * timeScale)
        let posts = try await namePosts()
        guard let post = posts.first(where: { $0.id == postKey }) else { return [] }
        return state.names.filter(\.enabled).compactMap { name -> PostName? in
            let (score, carries) = PreviewData.carries(post, name, in: posts)
            let mark = name.mark(of: postKey)
            guard carries || mark != nil else { return nil }
            return PostName(id: name.id, name: name.name, score: score, mark: mark, carries: carries)
        }
        .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
    }

    /// 48.3 on the preview's search: the names the query says, and the posts that carry them lifted by the text bonus
    /// (`0.3 * w`, `w` the share of the query's words that are names' words; never past one bonus).
    func applyNames(_ query: String, to hits: [LibrarySearchResult.Hit], posts: [LibraryPost]) -> (hits: [LibrarySearchResult.Hit], said: [SearchNameRef]) {
        guard hasNames else { return (hits, []) }
        searchState.names.seedIfNeeded(now: clock.now())
        let said = PreviewData.namesSaid(in: query, names: searchState.names.names)
        guard !said.isEmpty else { return (hits, []) }
        let typed = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var namesWords = Set<String>()
        for name in said {
            for word in [name.name] + name.aliases {
                for piece in word.lowercased().split(whereSeparator: \.isWhitespace) { namesWords.insert(String(piece)) }
            }
        }
        let queryWords = typed.count
        let sayingWords = typed.filter { namesWords.contains($0) }.count
        let w = queryWords == 0 ? 0 : min(1, Double(sayingWords) / Double(queryWords))
        let lifted = hits.map { hit -> LibrarySearchResult.Hit in
            guard said.contains(where: { PreviewData.carries(hit.post, $0, in: posts).carries }) else { return hit }
            var h = hit
            h.score = ((h.score + 0.3 * w) * 1000).rounded() / 1000
            return h
        }
        return (lifted.sorted { $0.score > $1.score }, said.map { SearchNameRef(id: $0.id, name: $0.name) })
    }
}

extension AppModel {
    /// The library with search and three search names (Lia, capy, the ramen place), nothing on the network.
    public static func previewNames() -> AppModel {
        makePreviewSearch(.ready, timeScale: 1, clock: SystemClock())
    }
}
