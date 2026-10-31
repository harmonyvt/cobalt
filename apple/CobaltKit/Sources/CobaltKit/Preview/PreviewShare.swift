import Foundation
import Synchronization

// Gallery share links in previews (APP-API-CONTRACT 24): a server with `features.share_sets` and a `share_base_url`,
// three sample links, and the real rule (2..4 distinct files, all public now). `PreviewScenario.shareLinksEmpty` has no
// links yet; `.shareLinksFail` cannot list them. `.happy` and `.renditions` have the three samples. The same server
// answers `/share/collections` (APP-API-CONTRACT 26): two sample collections over the three links, the real name rule,
// the 100/200 caps, and a revoked link dropping out of every collection. And `/share/groups` (APP-API-CONTRACT 28): two
// sample groups ("sets") over the two collections, the same name rule, the 100/100 caps, and a deleted collection
// dropping out of every group.

extension PreviewScenario {
    /// The preview server has `features.share_sets`.
    var hasShareLinks: Bool {
        switch self {
        case .happy, .renditions, .shareLinksEmpty, .shareLinksFail, .stageNotConnected, .stageFail, .hidden: return true
        default: return false
        }
    }
}

extension PreviewData {
    /// `share_base_url` of the preview server.
    static let shareBase = URL(string: "https://share.capybaraharmony.com/")!

    static func shareURL(id: String) -> URL { shareBase.appendingPathComponent("g").appendingPathComponent(id) }

    /// The two sample collections, most recently changed first (`now` is when the preview server started):
    /// - `PrEvIeWcoll00001` "memes" (1 hour ago): the two newest links.
    /// - `PrEvIeWcoll00002` "for discord" (5 hours ago): the kitchen link.
    static func shareCollections(now: Date) -> [ShareCollection] {
        [
            ShareCollection(
                id: "PrEvIeWcoll00001", name: "memes", createdAt: now.addingTimeInterval(-3 * 86_400),
                updatedAt: now.addingTimeInterval(-3_600), setIDs: ["9000000000000000002", "9000000000000000001"]),
            ShareCollection(
                id: "PrEvIeWcoll00002", name: "for discord", createdAt: now.addingTimeInterval(-2 * 86_400),
                updatedAt: now.addingTimeInterval(-5 * 3_600), setIDs: ["9000000000000000003"]),
        ]
    }

    /// The two sample collection groups ("sets"), most recently changed first (`now` is when the preview server started):
    /// - `PrEvIeWgrup00001` "weekend" (30 minutes ago): both collections, "memes" first.
    /// - `PrEvIeWgrup00002` "work" (1 day ago): "for discord".
    static func collectionGroups(now: Date) -> [CollectionGroup] {
        [
            CollectionGroup(
                id: "PrEvIeWgrup00001", name: "weekend", createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-30 * 60), collectionIDs: ["PrEvIeWcoll00001", "PrEvIeWcoll00002"]),
            CollectionGroup(
                id: "PrEvIeWgrup00002", name: "work", createdAt: now.addingTimeInterval(-2 * 86_400),
                updatedAt: now.addingTimeInterval(-86_400), collectionIDs: ["PrEvIeWcoll00002"]),
        ]
    }

    /// The three sample links, newest first (`now` is when the preview server started):
    /// - `9000000000000000001` "harbour and the dog" (20 minutes ago): a video with its poster, a webp, a photo.
    /// - `9000000000000000002` (3 hours ago, untitled): two webps.
    /// - `9000000000000000003` "kitchen, coffee, city" (2 days ago): four files, and the video went private since (its
    ///   `url` is null), so the page shows three.
    static func shareSets(now: Date) -> [ShareSet] {
        func item(
            _ id: String, _ file: String?, _ type: String, poster: String? = nil, w: Int?, h: Int?, d: Double? = nil
        ) -> ShareSetItem {
            ShareSetItem(
                id: id, url: file.flatMap { URL(string: "https://media.capybaraharmony.com/\($0)") }, contentType: type,
                posterURL: poster.flatMap { URL(string: "https://media.capybaraharmony.com/\($0)") }, width: w, height: h, duration: d)
        }
        let video = item("PrEvIeWitem000001", "PrEvIeW011.mp4", "video/mp4", poster: "PrEvIeWp11.jpg", w: 720, h: 1280, d: 37.43)
        let dogWebp = item("PrEvIeWitem000003", "PrEvIeW001.webp", "image/webp", w: 480, h: 854, d: 10.1)
        let photo = item("PrEvIeWitem000030", "PrEvIeW021.jpg", "image/jpeg", w: 1080, h: 1350)
        let timerWebp = item("PrEvIeWitem000005", "PrEvIeW002.webp", "image/webp", w: 480, h: 568, d: 5.4)
        let cityWebp = item("PrEvIeWitem000010", "PrEvIeW004.webp", "image/webp", w: 480, h: 270, d: 5.0)
        let coffeeWebp = item("PrEvIeWitem000008", "PrEvIeW003.webp", "image/webp", w: 480, h: 480, d: 10.1)
        let wentPrivate = item("PrEvIeWitem000002", nil, "video/mp4", w: 720, h: 1280, d: 37.43)
        let photo2 = item("PrEvIeWitem000031", "PrEvIeW022.jpg", "image/jpeg", w: 1080, h: 1080)
        return [
            ShareSet(
                id: "9000000000000000001", url: shareURL(id: "9000000000000000001"), title: "harbour and the dog",
                createdAt: now.addingTimeInterval(-20 * 60), items: [video, dogWebp, photo]),
            ShareSet(
                id: "9000000000000000002", url: shareURL(id: "9000000000000000002"), title: nil,
                createdAt: now.addingTimeInterval(-3 * 3_600), items: [timerWebp, cityWebp]),
            ShareSet(
                id: "9000000000000000003", url: shareURL(id: "9000000000000000003"), title: "kitchen, coffee, city",
                createdAt: now.addingTimeInterval(-2 * 86_400), items: [coffeeWebp, cityWebp, wentPrivate, photo2]),
        ]
    }
}

