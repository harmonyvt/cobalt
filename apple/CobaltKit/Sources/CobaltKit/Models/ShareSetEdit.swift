import Foundation

// Editing a gallery link's files after it was made (APP-API-CONTRACT 41): the draft the link screen's edit mode holds,
// what changed (the save bar's words come from `changes`), and the verdict of the library's "add to link" per link.
// Pure values, so the rules are tested without a screen. The server enforces the same (2..`share_set_max` distinct
// ids; an added file public in a public link).

/// One change a draft makes, in the order the save bar says them ("2 added · 1 out · new order · new title").
public enum ShareSetChange: Sendable, Equatable {
    case added(Int)
    case removed(Int)
    case reordered
    case retitled
}

/// A link being edited: the files and title it had when edit began, and the draft.
public struct ShareSetEdit: Sendable, Equatable {
    /// The link's file ids when edit began: what `expect` sends.
    public let original: [String]
    /// Its title then (nil: none, the roast caption shows).
    public let originalTitle: String?
    /// The most files a link holds (`limits.share_set_max`).
    public let maximum: Int
    /// The draft, in the order shown.
    public private(set) var items: [String]
    /// The title field's text, as typed.
    public var title: String

    public init(original: [String], originalTitle: String?, maximum: Int) {
        self.original = original
        self.originalTitle = originalTitle
        self.maximum = Swift.max(ShareSetRule.minimum, maximum)
        self.items = original
        self.title = originalTitle ?? ""
    }

    public init(set: ShareSet, maximum: Int) {
        self.init(original: set.items.map(\.id), originalTitle: set.title, maximum: maximum)
    }

    // MARK: what changed

    /// The files in the draft that were not in the link, in draft order.
    public var added: [String] {
        let before = Set(original)
        return items.filter { !before.contains($0) }
    }

    /// The files of the link that are not in the draft, in the link's order.
    public var removed: [String] {
        let now = Set(items)
        return original.filter { !now.contains($0) }
    }

    /// The files kept are in another order.
    public var moved: Bool {
        let now = Set(items)
        let before = Set(original)
        return original.filter { now.contains($0) } != items.filter { before.contains($0) }
    }

    /// The title as it would be stored: trimmed, control characters out; nil when empty (no title).
    public var cleanedTitle: String? { Self.clean(title) }

    /// The title differs from the link's (after cleaning; nil and "" are the same).
    public var titleChanged: Bool { cleanedTitle != Self.clean(originalTitle ?? "") }

    /// The title fits the server's 80 characters (an empty one always does: it clears the title).
    public var titleFits: Bool { (cleanedTitle?.unicodeScalars.count ?? 0) <= ShareSetRule.titleLimit }

    /// What the save bar says, in its order: added, out, new order, new title. Empty: nothing changed.
    public var changes: [ShareSetChange] {
        var out: [ShareSetChange] = []
        let addedCount = added.count
        let removedCount = removed.count
        if addedCount > 0 { out.append(.added(addedCount)) }
        if removedCount > 0 { out.append(.removed(removedCount)) }
        if moved { out.append(.reordered) }
        if titleChanged { out.append(.retitled) }
        return out
    }

    public var hasChanges: Bool { items != original || titleChanged }

    /// Save is on: something changed, 2..maximum files, a title that fits.
    public var canSave: Bool {
        hasChanges && items.count >= ShareSetRule.minimum && items.count <= maximum && titleFits
    }

    /// The minus is on: taking one out still leaves 2.
    public var canRemove: Bool { items.count > ShareSetRule.minimum }

    /// How many more files fit.
    public var room: Int { Swift.max(0, maximum - items.count) }

    /// No more files fit ("full").
    public var isFull: Bool { room == 0 }

    // MARK: what the save sends

    /// `items`: the whole new list, or nil when the files did not change (a title-only save).
    public var itemsToSend: [String]? { items != original ? items : nil }

    /// `title`: kept, set or cleared.
    public var titleChange: ShareSetTitleChange {
        guard titleChanged else { return .keep }
        return cleanedTitle.map(ShareSetTitleChange.set) ?? .clear
    }

    // MARK: changing the draft

    /// Takes a file out; nothing happens at 2 files (a link needs 2: revoke it instead).
    public mutating func remove(_ id: String) {
        guard canRemove else { return }
        items.removeAll { $0 == id }
    }

