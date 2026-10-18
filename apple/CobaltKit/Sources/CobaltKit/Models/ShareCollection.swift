import Foundation

// Share link collections (APP-API-CONTRACT section 26): a named folder of gallery links. The wire shape, the errors the
// four routes answer, and the one naming rule the app and the server share.

/// One collection (`GET /share/collections`, `POST`, `PATCH`).
public struct ShareCollection: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The collection's live links (ids of `ShareSet`s), most recently added first. A revoked link drops out on its own.
    public var setIDs: [String]

    public init(id: String, name: String, createdAt: Date, updatedAt: Date, setIDs: [String]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.setIDs = setIDs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt
        case setIDs = "setIds"                 // `set_ids` after convertFromSnakeCase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        setIDs = try c.decodeIfPresent([String].self, forKey: .setIDs) ?? []
    }

    /// Whether the link is in this collection.
    public func contains(_ setID: String) -> Bool { setIDs.contains(setID) }
}

/// What the four collection routes answer when they refuse (mapped from the wire in `HTTPCobaltClient`).
public enum ShareCollectionError: Error, Sendable, Equatable {
    /// `400 error.collection.bad_request`: bad JSON, name or id list.
    case badRequest
    /// `404 error.collection.not_found`: the collection is not (or no longer) there.
    case notFound
    /// `409 error.collection.link_not_found`: these link ids are unknown or revoked; nothing changed.
    case linkNotFound([String])
    /// `409 error.collection.too_many`: 100 collections already.
    case tooMany
    /// `409 error.collection.full`: 200 links already in the collection.
    case full
    /// `409 error.collection.empty`: a reroll with no live links in the collection; nothing changed.
    case empty
    /// `503 error.api.generic`: the server cannot take it right now.
    case unavailable
}

/// What `POST /share/collections/<id>/reroll` answers: the collection with its new link ids (same order) and which
/// old link became which new one (`replaced[old] = new`). Every collection that held an old link now holds the new one
/// in place, so the store swaps the ids in all of them.
public struct ShareCollectionReroll: Sendable, Equatable, Decodable {
    public var collection: ShareCollection
    public var replaced: [String: String]

    public init(collection: ShareCollection, replaced: [String: String]) {
        self.collection = collection
        self.replaced = replaced
    }

    enum CodingKeys: String, CodingKey { case collection, replaced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(ShareCollection.self, forKey: .collection)
        replaced = try c.decodeIfPresent([String: String].self, forKey: .replaced) ?? [:]
    }
}

/// The naming rule of a collection, shared by the sheets' save button and the tests (the server enforces the same).
public enum ShareCollectionRule {
    /// The name the server takes: 1..60 code points after trimming and removing control characters.
    public static let nameLimit = 60
    /// The server's cap on collections.
    public static let collectionLimit = 100
    /// The server's cap on links in one collection.
    public static let linkLimit = 200

    /// Trimmed, control characters removed (U+0000-U+001F, U+007F-U+009F, U+2028, U+2029); nil when empty or over
    /// `nameLimit` code points (the field is capped by the UI, so a too-long name is refused, not cut).
    public static func cleanName(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: continue
            default: scalars.append(s)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.unicodeScalars.count <= nameLimit else { return nil }
        return cleaned
    }
}