/// What the preview "server" holds for `/share/sets`, and every call made (`"POST a,b"`, `"GET"`, `"DELETE <id>"`).
final class PreviewShareState: Sendable {
    private struct State {
        var sets: [ShareSet] = []
        var collections: [ShareCollection] = []
        var groups: [CollectionGroup] = []
        var counter = 0
        var collectionCounter = 0
        var groupCounter = 0
        var calls: [String] = []
        var listFails = false
    }

    private let state = Mutex(State())

    var sets: [ShareSet] { state.withLock { $0.sets } }
    var calls: [String] { state.withLock { $0.calls } }

    var collections: [ShareCollection] { state.withLock { $0.collections } }

    var groups: [CollectionGroup] { state.withLock { $0.groups } }

    func seed(_ sets: [ShareSet], collections: [ShareCollection] = [], groups: [CollectionGroup] = [], listFails: Bool) {
        state.withLock { $0.sets = sets; $0.collections = collections; $0.groups = groups; $0.listFails = listFails }
    }

    /// Tests: `GET /share/sets` answers 503 while this is true.
    var listFails: Bool {
        get { state.withLock { $0.listFails } }
        set { state.withLock { $0.listFails = newValue } }
    }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func list() -> [ShareSet]? {
        state.withLock { $0.listFails ? nil : $0.sets.sorted { $0.createdAt > $1.createdAt } }
    }

    func add(items: [ShareSetItem], title: String?, at now: Date) -> ShareSet {
        state.withLock { s in
            s.counter += 1
            let id = "9100000000000000" + String(format: "%03d", s.counter)
            let made = ShareSet(id: id, url: PreviewData.shareURL(id: id), title: title, createdAt: now, items: items)
            s.sets.insert(made, at: 0)
            return made
        }
    }

    /// The link with this id, if it is live.
    func set(_ id: String) -> ShareSet? { state.withLock { s in s.sets.first { $0.id == id } } }

    /// `PATCH`: the link with these items and this title, in its place. Nil when it is not live.
    func replace(_ id: String, items: [ShareSetItem], title: String?) -> ShareSet? {
        state.withLock { s in
            guard let index = s.sets.firstIndex(where: { $0.id == id }) else { return nil }
            s.sets[index].items = items
            s.sets[index].title = title
            return s.sets[index]
        }
    }

    /// Tests: another device changes the link's files behind the client's back.
    func changeBehind(_ id: String, items: [ShareSetItem]) {
        state.withLock { s in
            guard let index = s.sets.firstIndex(where: { $0.id == id }) else { return }
            s.sets[index].items = items
        }
    }

