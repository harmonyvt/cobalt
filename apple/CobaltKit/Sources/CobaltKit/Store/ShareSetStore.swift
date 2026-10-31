import Foundation
import Observation

/// The gallery share links the owner has made (APP-API-CONTRACT 24): `GET /share/sets` for the links tab, `POST` from
/// the library's select bar, `DELETE` to revoke. It also holds their collections (section 26, only while
/// `capabilities.shareCollections`) and the groups of collections, "sets" in the app (section 28, only while
/// `capabilities.shareGroups`): the same refresh loads all three, so the links tab never shows a folder over links it
/// has not loaded. Reads the app model's current client on every call, so a server or key
/// change is picked up (`reset()` forgets what the old server listed).
@MainActor @Observable
public final class ShareSetStore {
    public enum State: Equatable, Sendable {
        case idle
        /// A `refresh()` is running. `sets` still holds what was listed before, if anything.
        case loading
        case loaded
        /// The last `refresh()` failed, with a message to show. `sets` still holds what was listed before.
        case failed(String)
    }

    /// The live sets, newest first.
    public private(set) var sets: [ShareSet] = []
    /// The collections, most recently changed first; always empty while the server has no `share_collections`.
    public private(set) var collections: [ShareCollection] = []
    /// The collection groups ("sets"), most recently changed first; always empty while the server has no `share_groups`.
    public private(set) var groups: [CollectionGroup] = []
    public private(set) var state: State = .idle
    /// Every live private link (APP-API-CONTRACT 36), files' and gallery links', newest first; always empty while the
    /// server has no `private_links`.
    public private(set) var privateLinks: [PrivateLink] = []
    /// What a new gallery link starts as (`share_settings.new_links`); `.public` until the server says.
    public private(set) var newLinks: NewLinks = .public
    /// `GET /share/private` has answered since the last reset.
    public private(set) var privateLoaded = false

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`: an answer from the old server arriving later is dropped.
    @ObservationIgnored private var generation = 0

    init(context: PipelineContext) {
        self.ctx = context
    }

    /// Lists the sets again (`GET /share/sets`) and, when the server has them, the collections (`GET /share/collections`)
    /// and the groups (`GET /share/groups`) beside them. A refresh that is already running is not doubled. If any list
    /// fails the state is `.failed` and whatever loaded before stays.
    public func refresh() async {
        guard state != .loading else { return }
        let started = generation
        state = .loading
        let client = ctx.client
        let withCollections = ctx.capabilities.shareCollections
        let withGroups = withCollections && ctx.capabilities.shareGroups
        let withPrivate = ctx.capabilities.privateLinks
        do {
            async let listedSets = client.shareSets()
            async let listedCollections: [ShareCollection] = withCollections ? client.shareCollections() : []
            async let listedGroups: [CollectionGroup] = withGroups ? client.collectionGroups() : []
            // the private links never fail the links tab: a server that cannot list them shows the links as they are
            async let listedPrivate = Self.loadPrivate(client, withPrivate)
            let (newSets, newCollections, newGroups) = try await (listedSets, listedCollections, listedGroups)
            let newPrivate = await listedPrivate
            guard started == generation else { return }
            sets = newSets.sorted { $0.createdAt > $1.createdAt }
            collections = withCollections ? newCollections.sorted { $0.updatedAt > $1.updatedAt } : []
            groups = withGroups ? newGroups.sorted { $0.updatedAt > $1.updatedAt } : []
            if let newPrivate { takePrivate(newPrivate) } else if !withPrivate { forgetPrivate() }
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(Self.message(for: error))
        }
    }

    /// Makes a link (`POST /share/sets`) and puts it first. Throws `ShareSetError` (`.notPublic(ids)` names the files
    /// that are private now) or whatever the transport threw; nothing is inserted then. `isPrivate` (APP-API-CONTRACT
    /// 36.3): nil lets the server use `new_links`; true makes it private in the same call (any live files).
    @discardableResult
    public func create(items: [String], title: String?, private isPrivate: Bool? = nil) async throws -> ShareSet {
        let started = generation
        let made: ShareSet
        if let isPrivate, ctx.capabilities.privateLinks {
            made = try await ctx.client.createShareSet(items: items, title: title, private: isPrivate)
        } else {
            made = try await ctx.client.createShareSet(items: items, title: title)
        }
        if started == generation {
            sets.removeAll { $0.id == made.id }
            sets.insert(made, at: 0)
            if let link = made.link { notePrivate(link) }
        }
        return made
    }

    /// Revokes a link (`DELETE /share/sets/<id>`) and drops its row. A set the server no longer knows (`.notFound`) is
    /// gone already, so its row goes too; any other error leaves the row and is thrown.
    public func revoke(_ id: String) async throws {
        let started = generation
        do {
            try await ctx.client.revokeShareSet(id: id)
        } catch ShareSetError.notFound {
            // already gone
        }
        if started == generation {
            dropLocally(setIDs: [id])
            privateLinks.removeAll { $0.id == PrivateLink.id(.set, id) }     // revoking a link revokes its key too
        }
    }

    // MARK: editing a link (APP-API-CONTRACT 41)

    /// The link with this id, if it is loaded.
    public func set(_ id: String) -> ShareSet? { sets.first { $0.id == id } }

    /// Changes a link's files and/or title (`PATCH /share/sets/<id>`): `items` the whole new list (nil keeps it),
    /// `expect` the list last seen. The answer replaces the link in `sets` (it keeps its place). When the link moved on
    /// meanwhile (`ShareSetError.changed(set)`) the server's link replaces it and the error is rethrown, so the screen can
    /// say it reloaded; a link the server no longer has (`.notFound`) goes from the list. Anything else changes nothing.
    @discardableResult
    public func update(
        _ setID: String, items: [String]?, title: ShareSetTitleChange = .keep, expect: [String]?
    ) async throws -> ShareSet {
        let started = generation
        do {
            let updated = try await ctx.client.updateShareSet(id: setID, items: items, title: title, expect: expect)
            if started == generation { replace(updated) }
            return updated
        } catch let ShareSetError.changed(current) {
            if started == generation { replace(current) }
            throw ShareSetError.changed(current)
        } catch ShareSetError.notFound {
            if started == generation {
                dropLocally(setIDs: [setID])
                privateLinks.removeAll { $0.id == PrivateLink.id(.set, setID) }
            }
            throw ShareSetError.notFound
        }
    }

    /// The library's "add to link": appends these files to the link, in order, skipping ones it holds already, with the
    /// link's list as `expect`. Answers the link as stored (unchanged when there was nothing new). Past
    /// `limits.share_set_max` is `.badRequest` without asking; a link that is not loaded is `.notFound`.
    @discardableResult
    public func addFiles(_ fileIDs: [String], to setID: String) async throws -> ShareSet {
        guard let link = set(setID) else { throw ShareSetError.notFound }
        let current = link.items.map(\.id)
        var next = current
        for id in fileIDs where !next.contains(id) { next.append(id) }
        guard next.count > current.count else { return link }
        guard next.count <= ctx.capabilities.limits.shareSetMax else { throw ShareSetError.badRequest }
        return try await update(setID, items: next, expect: current)
    }

    /// A link as the server just answered it: in place of the old one (its place in the list kept), else first.
    private func replace(_ link: ShareSet) {
        if let index = sets.firstIndex(where: { $0.id == link.id }) {
            sets[index] = link
        } else {
            sets.insert(link, at: 0)
        }
        if let key = link.link { notePrivate(key) }
    }

    // MARK: private links (APP-API-CONTRACT 36)

    /// Lists the private links and `new_links` again (`GET /share/private`) without touching the links. Throws what the
    /// client threw; nothing changes then. Nothing is asked while the server has no `private_links`.
    public func refreshPrivate() async throws {
        guard ctx.capabilities.privateLinks else { forgetPrivate(); return }
        let started = generation
        let list = try await ctx.client.privateLinks()
        if started == generation { takePrivate(list) }
    }

    /// The live private link of a gallery link, if any.
    public func privateLink(forSet id: String) -> PrivateLink? {
        privateLinks.first { $0.id == PrivateLink.id(.set, id) } ?? sets.first { $0.id == id }?.link
    }

    /// The live private link of a library file, if any.
    public func privateLink(forItem id: String) -> PrivateLink? {
        privateLinks.first { $0.id == PrivateLink.id(.item, id) }
    }

    /// How many live private links there are (files and gallery links).
    public var privateLinkCount: Int { privateLinks.count }

    /// The PUBLIC gallery links that hold this library file: the ones a file going private drops out of (36.2), which
    /// the app offers to make private too.
    public func publicSets(containing fileID: String) -> [ShareSet] {
        sets.filter { !$0.isPrivate && $0.items.contains { $0.id == fileID } }
    }

    /// Turns a gallery link's private link on (`PUT /share/private/sets/<id>`): its row now carries the private URL.
    /// `.notFound` means the link is gone, so its row goes; anything else leaves it and is thrown.
    @discardableResult
    public func makePrivate(_ setID: String) async throws -> PrivateLink {
        let started = generation
        do {
            let link = try await ctx.client.enablePrivateLink(.set, id: setID)
            if started == generation { notePrivate(link) }
            return link
        } catch PrivateLinkError.notFound {
            if started == generation { dropLocally(setIDs: [setID]) }
            throw PrivateLinkError.notFound
        }
    }

    /// Revokes a gallery link's private link (`DELETE /share/private/sets/<id>`): it is public again at `share…/g/<id>`.
    public func makePublic(_ setID: String) async throws {
        let started = generation
        try await ctx.client.revokePrivateLink(.set, id: setID)
        guard started == generation else { return }
        dropPrivate(.set, setID)
        // a server that never said the public address: list again so the row shows the one that works
        if sets.first(where: { $0.id == setID })?.publicURL == nil,
           let listed = try? await ctx.client.shareSets(), started == generation {
            sets = listed.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// A new key for a gallery link (`POST /share/private/sets/<id>/rotate`); the old one is a 404 at once. `.notFound`
    /// (none live) drops the key locally and rethrows.
    @discardableResult
    public func rotate(_ setID: String) async throws -> PrivateLink {
        try await rotate(.set, setID)
    }

    /// A new key for a file (`POST /share/private/items/<id>/rotate`).
    @discardableResult
    public func rotateItem(_ fileID: String) async throws -> PrivateLink {
        try await rotate(.item, fileID)
    }

    private func rotate(_ kind: PrivateLink.Kind, _ id: String) async throws -> PrivateLink {
        let started = generation
        do {
            let link = try await ctx.client.rotatePrivateLink(kind, id: id)
            if started == generation { notePrivate(link) }
            return link
        } catch PrivateLinkError.notFound {
            if started == generation { dropPrivate(kind, id) }
            throw PrivateLinkError.notFound
        }
    }

    /// Every live key rotated in one batch (`POST /share/private/rotate-all`): the links and the gallery link rows carry
    /// the new keys. Answers how many were rotated.
    @discardableResult
    public func rotateAll() async throws -> PrivateLinkRotation {
        let started = generation
        let answer = try await ctx.client.rotateAllPrivateLinks()
        guard started == generation else { return answer }
        privateLinks = []
        for link in answer.links { notePrivate(link) }
        privateLoaded = true
        return answer
    }

    /// `PATCH /share/private/settings`: what a new gallery link starts as.
    public func setNewLinks(_ value: NewLinks) async throws {
        let started = generation
        let stored = try await ctx.client.setNewLinks(value)
        if started == generation { newLinks = stored }
    }

    /// Every live gallery link of a collection made private, made public or rotated (`POST .../privacy`). Answers the
    /// private links after the change. `.notFound` drops the collection locally and rethrows.
    @discardableResult
    public func setPrivacy(of collectionID: String, _ change: CollectionPrivacy) async throws -> [PrivateLink] {
        let started = generation
        let links: [PrivateLink]
        do {
            links = try await ctx.client.setCollectionPrivacy(id: collectionID, change)
        } catch ShareCollectionError.notFound {
            if started == generation { dropLocally(collectionIDs: [collectionID]) }
            throw ShareCollectionError.notFound
        }
        guard started == generation else { return links }
        if change == .makePublic, let collection = collection(collectionID) {
            for id in collection.setIDs { dropPrivate(.set, id) }
            if sets.contains(where: { collection.setIDs.contains($0.id) && $0.publicURL == nil }),
               let listed = try? await ctx.client.shareSets(), started == generation {
                sets = listed.sorted { $0.createdAt > $1.createdAt }
            }
        }
        for link in links { notePrivate(link) }
        return links
    }

    /// The private links of a collection's loaded links: how many are private, of how many.
    public func privateCount(in collection: ShareCollection) -> Int {
        sets(in: collection).filter(\.isPrivate).count
    }

    /// A file's private link as the app just learned it (36.6, the detail): kept in the list.
    func noteItemLink(_ link: PrivateLink) { notePrivate(link) }

    /// A file's private link is gone (revoked, or the file is public again).
    func dropItemLink(_ fileID: String) { dropPrivate(.item, fileID) }

    nonisolated private static func loadPrivate(_ client: any CobaltClient, _ on: Bool) async -> PrivateLinkList? {
        guard on else { return nil }
        return try? await client.privateLinks()
    }

    private func takePrivate(_ list: PrivateLinkList) {
        privateLinks = list.links.sorted { $0.createdAt > $1.createdAt }
        newLinks = list.newLinks
        privateLoaded = true
        // a gallery link row follows its live key (the list of sets may be older than this answer)
        for link in list.links where link.kind == .set {
            if let i = sets.firstIndex(where: { $0.id == link.targetID }) { sets[i] = sets[i].makingPrivate(link) }
        }
    }

    private func forgetPrivate() {
        privateLinks = []
        newLinks = .public
        privateLoaded = false
    }

    /// A live private link: first in the list (in place of the old key of the same thing), and its gallery link row
    /// carries it.
    private func notePrivate(_ link: PrivateLink) {
        privateLinks.removeAll { $0.id == link.id }
        privateLinks.insert(link, at: 0)
        if link.kind == .set, let i = sets.firstIndex(where: { $0.id == link.targetID }) {
            sets[i] = sets[i].makingPrivate(link)
        }
    }

    private func dropPrivate(_ kind: PrivateLink.Kind, _ id: String) {
        privateLinks.removeAll { $0.id == PrivateLink.id(kind, id) }
        if kind == .set, let i = sets.firstIndex(where: { $0.id == id }), sets[i].isPrivate {
            sets[i] = sets[i].makingPublic(fallback: Self.publicAddress(of: id, ctx.capabilities.shareBaseURL))
        }
    }

    /// `<share_base_url>g/<id>`, for a server that did not send `public_url`.
    static func publicAddress(of setID: String, _ base: URL?) -> URL? {
        guard let base else { return nil }
        return base.appendingPathComponent("g").appendingPathComponent(setID)
    }

    // MARK: collections (APP-API-CONTRACT 26)

    /// The collection with this id, if it is loaded.
    public func collection(_ id: String) -> ShareCollection? { collections.first { $0.id == id } }

    /// The loaded links of a collection, in the collection's order (most recently added first); ids that are not
    /// loaded are skipped.
    public func sets(in collection: ShareCollection) -> [ShareSet] {
        let byID = Dictionary(sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return collection.setIDs.compactMap { byID[$0] }
    }

    /// Every live link of a collection, one URL per line in the collection's order (owner: "a share collection button
    /// which combines all the gallery links separated by a return"); nil when it has none loaded.
    public func linksText(in collection: ShareCollection) -> String? {
        let urls = sets(in: collection).map(\.url.absoluteString)
        return urls.isEmpty ? nil : urls.joined(separator: "\n")
    }

    /// The collections a link is in.
    public func collections(containing setID: String) -> [ShareCollection] {
        collections.filter { $0.setIDs.contains(setID) }
    }

    /// Every gallery link's collection names, in `collections` order, in one pass: for a whole list of rows.
    public func collectionNamesBySet() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for collection in collections {
            for id in Set(collection.setIDs) { out[id, default: []].append(collection.name) }
        }
        return out
    }

    /// What `privateLink(forSet:)` answers, for every gallery link at once (the store's list wins over the link's own).
    public func privateLinksBySet() -> [String: PrivateLink] {
        var out: [String: PrivateLink] = [:]
        for set in sets {
            if let link = set.link { out[set.id] = link }
        }
        for link in privateLinks.reversed() where link.kind == .set { out[link.targetID] = link }
        return out
    }

    /// Makes a collection (`POST /share/collections`) and puts it first. Throws `ShareCollectionError` (`.linkNotFound`
    /// names links that are gone, `.tooMany` at 100 collections) or whatever the transport threw; nothing is inserted
    /// then. `name` is sent as given: clean it with `ShareCollectionRule.cleanName` first.
    @discardableResult
    public func createCollection(name: String, setIDs: [String] = []) async throws -> ShareCollection {
        let started = generation
        do {
            let made = try await ctx.client.createShareCollection(name: name, setIDs: setIDs)
            if started == generation { put(made) }
            return made
        } catch let ShareCollectionError.linkNotFound(ids) {
            if started == generation { dropLocally(setIDs: ids) }
            throw ShareCollectionError.linkNotFound(ids)
        }
    }

    /// Renames a collection (`PATCH`). The answer replaces the local one and moves it first.
    @discardableResult
    public func renameCollection(_ id: String, to name: String) async throws -> ShareCollection {
        try await update(id, name: name, add: [], remove: [])
    }

    /// Puts a link in a collection (`PATCH` `add`); already in it is a no-op on the server.
    @discardableResult
    public func addLink(_ setID: String, to collectionID: String) async throws -> ShareCollection {
        try await update(collectionID, name: nil, add: [setID], remove: [])
    }

    /// Takes a link out of a collection (`PATCH` `remove`); the link itself stays live.
    @discardableResult
    public func removeLink(_ setID: String, from collectionID: String) async throws -> ShareCollection {
        try await update(collectionID, name: nil, add: [], remove: [setID])
    }

    /// Deletes a collection (`DELETE`); its links stay live. A collection the server no longer knows (`.notFound`) is gone
    /// already, so it goes locally too; any other error leaves it and is thrown.
    public func deleteCollection(_ id: String) async throws {
        let started = generation
        do {
            try await ctx.client.deleteShareCollection(id: id)
        } catch ShareCollectionError.notFound {
            // already gone
        }
        if started == generation { dropLocally(collectionIDs: [id]) }
    }

    /// Rerolls every live link of a collection (`POST .../reroll`): the collection is replaced by the answer, the old link
    /// ids are swapped for the new ones in every other loaded collection, and the sets are listed again (so the new URLs
    /// and thumbnails load) without touching the collections. `.notFound` drops the collection locally and rethrows;
    /// `.empty` and the rest rethrow with everything as it was. A failed re-listing is not an error: the reroll
    /// happened, and the next refresh picks the new links up.
    @discardableResult
    public func rerollCollection(_ id: String) async throws -> ShareCollectionReroll {
        let started = generation
        let client = ctx.client
        let answer: ShareCollectionReroll
        do {
            answer = try await client.rerollShareCollection(id: id)
        } catch ShareCollectionError.notFound {
            if started == generation { dropLocally(collectionIDs: [id]) }
            throw ShareCollectionError.notFound
        }
        guard started == generation else { return answer }
        for i in collections.indices where collections[i].id != answer.collection.id {
            collections[i].setIDs = collections[i].setIDs.map { answer.replaced[$0] ?? $0 }
        }
        put(answer.collection)
        // the old links are revoked: out of the list now, so no stale row shows while the new ones load
        let gone = Set(answer.replaced.keys)
        sets.removeAll { gone.contains($0.id) }
        if let listed = try? await client.shareSets(), started == generation {
            sets = listed.sorted { $0.createdAt > $1.createdAt }
        }
        return answer
    }

    private func update(_ id: String, name: String?, add: [String], remove: [String]) async throws -> ShareCollection {
        let started = generation
        do {
            let changed = try await ctx.client.updateShareCollection(id: id, name: name, add: add, remove: remove)
            if started == generation { put(changed) }
            return changed
        } catch ShareCollectionError.notFound {
            if started == generation { dropLocally(collectionIDs: [id]) }
            throw ShareCollectionError.notFound
        } catch let ShareCollectionError.linkNotFound(ids) {
            if started == generation { dropLocally(setIDs: ids) }
            throw ShareCollectionError.linkNotFound(ids)
        }
    }

    /// A collection as the server just answered it: first in the list (it changed last).
    private func put(_ collection: ShareCollection) {
        collections.removeAll { $0.id == collection.id }
        collections.insert(collection, at: 0)
    }

    /// Links that are revoked or gone: out of the list and out of every collection (the server does the same).
    private func dropLocally(setIDs gone: [String]) {
        let ids = Set(gone)
        sets.removeAll { ids.contains($0.id) }
        for i in collections.indices { collections[i].setIDs.removeAll { ids.contains($0) } }
    }

    /// Collections that are deleted or gone: out of the list and out of every group (the server does the same).
    private func dropLocally(collectionIDs gone: [String]) {
        let ids = Set(gone)
        collections.removeAll { ids.contains($0.id) }
        for i in groups.indices { groups[i].collectionIDs.removeAll { ids.contains($0) } }
    }

    // MARK: collection groups, "sets" (APP-API-CONTRACT 28)

    /// The group with this id, if it is loaded.
    public func group(_ id: String) -> CollectionGroup? { groups.first { $0.id == id } }

    /// The loaded collections of a group, in the group's order (most recently added first); ids that are not loaded are
    /// skipped.
    public func collections(in group: CollectionGroup) -> [ShareCollection] {
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return group.collectionIDs.compactMap { byID[$0] }
    }

    /// The groups a collection is in.
    public func groups(containing collectionID: String) -> [CollectionGroup] {
        groups.filter { $0.collectionIDs.contains(collectionID) }
    }

    /// Every live link of a group's collections, one URL per line: the group's order, then each collection's order, a
    /// link in several of its collections once (where it first shows); nil when it has none loaded.
    public func linksText(in group: CollectionGroup) -> String? {
        var seen = Set<String>()
        var urls: [String] = []
        for collection in collections(in: group) {
            for link in sets(in: collection) where seen.insert(link.id).inserted {
                urls.append(link.url.absoluteString)
            }
        }
        return urls.isEmpty ? nil : urls.joined(separator: "\n")
    }

    /// Makes a group (`POST /share/groups`) and puts it first. Throws `CollectionGroupError` (`.collectionNotFound`
    /// names collections that are gone, which are dropped locally; `.tooMany` at 100 groups) or whatever the transport
    /// threw; nothing is inserted then. `name` is sent as given: clean it with `CollectionGroupRule.cleanName` first.
    @discardableResult
    public func createGroup(name: String, collectionIDs: [String] = []) async throws -> CollectionGroup {
        let started = generation
        do {
            let made = try await ctx.client.createCollectionGroup(name: name, collectionIDs: collectionIDs)
            if started == generation { put(made) }
            return made
        } catch let CollectionGroupError.collectionNotFound(ids) {
            if started == generation { dropLocally(collectionIDs: ids) }
            throw CollectionGroupError.collectionNotFound(ids)
        }
    }

    /// Renames a group (`PATCH`). The answer replaces the local one and moves it first.
    @discardableResult
    public func renameGroup(_ id: String, to name: String) async throws -> CollectionGroup {
        try await updateGroup(id, name: name, add: [], remove: [])
    }

    /// Puts a collection in a group (`PATCH` `add`); already in it is a no-op on the server.
    @discardableResult
    public func addCollection(_ collectionID: String, to groupID: String) async throws -> CollectionGroup {
        try await updateGroup(groupID, name: nil, add: [collectionID], remove: [])
    }

    /// Takes a collection out of a group (`PATCH` `remove`); the collection itself stays.
    @discardableResult
    public func removeCollection(_ collectionID: String, from groupID: String) async throws -> CollectionGroup {
        try await updateGroup(groupID, name: nil, add: [], remove: [collectionID])
    }

    /// Deletes a group (`DELETE`); its collections stay. A group the server no longer knows (`.notFound`) is gone
    /// already, so it goes locally too; any other error leaves it and is thrown.
    public func deleteGroup(_ id: String) async throws {
        let started = generation
        do {
            try await ctx.client.deleteCollectionGroup(id: id)
        } catch CollectionGroupError.notFound {
            // already gone
        }
        if started == generation { groups.removeAll { $0.id == id } }
    }

    private func updateGroup(_ id: String, name: String?, add: [String], remove: [String]) async throws -> CollectionGroup {
        let started = generation
        do {
            let changed = try await ctx.client.updateCollectionGroup(id: id, name: name, add: add, remove: remove)
            if started == generation { put(changed) }
            return changed
        } catch CollectionGroupError.notFound {
            if started == generation { groups.removeAll { $0.id == id } }
            throw CollectionGroupError.notFound
        } catch let CollectionGroupError.collectionNotFound(ids) {
            if started == generation { dropLocally(collectionIDs: ids) }
            throw CollectionGroupError.collectionNotFound(ids)
        }
    }

    /// A group as the server just answered it: first in the list (it changed last).
    private func put(_ group: CollectionGroup) {
        groups.removeAll { $0.id == group.id }
        groups.insert(group, at: 0)
    }

    /// Another server or key: nothing from the old one is kept.
    func reset() {
        generation += 1
        sets = []
        collections = []
        groups = []
        forgetPrivate()
        state = .idle
    }

    /// A short line for the failed state (the UI may word it its own way from the error kind).
    static func message(for error: Error) -> String {
        switch error {
        case ShareSetError.unavailable: return "The server can't make links right now."
        case ShareCollectionError.unavailable: return "The server can't load collections right now."
        case CollectionGroupError.unavailable: return "The server can't load sets right now."
        case ShareSetError.notFound, ShareSetError.badRequest, ShareSetError.notPublic, ShareSetError.hidden: return "The server refused the request."
        case ShareSetError.changed: return "The link changed on another device."
        case PrivateLinkError.unavailable: return "The server can't make private links right now."
        case PrivateLinkError.notFound, PrivateLinkError.notToggleable, PrivateLinkError.badRequest: return "The server refused the request."
        case CobaltError.network: return "Can't reach the server."
        case CobaltError.noAPIKey: return "No API key."
        case CobaltError.api(let code, _) where code.hasPrefix("error.api.auth.key."): return "The API key was refused."
        case is CancellationError: return "Cancelled."
        default: return "Something went wrong."
        }
    }
}