    /// A drag in the list (`List.onMove`).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items = Self.moving(items, fromOffsets: source, toOffset: destination)
    }

    /// `move(fromOffsets:toOffset:)` as SwiftUI's lists mean it (`destination` is an offset in the list before the move),
    /// without SwiftUI.
    static func moving(_ list: [String], fromOffsets source: IndexSet, toOffset destination: Int) -> [String] {
        let picked = source.filter { $0 >= 0 && $0 < list.count }
        guard !picked.isEmpty else { return list }
        let moving = picked.map { list[$0] }
        var rest = list
        for index in picked.sorted(by: >) { rest.remove(at: index) }
        let before = picked.filter { $0 < destination }.count
        let at = Swift.min(Swift.max(0, destination - before), rest.count)
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    /// Appends files in order, skipping ones already in the draft, up to the room left. Answers the ids appended.
    @discardableResult
    public mutating func append(_ ids: [String]) -> [String] {
        var taken: [String] = []
        for id in ids where !items.contains(id) && room > 0 {
            items.append(id)
            taken.append(id)
        }
        return taken
    }

    /// Back to the link as it was.
    public mutating func reset() {
        items = original
        title = originalTitle ?? ""
    }

    static func clean(_ raw: String) -> String? {
        var view = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !(scalar.value < 0x20 || scalar.value == 0x7f) { view.append(scalar) }
        let t = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - the library's "add to link"

/// One picked post as "add to link" sees it: the file that stands for it in a public link, the one for a private link,
/// and every library file the post has (to tell whether a link already holds it).
public struct ShareSetPick: Sendable, Equatable {
    /// `ShareSetRule.fileID(for:)`: nil when the post has no public file.
    public var publicFileID: String?
    /// `ShareSetRule.privateFileID(for:)`: nil when the post has no file at all.
    public var anyFileID: String?
    /// `ShareSetIndex.fileIDs(of:)`.
    public var fileIDs: Set<String>

    public init(publicFileID: String?, anyFileID: String?, fileIDs: Set<String>) {
        self.publicFileID = publicFileID
        self.anyFileID = anyFileID
        self.fileIDs = fileIDs
    }

    public init(item: MediaItem) {
        self.init(
            publicFileID: ShareSetRule.fileID(for: item), anyFileID: ShareSetRule.privateFileID(for: item),
            fileIDs: ShareSetIndex.fileIDs(of: item))
    }
}

/// What the link picker says about one link for the picks.
public enum ShareSetAddVerdict: Sendable, Equatable {
    /// The picks fit: `count` files go in ("6 → 8 files").
    case ready(adding: Int)
    /// Every pick is in the link already.
    case alreadyIn
    /// More new picks than the link has room for.
    case noRoom(room: Int)
    /// A public link, and a new pick has no public file.
    case hasPrivate
}

extension ShareSetRule {
    /// The picks not in `link` yet (none of their files is one of its files), in pick order.
    public static func freshPicks(_ picks: [ShareSetPick], for link: ShareSet) -> [ShareSetPick] {
        let held = Set(link.items.map(\.id))
        return picks.filter { pick in
            var ids = pick.fileIDs
            if let id = pick.publicFileID { ids.insert(id) }
            if let id = pick.anyFileID { ids.insert(id) }
            return ids.isDisjoint(with: held)
        }
    }

    /// The file ids "add to link" appends to `link`: each new pick's public file, or in a private link any file. Picks
    /// with no such file are left out.
    public static func fileIDs(adding picks: [ShareSetPick], to link: ShareSet) -> [String] {
        var seen = Set(link.items.map(\.id))
        var out: [String] = []
        for pick in freshPicks(picks, for: link) {
            guard let id = link.isPrivate ? pick.anyFileID : pick.publicFileID else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// The verdict for one link, in the mockup's order: already in, no room, then a private pick in a public link.
    public static func addVerdict(_ picks: [ShareSetPick], to link: ShareSet, maximum: Int) -> ShareSetAddVerdict {
        let fresh = freshPicks(picks, for: link)
        if fresh.isEmpty { return .alreadyIn }
        let room = Swift.max(0, Swift.max(minimum, maximum) - link.items.count)
        if fresh.count > room { return .noRoom(room: room) }
        if !link.isPrivate, fresh.contains(where: { $0.publicFileID == nil }) { return .hasPrivate }
        let ids = fileIDs(adding: picks, to: link)
        if ids.isEmpty { return .hasPrivate }
        return .ready(adding: ids.count)
    }
}