    /// Revokes a link: it goes from the list and from every collection.
    func remove(_ id: String) -> Bool {
        state.withLock { s in
            guard s.sets.contains(where: { $0.id == id }) else { return false }
            s.sets.removeAll { $0.id == id }
            for i in s.collections.indices { s.collections[i].setIDs.removeAll { $0 == id } }
            return true
        }
    }

    // MARK: collections

    func listCollections() -> [ShareCollection]? {
        state.withLock { $0.listFails ? nil : $0.collections.sorted { $0.updatedAt > $1.updatedAt } }
    }

    /// `POST`: `tooMany` at 100, `linkNotFound` for ids that are not live links (nothing changes), else the new one.
    func addCollection(name: String, setIDs: [String], at now: Date) throws -> ShareCollection {
        try state.withLock { s in
            let unknown = setIDs.filter { id in !s.sets.contains { $0.id == id } }
            guard unknown.isEmpty else { throw ShareCollectionError.linkNotFound(unknown) }
            guard s.collections.count < ShareCollectionRule.collectionLimit else { throw ShareCollectionError.tooMany }
            var seen = Set<String>()
            let ids = setIDs.filter { seen.insert($0).inserted }
            guard ids.count <= ShareCollectionRule.linkLimit else { throw ShareCollectionError.badRequest }
            s.collectionCounter += 1
            let id = "PrEvIeWnewc" + String(format: "%05d", s.collectionCounter)
            let made = ShareCollection(id: id, name: name, createdAt: now, updatedAt: now, setIDs: ids)
            s.collections.insert(made, at: 0)
            return made
        }
    }

    /// `PATCH`: rename, add (most recently added first; one already there stays where it is), remove. `notFound` for an
    /// unknown collection, `linkNotFound` for ids that are not live links, `full` past 200 links.
    func change(_ id: String, name: String?, add: [String], remove: [String], at now: Date) throws -> ShareCollection {
        try state.withLock { s in
            guard let index = s.collections.firstIndex(where: { $0.id == id }) else { throw ShareCollectionError.notFound }
            let unknown = add.filter { id in !s.sets.contains { $0.id == id } }
            guard unknown.isEmpty else { throw ShareCollectionError.linkNotFound(unknown) }
            var collection = s.collections[index]
            if let name { collection.name = name }
            collection.setIDs.removeAll { remove.contains($0) }
            var fresh: [String] = []
            for id in add where !collection.setIDs.contains(id) && !fresh.contains(id) { fresh.append(id) }
            guard collection.setIDs.count + fresh.count <= ShareCollectionRule.linkLimit else { throw ShareCollectionError.full }
            collection.setIDs = fresh.reversed() + collection.setIDs
            collection.updatedAt = now
            s.collections[index] = collection
            return collection
        }
    }

    /// `POST .../reroll`: each live link of the collection becomes a new link (same items, no title, new 19-digit id), the
    /// old ones are revoked, and every collection holding an old one holds the new one in place. `notFound`, or `empty`
    /// when the collection has no live link.
    func reroll(_ id: String, at now: Date) throws -> ShareCollectionReroll {
        try state.withLock { s in
            guard let index = s.collections.firstIndex(where: { $0.id == id }) else { throw ShareCollectionError.notFound }
            let live = s.collections[index].setIDs.compactMap { sid in s.sets.first { $0.id == sid } }
            guard !live.isEmpty else { throw ShareCollectionError.empty }
            var replaced: [String: String] = [:]
            var fresh: [ShareSet] = []
            for (i, old) in live.enumerated() {
                s.counter += 1
                let newID = "9100000000000000" + String(format: "%03d", s.counter)
                replaced[old.id] = newID
                // the collection's order is newest first, so the first one gets the latest time
                fresh.append(ShareSet(
                    id: newID, url: PreviewData.shareURL(id: newID), title: nil,
                    createdAt: now.addingTimeInterval(-Double(i) * 0.001), items: old.items))
            }
            s.sets.removeAll { replaced[$0.id] != nil }
            s.sets.insert(contentsOf: fresh, at: 0)
            for i in s.collections.indices {
                s.collections[i].setIDs = s.collections[i].setIDs.map { replaced[$0] ?? $0 }
            }
            s.collections[index].updatedAt = now
            return ShareCollectionReroll(collection: s.collections[index], replaced: replaced)
        }
    }

