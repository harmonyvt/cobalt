import Foundation

/// The `:word` the keyboard is completing, read from the text right before the cursor.
public enum EmoteTrigger {
    public static let maxQuery = 64

    /// The word after the last ":" before the cursor, "" for a bare ":". Nil when nothing is being completed:
    /// the ":" starts the text or follows whitespace (so "12:30" and "https:" are not triggers), and only
    /// letters, digits, "_" or "-" follow it.
    public static func query(before text: String?) -> String? {
        guard let text, let colon = text.lastIndex(of: ":") else { return nil }
        let word = text[text.index(after: colon)...]
        guard word.count <= maxQuery, word.allSatisfy(isWordCharacter) else { return nil }
        if colon > text.startIndex, !text[text.index(before: colon)].isWhitespace { return nil }
        return String(word)
    }

    static func isWordCharacter(_ ch: Character) -> Bool {
        (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" || ch == "-"
    }
}

/// Emotes the keyboard used, newest first. Pure: the keyboard keeps the list in its own defaults.
public enum EmoteRecents {
    public static let limit = 30

    public static func adding(_ hit: EmoteHit, to list: [EmoteHit]) -> [EmoteHit] {
        var next = list.filter { $0.id != hit.id }
        next.insert(hit, at: 0)
        return Array(next.prefix(limit))
    }

    /// Names starting with the query, then names containing it, each kept in list order. Case-insensitive.
    /// An empty query is the whole list.
    public static func matching(_ query: String, in list: [EmoteHit]) -> [EmoteHit] {
        let q = query.lowercased()
        guard !q.isEmpty else { return list }
        let starts = list.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = list.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return starts + contains
    }

    /// The bar above the keys: matching recents first, then the search hits not already shown. A recent takes
    /// the search's library link when it has none of its own (saved elsewhere since).
    public static func suggestions(query: String, recents: [EmoteHit], found: [EmoteHit]) -> [EmoteHit] {
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = matching(query, in: recents).map { recent -> EmoteHit in
            guard recent.libraryURL == nil, let fresh = byID[recent.id], fresh.libraryURL != nil else { return recent }
            var next = recent
            next.libraryID = fresh.libraryID
            next.libraryURL = fresh.libraryURL
            return next
        }
        var seen = Set(out.map(\.id))
        for hit in found where seen.insert(hit.id).inserted { out.append(hit) }
        return out
    }

    public static func decode(_ data: Data?) -> [EmoteHit] {
        guard let data, let list = try? JSONDecoder().decode([EmoteHit].self, from: data) else { return [] }
        return Array(list.prefix(limit))
    }

    public static func encode(_ list: [EmoteHit]) -> Data? {
        try? JSONEncoder().encode(Array(list.prefix(limit)))
    }
}
