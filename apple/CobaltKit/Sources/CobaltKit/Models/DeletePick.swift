import Foundation

/// What the library's select panel deletes of one picked post (its trash circle): everything, or
/// only the files the owner ticked. Only the files the server can delete one by one can be ticked: a gallery's items
/// (while one stays), what was made from it (slideshows, gallery images, crops, animated stills) and a video's webps. A
/// video's original goes only with everything (`DELETE /library/posts`). No new route: the same calls the detail uses.
public struct DeletePick: Sendable, Equatable {
    public enum Plan: Sendable, Equatable {
        /// Nothing ticked: the post is kept.
        case nothing
        /// The whole post (`AppModel.deleteEverything`).
        case everything
        /// Only these files: item indices (`deleteItems`), made files (`deleteMade`), webps (`deleteWebp`).
        case files(items: [Int], made: [Rendition.ID], webps: [Rendition.ID])
        /// Every item ticked but not everything: the server keeps a post's last item, so this has to be everything.
        case keepOneItem
    }

    public let item: MediaItem
    /// Everything goes: the post itself (and its video), whatever `chosen` says.
    public var everything: Bool
    /// The ticked files when not `everything`.
    public var chosen: Set<Rendition.ID>

    public init(item: MediaItem) {
        self.item = item
        everything = true
        chosen = []
    }

    /// The files that can be ticked one by one, in the detail's tab order (items, made, webps).
    public static func choosable(in item: MediaItem) -> [Rendition] {
        let items = item.items.count >= 2 ? item.items.filter { $0.file != nil || $0.local != nil } : []
        let made = item.made.filter { $0.file != nil || $0.local != nil }
        let webps = item.webps.filter { $0.deletableName != nil || ($0.file == nil && $0.publicURL == nil && $0.local != nil) }
        return items + made + webps
    }

    public var choosable: [Rendition] { Self.choosable(in: item) }

    /// More than one thing to choose from: the panel offers `choose files`.
    public var canChoose: Bool { !choosable.isEmpty && item.renditions.count >= 2 }

    /// The file is going: everything is, or it is ticked.
    public func isChosen(_ id: Rendition.ID) -> Bool { everything || chosen.contains(id) }

    /// Ticks or unticks one file. Unticking one while everything goes keeps the rest ticked; ticking the last one of a post
    /// whose files can all be ticked is everything again.
    public mutating func toggle(_ id: Rendition.ID) {
        guard choosable.contains(where: { $0.id == id }) else { return }
        if everything {
            everything = false
            chosen = Set(choosable.map(\.id)).subtracting([id])
        } else if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
            // every file ticked, and nothing else in the post: that is everything again
            if chosen.count == choosable.count, choosable.count == item.renditions.count {
                everything = true
                chosen = []
            }
        }
    }

    /// The whole post, or none of it.
    public mutating func toggleEverything() {
        everything.toggle()
        chosen = []
    }

    public var plan: Plan {
        if everything { return .everything }
        let ticked = choosable.filter { chosen.contains($0.id) }
        if ticked.isEmpty { return .nothing }
        let items = ticked.compactMap(\.itemIndex)
        let liveItems = item.items.filter { $0.itemIndex != nil }.count
        if !items.isEmpty, items.count >= liveItems { return .keepOneItem }
        return .files(
            items: items, made: ticked.filter(\.isMade).map(\.id), webps: ticked.filter(\.isWebp).map(\.id))
    }

    /// How many files the plan deletes (everything counts every file the post has).
    public var fileCount: Int {
        switch plan {
        case .nothing, .keepOneItem: 0
        case .everything: max(item.renditions.count, item.post?.files.count ?? 0, 1)
        case .files(let items, let made, let webps): items.count + made.count + webps.count
        }
    }
}

extension AppModel {
    /// Deletes what one pick's plan says (the select panel's trash). `.everything` is `deleteEverything`; `.files` deletes
    /// the made files and webps first, then the items (one stays, `deleteItems` checks). Throws on the first failure,
    /// after the ones that went were dropped; `.nothing` and `.keepOneItem` do nothing.
    @discardableResult
    public func delete(_ pick: DeletePick) async throws -> DeleteOutcome {
        switch pick.plan {
        case .nothing, .keepOneItem:
            return .done
        case .everything:
            return try await deleteEverything(pick.item)
        case .files(let items, let made, let webps):
            for id in made {
                if let r = pick.item.rendition(id: id) { try await deleteMade(r, of: pick.item) }
            }
            for id in webps {
                if let r = pick.item.rendition(id: id) { try await deleteWebp(r, of: pick.item) }
            }
            if !items.isEmpty { try await deleteItems(items, of: pick.item) }
            return .done
        }
    }
}