    /// Deletes a collection: it goes from the list and from every group.
    func removeCollection(_ id: String) -> Bool {
        state.withLock { s in
            guard s.collections.contains(where: { $0.id == id }) else { return false }
            s.collections.removeAll { $0.id == id }
            for i in s.groups.indices { s.groups[i].collectionIDs.removeAll { $0 == id } }
            return true
        }
    }

    // MARK: collection groups

    func listGroups() -> [CollectionGroup]? {
        state.withLock { $0.listFails ? nil : $0.groups.sorted { $0.updatedAt > $1.updatedAt } }
    }

    /// `POST`: `tooMany` at 100, `collectionNotFound` for ids that are not collections (nothing changes), else the new one.
    func addGroup(name: String, collectionIDs: [String], at now: Date) throws -> CollectionGroup {
        try state.withLock { s in
            let unknown = collectionIDs.filter { id in !s.collections.contains { $0.id == id } }
            guard unknown.isEmpty else { throw CollectionGroupError.collectionNotFound(unknown) }
            guard s.groups.count < CollectionGroupRule.groupLimit else { throw CollectionGroupError.tooMany }
            var seen = Set<String>()
            let ids = collectionIDs.filter { seen.insert($0).inserted }
            guard ids.count <= CollectionGroupRule.collectionLimit else { throw CollectionGroupError.badRequest }
            s.groupCounter += 1
            let id = "PrEvIeWnewg" + String(format: "%05d", s.groupCounter)
            let made = CollectionGroup(id: id, name: name, createdAt: now, updatedAt: now, collectionIDs: ids)
            s.groups.insert(made, at: 0)
            return made
        }
    }

    /// `PATCH`: rename, add (most recently added first; one already there stays where it is), remove. `notFound` for an
    /// unknown group, `collectionNotFound` for ids that are not collections, `full` past 100 collections.
    func changeGroup(_ id: String, name: String?, add: [String], remove: [String], at now: Date) throws -> CollectionGroup {
        try state.withLock { s in
            guard let index = s.groups.firstIndex(where: { $0.id == id }) else { throw CollectionGroupError.notFound }
            let unknown = add.filter { id in !s.collections.contains { $0.id == id } }
            guard unknown.isEmpty else { throw CollectionGroupError.collectionNotFound(unknown) }
            var group = s.groups[index]
            if let name { group.name = name }
            group.collectionIDs.removeAll { remove.contains($0) }
            var fresh: [String] = []
            for id in add where !group.collectionIDs.contains(id) && !fresh.contains(id) { fresh.append(id) }
            guard group.collectionIDs.count + fresh.count <= CollectionGroupRule.collectionLimit else { throw CollectionGroupError.full }
            group.collectionIDs = fresh.reversed() + group.collectionIDs
            group.updatedAt = now
            s.groups[index] = group
            return group
        }
    }

    func removeGroup(_ id: String) -> Bool {
        state.withLock { s in
            guard s.groups.contains(where: { $0.id == id }) else { return false }
            s.groups.removeAll { $0.id == id }
            return true
        }
    }
}

extension PreviewClient {
    /// `POST /share/sets` against the preview library (what it lists now, switches and deletes included): `badRequest`
    /// unless 2..4 distinct ids and a title of 1..80 characters (or none), `notPublic(ids)` for the files that are
    /// missing or private, else the new link, first in the list.
    public func createShareSet(items: [String], title: String?) async throws -> ShareSet {
        try await createShareSet(items: items, title: title, private: nil)
    }

    /// The same with `private` (APP-API-CONTRACT 36.3): nil follows `new_links`. Private takes any listed file, public
    /// or not (`notPublic` then names only the missing ones), and the link is private from the start.
    public func createShareSet(items: [String], title: String?, private isPrivate: Bool?) async throws -> ShareSet {
        shareState.record("POST " + items.joined(separator: ","))
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, cleaned.isEmpty || cleaned.count > ShareSetRule.titleLimit { throw ShareSetError.badRequest }
        guard items.count >= ShareSetRule.minimum, items.count <= PreviewData.capabilities(for: scenario).limits.shareSetMax,
              Set(items).count == items.count else { throw ShareSetError.badRequest }
        let makesPrivate = scenario.hasShareLinks && (isPrivate ?? (privateState.newLinks == .private))
        let posts = try await library(cursor: nil, limit: 100, v2: visibility != .off).posts
        var wire: [ShareSetItem] = []
        var refused: [String] = []
        for id in items {
            guard let post = posts.first(where: { $0.files.contains { $0.id == id } }),
                  let file = post.files.first(where: { $0.id == id }), makesPrivate || (file.isPublic && file.url != nil) else {
                refused.append(id)
                continue
            }
            let isVideo = file.contentType?.lowercased().hasPrefix("video/") == true
            wire.append(ShareSetItem(
                id: id, url: file.url, contentType: file.contentType, posterURL: file.posterURL ?? (isVideo ? post.posterURL : nil),
                width: file.width, height: file.height, duration: file.duration))
        }
        if !refused.isEmpty { throw ShareSetError.notPublic(refused) }
        let made = shareState.add(items: wire, title: cleaned, at: clock.now())
        if makesPrivate { _ = privateState.enable(.set, made.id, now: clock.now()) }
        return privateState.applying(to: made, now: clock.now())
    }

