import Foundation
import Observation

/// Search names (APP-API-CONTRACT 48.4, 48.6): the names list (library › names), the switches, the open name editor, and
/// the marks the detail and a post's menu make. `AppModel.searchNames`. Idle until `load()`; a server or key change empties it.
@MainActor @Observable
public final class SearchNamesModel {
    /// Oldest first, as the server lists them.
    public internal(set) var names: [TaughtName] = []
    public internal(set) var isLoading: Bool = false
    /// The list has been read once (an empty list then means "no names yet").
    public internal(set) var hasLoaded: Bool = false
    /// Why the last load or change failed; nil after one that worked.
    public internal(set) var failure: PipelineFailure?
    /// The names screen is open (the library presents it as a sheet).
    public var showingList: Bool = false
    /// The open name (pushed over the list); nil when none.
    public internal(set) var editor: SearchNameEditor?
    /// Bumped whenever a name or a mark changed: the detail's names row reads its post again.
    public internal(set) var revision: Int = 0

    @ObservationIgnored let ctx: PipelineContext
    /// Where the editor's strips find a post the preview did not list.
    @ObservationIgnored let library: LibraryModel

    init(context: PipelineContext, library: LibraryModel) {
        self.ctx = context
        self.library = library
    }

    func reset() {
        editor?.cancel()
        names = []; isLoading = false; hasLoaded = false; failure = nil; showingList = false; editor = nil; revision += 1
    }

    /// `GET /library/names`.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            names = try await ctx.client.searchNames()
            hasLoaded = true
            failure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    /// A name by id.
    public func name(id: String) -> TaughtName? {
        names.first { $0.id == id }
    }

