import Foundation

// Finding a library picture's booru post (APP-API-CONTRACT 72.11, 72.12). With the owner's Danbooru key the device asks
// Danbooru's own picture search; without one (or when it refuses) it asks iqdb.org (anonymous, about 40 s under load), fetches the posts it names from Danbooru,
// and lets the server keep the general ones (POST /booru/filter). Linking sends Danbooru's post object to the server, which
// checks it is general again and gives the library post the Danbooru page as its link.

/// One booru post a picture search found.
public struct BooruMatch: Sendable, Equatable, Identifiable {
    public var post: BooruPost
    /// iqdb's similarity, 0...100.
    public var similarity: Int
    /// Danbooru's own post object (JSON), what `PUT /library/items/<id>/booru` takes.
    public var raw: Data

    public var id: Int { post.id }
    /// Close enough to link without asking (72.11).
    public var isSure: Bool { similarity >= BooruMatch.sure }
    public static let sure = 90
    /// Below this iqdb's matches are other pictures.
    public static let floor = 60

    public init(post: BooruPost, similarity: Int, raw: Data = Data("{}".utf8)) {
        self.post = post
        self.similarity = similarity
        self.raw = raw
    }
}

/// The owner's own Danbooru account (72.12): a login and an API key, kept in the keychain on this device only (never sent
/// to capystore's server). With one, a picture search asks Danbooru itself (seconds, its live index) and falls back to
/// iqdb.org when Danbooru refuses.
public struct DanbooruAccount: Sendable, Equatable {
    public var login: String
    public var apiKey: String

    public init(login: String, apiKey: String) {
        self.login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let loginAccount = "danbooru.login"
    static let keyAccount = "danbooru.api_key"

    public static func load(_ keychain: Keychain = .shared) -> DanbooruAccount? {
        guard let login = keychain.string(for: loginAccount), let key = keychain.string(for: keyAccount),
              !login.isEmpty, !key.isEmpty else { return nil }
        return DanbooruAccount(login: login, apiKey: key)
    }

    public func save(_ keychain: Keychain = .shared) throws {
        try keychain.set(login, for: Self.loginAccount)
        try keychain.set(apiKey, for: Self.keyAccount)
    }

    public static func clear(_ keychain: Keychain = .shared) throws {
        try keychain.set(nil, for: loginAccount)
        try keychain.set(nil, for: keyAccount)
    }

    /// HTTP basic auth, Danbooru's documented way to send a login and API key.
    var authorization: String { "Basic " + Data("\(login):\(apiKey)".utf8).base64EncodedString() }

    /// Asks Danbooru who this is (`/profile.json`): the account's name, or a code (`error.booru.bad_key`, a network code).
    public func check() async throws -> String {
        var req = URLRequest(url: URL(string: "https://danbooru.donmai.us/profile.json")!, timeoutInterval: 15)
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("capystore/1.0 (private booru tab)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = o["name"] as? String else {
                throw CobaltError.api(code: "error.booru.bad_key", httpStatus: status)
            }
            return name
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
    }

    /// Danbooru's picture search with this account: a multipart POST of the picture to `/iqdb_queries.json`. Its answer is
    /// a list of `{post_id, score, post}`; the posts and their similarity, best first, at or above `floor`.
    func search(jpeg: Data, floor: Int = BooruMatch.floor) async throws -> [(post: Int, similarity: Int, object: [String: Any]?)] {
        let boundary = "capystore-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://danbooru.donmai.us/iqdb_queries.json")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("capystore/1.0 (private booru tab)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"search[file]\"; filename=\"picture.jpg\"")
        line("Content-Type: image/jpeg")
        line("")
        body.append(jpeg)
        line("")
        line("--\(boundary)--")
        req.httpBody = body
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CobaltError.api(code: status == 401 || status == 403 ? "error.booru.bad_key" : "error.booru.search_failed", httpStatus: status)
        }
        return Self.parse(list, floor: floor)
    }

    static func parse(_ list: [[String: Any]], floor: Int = BooruMatch.floor) -> [(post: Int, similarity: Int, object: [String: Any]?)] {
        var out: [(post: Int, similarity: Int, object: [String: Any]?)] = []
        var seen = Set<Int>()
        for r in list {
            let object = r["post"] as? [String: Any]
            guard let id = (r["post_id"] as? Int) ?? (object?["id"] as? Int), let score = (r["score"] as? NSNumber)?.doubleValue else { continue }
            let similarity = Int(score.rounded())
            guard similarity >= floor, similarity <= 100, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append((id, similarity, object))
        }
        return out.sorted { $0.similarity > $1.similarity }
    }
}

/// iqdb.org: the request and the answer (HTML).
public enum Iqdb {
    public static let url = URL(string: "https://iqdb.org/")!
    /// iqdb takes JPEG, PNG or GIF up to 8192 KB and 7500 px a side.
    public static let maxBytes = 8 * 1024 * 1024