    /// `PATCH /share/sets/<id>` (APP-API-CONTRACT 41.1) against the preview library: `notFound` for a link it does not
    /// hold, `changed(set)` when `expect` is not its list, `badRequest` unless 2..max distinct ids (and a title of 1..80
    /// characters), `hidden(ids)` for added files of hidden posts, `notPublic(ids)` for added files that are missing (or
    /// private, in a public link). Files already in the link stay as they are.
    public func updateShareSet(id: String, items: [String]?, title: ShareSetTitleChange, expect: [String]?) async throws -> ShareSet {
        shareState.record("PATCH \(id) " + (items ?? []).joined(separator: ","))
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        let now = clock.now()
        guard let stored = shareState.set(id) else { throw ShareSetError.notFound }
        let before = stored.items.map(\.id)
        if let expect, expect != before { throw ShareSetError.changed(privateState.applying(to: stored, now: now)) }
        let newTitle: String?
        switch title {
        case .keep:
            newTitle = stored.title
        case .clear:
            newTitle = nil
        case .set(let text):
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.unicodeScalars.count <= ShareSetRule.titleLimit else { throw ShareSetError.badRequest }
            newTitle = cleaned.isEmpty ? nil : cleaned
        }
        if items == nil, title == .keep { throw ShareSetError.badRequest }
        let next = items ?? before
        let maximum = PreviewData.capabilities(for: scenario).limits.shareSetMax
        guard next.count >= ShareSetRule.minimum, next.count <= maximum, Set(next).count == next.count else {
            throw ShareSetError.badRequest
        }
        let added = next.filter { !before.contains($0) }
        let hiddenFiles = Set(hiddenState.hidden.flatMap { $0.files.map(\.id) })
        let hiddenAdded = added.filter { hiddenFiles.contains($0) }
        if !hiddenAdded.isEmpty { throw ShareSetError.hidden(hiddenAdded) }
        let isPrivate = privateState.link(.set, id, now: now) != nil
        var posts: [LibraryPost] = []
        if !added.isEmpty { posts = try await library(cursor: nil, limit: 100, v2: visibility != .off).posts }
        var wire: [ShareSetItem] = []
        var refused: [String] = []
        for fileID in next {
            if let kept = stored.items.first(where: { $0.id == fileID }) {
                wire.append(kept)
                continue
            }
            guard let post = posts.first(where: { $0.files.contains { $0.id == fileID } }),
                  let file = post.files.first(where: { $0.id == fileID }), isPrivate || (file.isPublic && file.url != nil) else {
                refused.append(fileID)
                continue
            }
            let isVideo = file.contentType?.lowercased().hasPrefix("video/") == true
            wire.append(ShareSetItem(
                id: fileID, url: file.url ?? file.privateURL, contentType: file.contentType,
                posterURL: file.posterURL ?? (isVideo ? post.posterURL : nil),
                width: file.width, height: file.height, duration: file.duration))
        }
        if !refused.isEmpty { throw ShareSetError.notPublic(refused) }
        guard let updated = shareState.replace(id, items: wire, title: newTitle) else { throw ShareSetError.notFound }
        return privateState.applying(to: updated, now: now)
    }

    /// `GET /share/sets`: newest first; `.shareLinksFail` answers `503`.
    public func shareSets() async throws -> [ShareSet] {
        shareState.record("GET")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let sets = shareState.list() else { throw ShareSetError.unavailable }
        let now = clock.now()
        return sets.map { privateState.applying(to: $0, now: now) }
    }

