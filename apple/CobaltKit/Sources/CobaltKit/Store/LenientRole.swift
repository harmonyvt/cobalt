import Foundation

/// A `GalleryRole?` on disk that never makes its container unreadable: a role this build does not know (a later build
/// wrote it) reads as none, and a missing key reads as none. The offline index, a file's tag and the download queue
/// all carry one; a single record from the future must not turn the whole index (or a kept file) into "not cobalt's".
@propertyWrapper
struct LenientRole: Codable, Equatable, Sendable {
    var wrappedValue: GalleryRole?

    init(wrappedValue: GalleryRole?) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        wrappedValue = (try? decoder.singleValueContainer().decode(GalleryRole.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    /// A missing key (an index written before galleries) is no role.
    func decode(_ type: LenientRole.Type, forKey key: Key) throws -> LenientRole {
        try decodeIfPresent(type, forKey: key) ?? LenientRole(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    /// No role writes no key, as before.
    mutating func encode(_ value: LenientRole, forKey key: Key) throws {
        if let role = value.wrappedValue { try encode(role, forKey: key) }
    }
}
