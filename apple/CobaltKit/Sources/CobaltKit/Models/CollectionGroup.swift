import Foundation

// Collection sets (APP-API-CONTRACT section 28): a named group of share link collections, called a "set" in the app.
// Internally it is a `CollectionGroup` because a `ShareSet` is already a gallery link. The wire shape, the errors the
// four routes answer, and the naming rule (the same as a collection's).

/// One group (`GET /share/groups`, `POST`, `PATCH`).
public struct CollectionGroup: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The group's collections (ids of `ShareCollection`s), most recently added first. A deleted collection drops out on
    /// its own.
    public var collectionIDs: [String]

    public init(id: String, name: String, createdAt: Date, updatedAt: Date, collectionIDs: [String]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.collectionIDs = collectionIDs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt
        case collectionIDs = "collectionIds"   // `collection_ids` after convertFromSnakeCase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        collectionIDs = try c.decodeIfPresent([String].self, forKey: .collectionIDs) ?? []
    }

    /// Whether the collection is in this group.
    public func contains(_ collectionID: String) -> Bool { collectionIDs.contains(collectionID) }
}

/// What the four group routes answer when they refuse (mapped from the wire in `HTTPCobaltClient`).
public enum CollectionGroupError: Error, Sendable, Equatable {
    /// `400 error.group.bad_request`: bad JSON, name or id list.
    case badRequest
    /// `404 error.group.not_found`: the group is not (or no longer) there.
    case notFound
    /// `409 error.group.collection_not_found`: these collection ids are unknown (deleted); nothing changed.
    case collectionNotFound([String])
    /// `409 error.group.too_many`: 100 groups already.
    case tooMany
    /// `409 error.group.full`: 100 collections already in the group.
    case full
    /// `503 error.api.generic`: the server cannot take it right now.
    case unavailable
}

/// The naming rule and caps of a group (the server enforces the same). The name rule is a collection's.
public enum CollectionGroupRule {
    /// The name the server takes: 1..60 code points after trimming and removing control characters.
    public static let nameLimit = ShareCollectionRule.nameLimit
    /// The server's cap on groups.
    public static let groupLimit = 100
    /// The server's cap on collections in one group.
    public static let collectionLimit = 100

    /// Trimmed, control characters removed; nil when empty or over `nameLimit` code points.
    public static func cleanName(_ raw: String) -> String? { ShareCollectionRule.cleanName(raw) }
}