    /// `DELETE /share/sets/<id>`: the link goes; an id the server does not hold is `.notFound`.
    public func revokeShareSet(id: String) async throws {
        shareState.record("DELETE " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard shareState.remove(id) else { throw ShareSetError.notFound }
        privateState.revoke(.set, id)                      // revoking a link revokes its private link too (36.2)
    }

    // MARK: collections (APP-API-CONTRACT 26)

    /// `GET /share/collections`: most recently changed first; `.shareLinksFail` answers `503`.
    public func shareCollections() async throws -> [ShareCollection] {
        shareState.record("GET collections")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let list = shareState.listCollections() else { throw ShareCollectionError.unavailable }
        return list
    }

    /// `POST /share/collections`: `badRequest` unless the name cleans to 1..60 code points; `linkNotFound(ids)`,
    /// `tooMany` as the server does.
    public func createShareCollection(name: String, setIDs: [String]) async throws -> ShareCollection {
        shareState.record("POST collections " + setIDs.joined(separator: ","))
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let cleaned = ShareCollectionRule.cleanName(name) else { throw ShareCollectionError.badRequest }
        return try shareState.addCollection(name: cleaned, setIDs: setIDs, at: clock.now())
    }

    /// `PATCH /share/collections/<id>`: `badRequest` for nothing to change or a bad name; the rest as the server.
    public func updateShareCollection(id: String, name: String?, add: [String], remove: [String]) async throws -> ShareCollection {
        shareState.record("PATCH collections " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        var cleaned: String?
        if let name {
            guard let c = ShareCollectionRule.cleanName(name) else { throw ShareCollectionError.badRequest }
            cleaned = c
        }
        guard cleaned != nil || !add.isEmpty || !remove.isEmpty else { throw ShareCollectionError.badRequest }
        return try shareState.change(id, name: cleaned, add: add, remove: remove, at: clock.now())
    }

    /// `DELETE /share/collections/<id>`: the folder goes, its links stay; an unknown id is `.notFound`.
    public func deleteShareCollection(id: String) async throws {
        shareState.record("DELETE collections " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard shareState.removeCollection(id) else { throw ShareCollectionError.notFound }
    }

    /// `POST /share/collections/<id>/reroll`: new links for the collection's live ones (see `PreviewShareState.reroll`).
    public func rerollShareCollection(id: String) async throws -> ShareCollectionReroll {
        shareState.record("POST collections reroll " + id)
        try await clock.sleep(seconds: 0.6 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        return try shareState.reroll(id, at: clock.now())
    }

    // MARK: collection groups (APP-API-CONTRACT 28)

    /// `GET /share/groups`: most recently changed first; `.shareLinksFail` answers `503`.
    public func collectionGroups() async throws -> [CollectionGroup] {
        shareState.record("GET groups")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let list = shareState.listGroups() else { throw CollectionGroupError.unavailable }
        return list
    }

    /// `POST /share/groups`: `badRequest` unless the name cleans to 1..60 code points; `collectionNotFound(ids)`,
    /// `tooMany` as the server does.
    public func createCollectionGroup(name: String, collectionIDs: [String]) async throws -> CollectionGroup {
        shareState.record("POST groups " + collectionIDs.joined(separator: ","))
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let cleaned = CollectionGroupRule.cleanName(name) else { throw CollectionGroupError.badRequest }
        return try shareState.addGroup(name: cleaned, collectionIDs: collectionIDs, at: clock.now())
    }

    /// `PATCH /share/groups/<id>`: `badRequest` for nothing to change or a bad name; the rest as the server.
    public func updateCollectionGroup(id: String, name: String?, add: [String], remove: [String]) async throws -> CollectionGroup {
        shareState.record("PATCH groups " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        var cleaned: String?
        if let name {
            guard let c = CollectionGroupRule.cleanName(name) else { throw CollectionGroupError.badRequest }
            cleaned = c
        }
        guard cleaned != nil || !add.isEmpty || !remove.isEmpty else { throw CollectionGroupError.badRequest }
        return try shareState.changeGroup(id, name: cleaned, add: add, remove: remove, at: clock.now())
    }

    /// `DELETE /share/groups/<id>`: the group goes, its collections stay; an unknown id is `.notFound`.
    public func deleteCollectionGroup(id: String) async throws {
        shareState.record("DELETE groups " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard shareState.removeGroup(id) else { throw CollectionGroupError.notFound }
    }
}
