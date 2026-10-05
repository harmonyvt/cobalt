import Foundation

/// What `DELETE /library/items/<id>/post` answers (CONTRACT-MEDIA 6.1): `200`, and the `502
/// error.library.partial` body, which carries the same fields. Idempotent on the server, so a retry
/// of a partial result is always safe.
public struct PostDeleteResult: Sendable, Equatable, Decodable {
    public var deletedFiles: Int                           // `deleted.files`
    public var deletedBytes: Int64                         // `deleted.bytes`
    public var remaining: [String]                         // file ids still live; [] on success

    public init(deletedFiles: Int, deletedBytes: Int64, remaining: [String]) {
        self.deletedFiles = deletedFiles
        self.deletedBytes = deletedBytes
        self.remaining = remaining
    }

    enum CodingKeys: String, CodingKey { case deleted, remaining }
    struct Counts: Decodable { var files: Int?; var bytes: Int64? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let counts = try c.decodeIfPresent(Counts.self, forKey: .deleted)
        deletedFiles = counts?.files ?? 0
        deletedBytes = counts?.bytes ?? 0
        remaining = try c.decodeIfPresent([String].self, forKey: .remaining) ?? []
    }
}

/// How "delete everything" ended (CONTRACT-MEDIA 1.12, 4.2).
public enum DeleteOutcome: Sendable, Equatable {
    /// Nothing is left on the server for this media. Through the keyed route the whole local media is
    /// gone too; through the per-webp fallback only the local copies of the deleted webps are (a local
    /// original is never removed by a call that did not delete it on the server).
    case done
    /// Some files are still on the server; the call is idempotent, so retrying is safe.
    case partial(remaining: Int)
    /// The older-server route finished: the webps are gone, and these stay on the server (the app
    /// cannot delete them there; "delete those on the web").
    case leftOnServer(hostedLink: Bool, privateCopy: Bool)
}