    /// The switch: optimistic, put back when the server refuses.
    public func setEnabled(_ name: TaughtName, _ on: Bool) async {
        guard let index = names.firstIndex(where: { $0.id == name.id }), names[index].enabled != on else { return }
        let before = names[index]
        names[index].enabled = on
        do {
            let saved = try await ctx.client.updateSearchName(id: name.id, SearchNamePatch(enabled: on))
            replace(saved)
            failure = nil
        } catch {
            if let at = names.firstIndex(where: { $0.id == name.id }) { names[at] = before }
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    /// Swipe or right click to delete: optimistic, put back where it was when the server refuses.
    public func delete(_ name: TaughtName) async {
        guard let index = names.firstIndex(where: { $0.id == name.id }) else { return }
        let removed = names.remove(at: index)
        if editor?.saved?.id == name.id { closeEditor() }
        do {
            try await ctx.client.deleteSearchName(id: name.id)
            failure = nil
            revision += 1
        } catch {
            // an id the server no longer has is gone, which is what was asked
            if case .api(_, 404)? = error as? CobaltError { revision += 1; return }
            names.insert(removed, at: min(index, names.endIndex))
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    // MARK: marks (the detail's names row, a post's "this is…")

    /// Marks one post on a saved name (`kind` nil takes the mark off). The saved name comes back; nil when the server
    /// refused (the failure is kept).
    @discardableResult
    public func mark(_ postKey: String, _ kind: NameMark?, on nameID: String) async -> TaughtName? {
        do {
            let saved = try await ctx.client.updateSearchName(
                id: nameID, SearchNamePatch(mark: [NameMarkChange(postKey: postKey, kind: kind)]))
            replace(saved)
            failure = nil
            if let editor, editor.saved?.id == saved.id { editor.marked(postKey, kind, saved: saved) }
            return saved
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
            return nil
        }
    }

    /// `GET /library/names/post`: the names the post carries or is marked for, best first.
    public func names(forPost postKey: String) async throws -> [PostName] {
        try await ctx.client.searchNames(forPost: postKey)
    }

    // MARK: the editor

    /// Opens a saved name (the sheet too, when it is closed).
    public func open(_ name: TaughtName) {
        editor?.cancel()
        editor = SearchNameEditor(owner: self, saved: name)
        showingList = true
    }

    /// Opens a saved name by id; false when the list does not hold it (it is read first when it was never read).
    @discardableResult
    public func open(id: String) async -> Bool {
        if name(id: id) == nil { await load() }
        guard let found = name(id: id) else { return false }
        open(found)
        return true
    }

    /// A new name; with `example`, the post is its first example ("new name…" in a post's menu).
    public func startNew(example postKey: String? = nil) {
        editor?.cancel()
        var draft = SearchNameDraft()
        if let postKey { draft.yes = [postKey] }
        editor = SearchNameEditor(owner: self, draft: draft)
        showingList = true
    }

    /// Back to the list (or the sheet closed): the editor's pending preview stops.
    public func closeEditor() {
        editor?.cancel()
        editor = nil
    }

    /// The sheet closed: nothing is pushed next time it opens.
    public func closeAll() {
        closeEditor()
        showingList = false
    }

    // MARK: inside

    func replace(_ saved: TaughtName) {
        if let at = names.firstIndex(where: { $0.id == saved.id }) { names[at] = saved } else { names.append(saved) }
        revision += 1
    }
}

/// Why a name could not be saved (48.4's refusals, as the editor words them).
public enum SearchNameSaveProblem: Sendable, Equatable {
    /// `409 error.names.taken`: another name has this word.
    case taken(word: String?)
    /// `400 error.names.bad` (or the draft is not valid yet).
    case invalid
    /// `409 error.names.too_many`: 100 names already.
    case tooMany
    /// `404 error.names.not_found`: the name was deleted elsewhere.
    case notFound
    /// Anything else (offline, the server's own error).
    case failed(PipelineFailure?)
}

/// What "try a search" found: the same query with the names (`names` the server used) and without them (`names=0`).
public struct SearchNameComparison: Sendable, Equatable {
    public var query: String
    public var with: [LibraryPost]
    public var without: [LibraryPost]
    /// The names the query said and the server used.
    public var used: [SearchNameRef]

    public init(query: String, with: [LibraryPost], without: [LibraryPost], used: [SearchNameRef]) {
        self.query = query
        self.with = with
        self.without = without
        self.used = used
    }
}

/// One name being edited (48.6): the draft, its live preview (re-run 300 ms after a slider or a mark changes; a little
/// longer after the words), save, and "try a search". Made by `SearchNamesModel.open` / `startNew`.
@MainActor @Observable
public final class SearchNameEditor {
    /// The name as the server last saved it; nil for a new one.
    public internal(set) var saved: TaughtName?
    /// What the screen edits. After a change call `draftChanged()` (the screen does, from `onChange`).
    public var draft: SearchNameDraft
    /// The newest preview; kept while the next one is out, so the list does not blink.
    public internal(set) var preview: SearchNamePreview?
    public internal(set) var isPreviewing: Bool = false
    /// The last preview failed (offline, the server refused); the old one stays on screen.
    public internal(set) var previewFailed: Bool = false
    public internal(set) var isSaving: Bool = false
    public internal(set) var saveProblem: SearchNameSaveProblem?
    /// Bumped by every save that worked (the success haptic).
    public internal(set) var savedTick: Int = 0
    /// "try a search".
    public internal(set) var comparison: SearchNameComparison?
    public internal(set) var isComparing: Bool = false
    public internal(set) var compareFailed: Bool = false

    /// The pause before a preview after a slider or a mark changed (48.6).
    public static let previewDebounce: Double = 0.3
    /// After the name or the meaning changed (typing): a word at a time, not a letter.
    public static let wordsDebounce: Double = 0.8
    /// Posts a preview asks for.
    public static let previewLimit = 60

    @ObservationIgnored private weak var owner: SearchNamesModel?
    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var compareTask: Task<Void, Never>?
    /// The request the shown preview (or the one in flight) answers.
    @ObservationIgnored private var asked: SearchNamePreviewRequest?
    @ObservationIgnored private var generation = 0

    init(owner: SearchNamesModel, saved: TaughtName) {
        self.owner = owner
        self.ctx = owner.ctx
        self.saved = saved
        self.draft = SearchNameDraft(saved)
    }

    init(owner: SearchNamesModel, draft: SearchNameDraft) {
        self.owner = owner
        self.ctx = owner.ctx
        self.saved = nil
        self.draft = draft
    }

    /// A new name (not saved yet).
    public var isNew: Bool { saved == nil }
    /// The draft differs from what the server holds (a new name always does).
    public var isDirty: Bool { saved.map { SearchNameDraft($0) != draft } ?? true }
    public var canSave: Bool { draft.isValid && isDirty && !isSaving }

    /// The preview's posts that carry the name (above the cut-off line), and the rest.
    public var carrying: [SearchNamePreview.Entry] { (preview?.posts ?? []).filter { $0.carries } }
    public var notCarrying: [SearchNamePreview.Entry] { (preview?.posts ?? []).filter { !$0.carries } }

    /// The example and not posts as the preview knows them (for the strips' thumbnails), newest mark first.
    public func posts(marked mark: NameMark) -> [(key: String, post: LibraryPost?)] {
        let keys = mark == .yes ? draft.yes : draft.no
        let known = Dictionary((preview?.posts ?? []).map { ($0.postKey, $0.post) }, uniquingKeysWith: { first, _ in first })
        return keys.map { key in (key, (known[key] ?? nil) ?? owner?.library.post(id: key)) }
    }

    // MARK: preview

    /// The first preview (the screen appeared), at once.
    public func start() {
        guard preview == nil, previewTask == nil else { return }
        schedule(after: 0)
    }

    /// The draft changed: a new preview after the pause, when what it depends on changed.
    public func draftChanged() {
        saveProblem = nil
        let next = request()
        guard next != asked else { return }
        let wordsMoved = next.meaning != asked?.meaning || next.name != asked?.name
        schedule(after: wordsMoved ? Self.wordsDebounce : Self.previewDebounce)
    }

    /// A tap in "who's in": example → not → no mark, and the preview follows.
    public func cycle(_ postKey: String) {
        draft.cycle(postKey)
        draftChanged()
    }

    /// The preview again now (a retry).
    public func refreshPreview() {
        asked = nil
        schedule(after: 0)
    }

    /// Stops the pending preview and search (the screen went).
    public func cancel() {
        previewTask?.cancel()
        previewTask = nil
        compareTask?.cancel()
        compareTask = nil
    }

    private func request() -> SearchNamePreviewRequest {
        SearchNamePreviewRequest(id: saved?.id, draft: draft, limit: Self.previewLimit)
    }

    private func schedule(after seconds: Double) {
        previewTask?.cancel()
        let req = request()
        // without a saved name the server needs the meaning: nothing to show yet
        guard req.id != nil || req.meaning != nil else {
            asked = req
            preview = nil
            isPreviewing = false
            previewTask = nil
            return
        }
        asked = req
        generation += 1
        let gen = generation
        let clock = ctx.clock
        isPreviewing = true
        previewTask = Task { [weak self] in
            if seconds > 0 {
                do { try await clock.sleep(seconds: seconds) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.runPreview(req, generation: gen)
        }
    }

    private func runPreview(_ req: SearchNamePreviewRequest, generation gen: Int) async {
        do {
            var answer = try await ctx.client.previewSearchName(req)
            guard gen == generation, !Task.isCancelled else { return }
            // hidden posts never carry a name in any answer (48.2); the second lock
            answer.posts.removeAll { $0.post?.hidden == true }
            preview = answer
            previewFailed = false
        } catch {
            guard gen == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            previewFailed = true
        }
        if gen == generation {
            isPreviewing = false
            previewTask = nil
        }
    }

    // MARK: save

    /// Creates or updates the name with the draft. True when it saved.
    @discardableResult
    public func save() async -> Bool {
        guard !isSaving else { return false }
        guard draft.isValid else {
            saveProblem = .invalid
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let result: TaughtName
            if let saved {
                result = try await ctx.client.updateSearchName(id: saved.id, SearchNamePatch(draft))
            } else {
                result = try await ctx.client.createSearchName(draft)
            }
            saved = result
            // the server normalizes the words: what it holds is what the screen shows
            draft = SearchNameDraft(result)
            saveProblem = nil
            savedTick += 1
            owner?.replace(result)
            asked = nil
            schedule(after: 0)
            return true
        } catch let taken as SearchNameTaken {
            saveProblem = .taken(word: taken.word)
        } catch {
            switch LibraryModel.searchErrorCode(error) {
            case "error.names.bad": saveProblem = .invalid
            case "error.names.too_many": saveProblem = .tooMany
            case "error.names.not_found": saveProblem = .notFound
            default: saveProblem = .failed(pipelineFailure(from: error, during: .saving))
            }
        }
        return false
    }

    /// A mark made outside the editor (the detail, a post's menu) on this name: the draft follows when it had no edits.
    func marked(_ postKey: String, _ kind: NameMark?, saved result: TaughtName) {
        let clean = !isDirty
        saved = result
        if clean { draft = SearchNameDraft(result) } else { draft.set(kind, for: postKey) }
        draftChanged()
    }

    // MARK: try a search

    /// Runs `query` with the saved names and without them (`names=0`), side by side.
    public func compare(_ query: String) {
        compareTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LibraryModel.isServerQuery(q) else {
            comparison = nil
            isComparing = false
            return
        }
        isComparing = true
        compareFailed = false
        compareTask = Task { [weak self] in
            await self?.runCompare(q)
        }
    }

    private func runCompare(_ q: String) async {
        let limit = 12
        let client = ctx.client
        let version = ctx.searchVersion
        do {
            async let with = client.librarySearch(query: q, limit: limit, version: version, names: true)
            async let without = client.librarySearch(query: q, limit: limit, version: version, names: false)
            let a = try await with
            let b = try await without
            guard !Task.isCancelled else { return }
            comparison = SearchNameComparison(
                query: q, with: a.posts.filter { !$0.hidden }, without: b.posts.filter { !$0.hidden }, used: a.names)
            compareFailed = false
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            compareFailed = true
        }
        isComparing = false
    }
}
