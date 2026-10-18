import Foundation

/// `GET /library/map` (APP-API-CONTRACT 21, "the map"; keyed): every embedded post with its vector, so the app can lay
/// the library out as a sky map the way the web library does.
public struct LibraryMap: Sendable, Equatable {
    public var model: String
    public var dims: Int
    public var searchEnabled: Bool
    /// Newest first.
    public var posts: [MapPost]
    /// Live posts with no vector yet.
    public var unmapped: Int

    public init(model: String, dims: Int, searchEnabled: Bool, posts: [MapPost], unmapped: Int) {
        self.model = model
        self.dims = dims
        self.searchEnabled = searchEnabled
        self.posts = posts
        self.unmapped = unmapped
    }
}

/// One post on the map.
public struct MapPost: Sendable, Equatable, Identifiable {
    /// The post key (the library's post id).
    public var id: String
    public var title: String?
    /// The text the server embedded: the file names and the link's host and path, joined with " · ".
    public var text: String
    public var imageURL: URL?
    /// When the post was last added to (the wire's `latest`, milliseconds).
    public var latest: Date
    /// The embedding, each component the server's int8 divided by 127 (so the largest is about +-1). Only the direction
    /// matters: the layout normalises it.
    public var vector: [Float]

    public init(id: String, title: String?, text: String, imageURL: URL?, latest: Date, vector: [Float]) {
        self.id = id
        self.title = title
        self.text = text
        self.imageURL = imageURL
        self.latest = latest
        self.vector = vector
    }

    /// `v8` (base64 of signed bytes) as floats, each divided by 127. Nil for text that is not base64 or is empty.
    public static func decodeVector(base64: String) -> [Float]? {
        var text = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        // btoa / Buffer output is padded, but tolerate a missing pad
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), !data.isEmpty else { return nil }
        return data.map { Float(Int8(bitPattern: $0)) / 127 }
    }

    /// The vector as the server sends it: signed bytes scaled so the largest component is +-127, in base64 (the
    /// preview server and the tests make their wire with this).
    public static func encodeVector(_ vector: [Float]) -> String {
        let peak = vector.reduce(Float(0)) { max($0, abs($1)) }
        let scale = peak > 0 ? 127 / peak : 0
        let bytes = vector.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 * scale).rounded())))) }
        return Data(bytes).base64EncodedString()
    }
}

extension LibraryMap {
    /// The answer body: `{"status":"success","model","dims","search_enabled","posts":[…],"unmapped"}`. A post that
    /// lacks its key, its time or a readable vector is dropped, the rest stay. Throws when the body is not that
    /// object, or its status is not "success".
    static func decode(_ data: Data) throws -> LibraryMap {
        let wire = try CobaltJSON.decoder().decode(Wire.self, from: data)
        if let status = wire.status, status != "success" {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: status))
        }
        return LibraryMap(
            model: wire.model ?? "", dims: wire.dims ?? 0, searchEnabled: wire.searchEnabled ?? false,
            posts: wire.posts.compactMap { $0.value?.post }, unmapped: max(0, wire.unmapped ?? 0))
    }

    private struct Wire: Decodable {
        var status: String?
        var model: String?
        var dims: Int?
        var searchEnabled: Bool?
        var posts: [Lossy<WirePost>]
        var unmapped: Int?
    }

    private struct WirePost: Decodable {
        var postKey: String
        var title: String?
        var text: String?
        var imageUrl: String?
        var latest: Double
        var v8: String

        var post: MapPost? {
            guard !postKey.isEmpty, latest.isFinite, let vector = MapPost.decodeVector(base64: v8) else { return nil }
            return MapPost(
                id: postKey, title: title, text: text ?? "", imageURL: imageUrl.flatMap { URL(string: $0) },
                latest: Date(timeIntervalSince1970: latest / 1000), vector: vector)
        }
    }
}
