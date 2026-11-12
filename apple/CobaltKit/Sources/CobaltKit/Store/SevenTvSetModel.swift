import Foundation
import Observation

/// One 7TV set on the set screen (APP-API-CONTRACT 57.7): its emotes 60 a page, a name filter (the server's `q`), and the
/// edits: add (from section 20's search), rename an emote's alias, copy it to another set of the same channel, remove it,
/// rename the set. Every edit changes the grid in place once 7TV took it, and the card's counts through `SevenTvStore`; a
/// refusal throws `SevenTvError` (with 7TV's message) and changes nothing.
@MainActor @Observable
public final class SevenTvSetModel {
    public enum State: Equatable, Sendable {
        case idle, loading, loaded
        case failed(SevenTvError)
    }

    public let setID: String
    public let channelID: String

    public private(set) var info: SevenTvSetInfo?
    public private(set) var state: State = .idle
    /// The filter as typed; `applyFilter()` reads it.
    public var filter = ""
    /// The emotes, unfiltered, in the order the server pages them (the set's own grid without a filter).
    public private(set) var all: [SevenTvSetItem] = []
    public private(set) var allHasMore = false
    /// The filter's answer (empty without a filter).
    public private(set) var matches: [SevenTvSetItem] = []
    public private(set) var matchesHaveMore = false
    public private(set) var loadingMore = false
    /// The emote ids (`SevenTvSetItem.emoteID`, or a search hit's id) with a write in flight.
    public private(set) var busy: Set<String> = []

    @ObservationIgnored private let store: SevenTvStore
    @ObservationIgnored private var allPage = 0
    @ObservationIgnored private var matchesPage = 0
    /// The filter `matches` answers (nil: none).
    private var appliedFilter: String?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var filterToken = 0

    init(setID: String, channelID: String, store: SevenTvStore) {
        self.setID = setID
        self.channelID = channelID
        self.store = store
        if let summary = store.sets(of: channelID).first(where: { $0.id == setID }) {
            info = SevenTvSetInfo(
                id: summary.id, name: summary.name, capacity: summary.capacity, count: summary.count, ownerID: channelID,
                live: summary.live)
        }
    }

    // MARK: reading

    /// What the grid shows: the filter's answer while there is a filter, else the whole set.
    public var emotes: [SevenTvSetItem] { appliedFilter == nil ? all : matches }
    public var hasMore: Bool { appliedFilter == nil ? allHasMore : matchesHaveMore }
    public var isFiltered: Bool { appliedFilter != nil }

    /// The channel this set belongs to (its rights).
    public var channel: SevenTvChannelInfo? { store.channel(channelID) }
    public var can: SevenTvRights { channel?.can ?? .none }

    /// The other sets of the same channel (for "copy to set…").
    public var otherSets: [SevenTvSetRow] { store.sets(of: channelID).filter { $0.id != setID } }

    /// The 7TV emote ids in the set as far as it is loaded (`loadEverything()` loads the rest).
    public var memberIDs: Set<String> { Set(all.map(\.emoteID)) }

    /// The whole set is loaded: `memberIDs` is complete.
    public var everythingLoaded: Bool { state == .loaded && !allHasMore }

    /// An emote already in the set under this alias (case as typed; 7TV compares exactly).
    public func emote(aliased alias: String) -> SevenTvSetItem? { all.first { $0.alias == alias } }

    /// The set's first page (and the filter's again, when there is one).
    public func load() async {
        token += 1
        let mine = token
        state = .loading
        do {
            let first = try await store.setClient().sevenTvSet(id: setID, query: nil, page: 1)
            guard mine == token else { return }
            info = first.set
            all = first.emotes
            allPage = first.page
            allHasMore = first.hasMore
            state = .loaded
            store.adopt(set: first.set, channelID: channelID)
        } catch {
            guard mine == token else { return }
            let refusal = SevenTvError.from(error)
            store.note(refusal)
            state = .failed(refusal)
            return
        }
        if appliedFilter != nil { await runFilter(force: true) }
    }

    /// Reads `filter` (trimmed, at most 100 characters) from page 1; an empty filter goes back to the whole set. The same
    /// filter again asks nothing.
    public func applyFilter() async {
        await runFilter(force: false)
    }

    private func runFilter(force: Bool) async {
        let q = SevenTvRule.cleanFilter(filter)
        guard force || q != appliedFilter else { return }
        filterToken += 1
        let mine = filterToken
        appliedFilter = q
        matches = []
        matchesHaveMore = false
        matchesPage = 0
        guard let q else { return }
        do {
            let page = try await store.setClient().sevenTvSet(id: setID, query: q, page: 1)
            guard mine == filterToken else { return }
            matches = page.emotes
            matchesPage = page.page
            matchesHaveMore = page.hasMore
        } catch {
            guard mine == filterToken else { return }
            store.note(SevenTvError.from(error))
        }
    }