    /// A multipart POST of the picture, Danbooru's index only (`service[]=1`).
    public static func request(jpeg: Data, boundary: String = "capystore-\(UUID().uuidString)") -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("capystore/1.0 (private booru tab)", forHTTPHeaderField: "User-Agent")
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"service[]\"")
        line("")
        line("1")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"picture.jpg\"")
        line("Content-Type: image/jpeg")
        line("")
        body.append(jpeg)
        line("")
        line("--\(boundary)--")
        req.httpBody = body
        return req
    }

    /// The Danbooru posts on the page with their similarity, best first, each post once, at or above `floor`.
    public static func parse(html: String, floor: Int = BooruMatch.floor) -> [(post: Int, similarity: Int)] {
        var out: [(post: Int, similarity: Int)] = []
        var seen = Set<Int>()
        for table in html.components(separatedBy: "<table").dropFirst() {
            guard let post = firstInt(in: table, pattern: #"danbooru\.donmai\.us/posts/(\d+)"#),
                  let similarity = firstInt(in: table, pattern: #"(\d{1,3})% similarity"#),
                  similarity >= floor, similarity <= 100, !seen.contains(post) else { continue }
            seen.insert(post)
            out.append((post, similarity))
        }
        return out.sorted { $0.similarity > $1.similarity }
    }

    private static func firstInt(in s: String, pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }
}

extension HTTPCobaltClient {
    private static let iqdbSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 150
        return URLSession(configuration: c)
    }()

    public func booruFind(jpeg: Data) async throws -> [BooruMatch] {
        guard jpeg.count <= Iqdb.maxBytes else { throw CobaltError.api(code: "error.booru.too_large", httpStatus: 413) }
        // the owner's Danbooru account first (72.12): fast and up to date; iqdb.org when Danbooru refuses or fails
        if let account = DanbooruAccount.load() {
            if let found = try? await account.search(jpeg: jpeg) {
                return try await matches(Array(found.prefix(10)))
            }
        }
        return try await matches(try await iqdbSearch(jpeg: jpeg))
    }

    private func iqdbSearch(jpeg: Data) async throws -> [(post: Int, similarity: Int, object: [String: Any]?)] {
        let html: String
        do {
            let (data, response) = try await Self.iqdbSession.data(for: Iqdb.request(jpeg: jpeg))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw CobaltError.api(code: "error.booru.search_failed", httpStatus: status) }
            html = String(decoding: data, as: UTF8.self)
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
        return Iqdb.parse(html: html).prefix(10).map { ($0.post, $0.similarity, nil) }
    }

    /// The found posts as matches: Danbooru's post objects (fetched when the search did not carry them), general only.
    private func matches(_ found: [(post: Int, similarity: Int, object: [String: Any]?)]) async throws -> [BooruMatch] {
        guard !found.isEmpty else { return [] }
        var objects = found.compactMap(\.object)
        let missing = found.filter { $0.object == nil }.map(\.post)
        if !missing.isEmpty {
            // one `id:` list is one tag
            let (body, status) = try await Self.danbooruGet("posts.json", [
                URLQueryItem(name: "tags", value: "id:" + missing.map(String.init).joined(separator: ",")),
                URLQueryItem(name: "limit", value: String(missing.count)),
            ])
            guard (200..<300).contains(status), let list = body as? [[String: Any]] else {
                throw CobaltError.api(code: "error.booru.upstream", httpStatus: status == 0 ? 502 : status)
            }
            objects += list
        }
        let trimmed = objects.map { $0.filter { Self.danbooruKeys.contains($0.key) } }
        var rawByID: [Int: Data] = [:]
        for p in trimmed {
            if let id = p["id"] as? Int, let d = try? JSONSerialization.data(withJSONObject: p) { rawByID[id] = d }
        }
        // the server keeps the general ones (72.9)
        struct Wire: Decodable { var posts: [BooruPost] }
        let req = try makeRequest("POST", "/booru/filter", keyed: true, timeout: 25)
        let (data, http) = try await send(req, body: try JSONSerialization.data(withJSONObject: ["posts": trimmed, "level": "g"]))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        guard let w = try? CobaltJSON.decoder().decode(Wire.self, from: data) else { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
        let similarity = Dictionary(found.map { ($0.post, $0.similarity) }, uniquingKeysWith: max)
        return w.posts
            .compactMap { p in similarity[p.id].map { BooruMatch(post: p, similarity: $0, raw: rawByID[p.id] ?? Data("{}".utf8)) } }
            .sorted { $0.similarity > $1.similarity }
    }

    public func booruLink(item: String, match: BooruMatch) async throws -> BooruCredit {
        struct Wire: Decodable {
            struct Credit: Decodable { var page: URL; var artist: String?; var source: String?; var title: String?; var postedAt: Int?; var favs: Int? }
            var credit: Credit
        }
        guard let post = try? JSONSerialization.jsonObject(with: match.raw) else { throw CobaltError.invalidResponse(httpStatus: 0) }
        let req = try makeRequest("PUT", "/library/items/\(item)/booru", keyed: true, timeout: 20)
        let (data, http) = try await send(req, body: try JSONSerialization.data(withJSONObject: ["post": post]))
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        guard let c = try? CobaltJSON.decoder().decode(Wire.self, from: data).credit else { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
        return BooruCredit(page: c.page, artist: c.artist, source: c.source, title: c.title, postedAt: c.postedAt, favs: c.favs)
    }
}
