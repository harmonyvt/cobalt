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
        do {
            async let listedSets = client.shareSets()
            async let listedCollections: [ShareCollection] = withCollections ? client.shareCollections() : []
            async let listedGroups: [CollectionGroup] = withGroups ? client.collectionGroups() : []
            let (newSets, newCollections, newGroups) = try await (listedSets, listedCollections, listedGroups)
            guard started == generation else { return }
            sets = newSets.sorted { $0.createdAt > $1.createdAt }
            collections = withCollections ? newCollections.sorted { $0.updatedAt > $1.updatedAt } : []
            groups = withGroups ? newGroups.sorted { $0.updatedAt > $1.updatedAt } : []
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(Self.message(for: error))
        }
    }

    /// Makes a link (`POST /share/sets`) and puts it first. Throws `ShareSetError` (`.notPublic(ids)` names the files
    /// that are private now) or whatever the transport threw; nothing is inserted then.
    @discardableResult
    public func create(items: [String], title: String?) async throws -> ShareSet {
        let started = generation
        let made = try await ctx.client.createShareSet(items: items, title: title)
        if started == generation {
            sets.removeAll { $0.id == made.id }
            sets.insert(made, at: 0)
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
        if started == generation { dropLocally(setIDs: [id]) }
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
        state = .idle
    }

    /// A short line for the failed state (the UI may word it its own way from the error kind).
    static func message(for error: Error) -> String {
        switch error {
        case ShareSetError.unavailable: return "The server can't make links right now."
        case ShareCollectionError.unavailable: return "The server can't load collections right now."
        case CollectionGroupError.unavailable: return "The server can't load sets right now."
        case ShareSetError.notFound, ShareSetError.badRequest, ShareSetError.notPublic: return "The server refused the request."
        case CobaltError.network: return "Can't reach the server."
        case CobaltError.noAPIKey: return "No API key."
        case CobaltError.api(let code, _) where code.hasPrefix("error.api.auth.key."): return "The API key was refused."
        case is CancellationError: return "Cancelled."
        default: return "Something went wrong."
        }
    }
}