    /// The next page of what the grid shows, when its last tile appears.
    public func loadMore() async {
        guard hasMore, !loadingMore, state == .loaded else { return }
        let q = appliedFilter
        let mine = q == nil ? token : filterToken
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = (q == nil ? allPage : matchesPage) + 1
            let page = try await store.setClient().sevenTvSet(id: setID, query: q, page: next)
            if q == nil {
                guard mine == token else { return }
                all = Self.appending(page.emotes, to: all)
                allPage = page.page
                allHasMore = page.hasMore
            } else {
                guard mine == filterToken else { return }
                matches = Self.appending(page.emotes, to: matches)
                matchesPage = page.page
                matchesHaveMore = page.hasMore
            }
        } catch {
            if q == nil, mine == token { allHasMore = false }
            if q != nil, mine == filterToken { matchesHaveMore = false }
        }
    }

    /// Pages the whole set in (at most 40 pages), so "add from 7tv" can mark every emote already in it.
    public func loadEverything() async {
        var pages = 0
        while state == .loaded, allHasMore, pages < 40, !Task.isCancelled {
            pages += 1
            let mine = token
            do {
                let page = try await store.setClient().sevenTvSet(id: setID, query: nil, page: allPage + 1)
                guard mine == token else { return }
                all = Self.appending(page.emotes, to: all)
                allPage = page.page
                allHasMore = page.hasMore
            } catch {
                return
            }
        }
    }

    private static func appending(_ more: [SevenTvSetItem], to list: [SevenTvSetItem]) -> [SevenTvSetItem] {
        let seen = Set(list.map(\.id))
        return list + more.filter { !seen.contains($0.id) }
    }

    // MARK: edits

    /// Adds a 7TV emote under `alias` (nil: its own name). `overrideConflicts` swaps out an emote that already has the name.
    public func add(_ hit: EmoteHit, alias: String?, overrideConflicts: Bool) async throws {
        let name = alias ?? hit.name
        try await write(hit.id) {
            let change = try await self.store.setClient().addSevenTvEmote(
                setID: self.setID, emoteID: hit.id, alias: alias, overrideConflicts: overrideConflicts)
            let added = SevenTvSetItem(
                emoteID: hit.id, alias: change.alias ?? name, name: hit.name, animated: hit.animated,
                previewURL: hit.previewURL, fileURL: hit.fileURL, addedAt: self.store.now())
            var removed = 0
            if overrideConflicts, let clash = self.emote(aliased: added.alias) {
                removed = 1
                self.drop(clash)
            }
            self.all.insert(added, at: 0)
            if let q = self.appliedFilter, added.alias.localizedCaseInsensitiveContains(q) { self.matches.insert(added, at: 0) }
            self.changeCount(by: 1 - removed)
        }
    }

    /// Renames the emote in this set (its alias). The name must pass `SevenTvRule.cleanAlias`.
    public func rename(_ emote: SevenTvSetItem, to raw: String) async throws {
        guard let alias = SevenTvRule.cleanAlias(raw) else { throw SevenTvError.rejected(nil) }
        guard alias != emote.alias else { return }
        try await write(emote.emoteID) {
            let change = try await self.store.setClient().renameSevenTvEmote(
                setID: self.setID, emoteID: emote.emoteID, alias: alias, from: emote.alias)
            let next = change.alias ?? alias
            self.all = self.all.map { $0.id == emote.id ? Self.renamed($0, to: next) : $0 }
            self.matches = self.matches.map { $0.id == emote.id ? Self.renamed($0, to: next) : $0 }
        }
    }

    private static func renamed(_ emote: SevenTvSetItem, to alias: String) -> SevenTvSetItem {
        var e = emote
        e.alias = alias
        e.renamed = alias != e.name
        return e
    }

    /// Removes the emote (this alias of it) from the set.
    public func remove(_ emote: SevenTvSetItem) async throws {
        try await write(emote.emoteID) {
            _ = try await self.store.setClient().removeSevenTvEmote(setID: self.setID, emoteID: emote.emoteID, alias: emote.alias)
            self.drop(emote)
            self.changeCount(by: -1)
        }
    }

    /// Copies the emote, under the alias it has here, into another set of the same channel.
    public func copy(_ emote: SevenTvSetItem, to otherSetID: String) async throws {
        try await write(emote.emoteID) {
            _ = try await self.store.setClient().addSevenTvEmote(
                setID: otherSetID, emoteID: emote.emoteID, alias: emote.renamed ? emote.alias : nil, overrideConflicts: false)
            self.store.bump(setID: otherSetID, channelID: self.channelID, by: 1)
        }
    }

    /// Renames the set. The name must pass `SevenTvRule.cleanSetName`.
    public func renameSet(_ raw: String) async throws {
        guard let name = SevenTvRule.cleanSetName(raw) else { throw SevenTvError.rejected(nil) }
        try await write("set") {
            let answer = try await self.store.setClient().renameSevenTvSet(id: self.setID, name: name)
            var next = answer
            if let current = self.info {
                // the rename answer may leave out what it did not touch
                if next.capacity == nil { next.capacity = current.capacity }
                if next.count == 0 { next.count = current.count }
                next.live = next.live || current.live
            }
            self.info = next
            self.store.adopt(set: next, channelID: self.channelID)
        }
    }

    /// Makes this set the channel's live set.
    public func makeLive() async throws {
        try await write("live") {
            try await self.store.makeLive(channelID: self.channelID, setID: self.setID)
            self.info?.live = true
        }
    }

    // MARK: helpers

    private func drop(_ emote: SevenTvSetItem) {
        all.removeAll { $0.id == emote.id }
        matches.removeAll { $0.id == emote.id }
    }

    private func changeCount(by delta: Int) {
        guard delta != 0 else { return }
        if var current = info {
            current.count = max(0, current.count + delta)
            info = current
            store.adopt(set: current, channelID: channelID)
        }
    }

    /// One write at a time per key; a refusal that says the link is gone goes to the card, then is thrown on.
    private func write(_ key: String, _ work: @MainActor () async throws -> Void) async throws {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await work()
        } catch {
            store.note(SevenTvError.from(error))
            throw error
        }
    }
}
