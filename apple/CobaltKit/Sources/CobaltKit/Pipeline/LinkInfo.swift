import Foundation

public struct LinkInfo: Sendable, Equatable {
    public var url: URL
    /// The host's second-level label; "twitter" shows as "x".
    public var service: String
    /// What names the post: the author's handle when the link names one (`@ilokineedsleep` for
    /// `x.com/ilokineedsleep/status/…`, `@user` for TikTok's `/@user/photo/…`), else the last non-empty path
    /// component (the host when the path is empty). A title reads `x · @ilokineedsleep` and `instagram · Ddy0-gpGg5U`
    /// (apple/CONTRACT-GALLERY.md 1.6).
    public var ref: String

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        self.url = url
        let labels = host.lowercased().split(separator: ".").map(String.init)
        let label = labels.count >= 2 ? labels[labels.count - 2] : (labels.first ?? host)
        service = label == "twitter" ? "x" : label
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        ref = Self.handle(service: service, parts: parts) ?? parts.last ?? host
    }

    /// The author the link names, as `@handle`: X and Twitter name theirs first (`/<handle>/status/<id>`; `/i/status/<id>`
    /// has none), TikTok and Threads put `@handle` first.
    static func handle(service: String, parts: [String]) -> String? {
        guard let first = parts.first, parts.count >= 2 else { return nil }
        if first.hasPrefix("@"), first.count > 1 { return first }
        if service == "x", ["status", "statuses"].contains(parts[1].lowercased()), first.lowercased() != "i",
           first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return "@" + first
        }
        return nil
    }

    /// Same rule as `extractFirstUrl` in the API worker: the first `http(s)://` run up to
    /// whitespace / quotes / angle brackets, minus trailing `),.;:!?]}` punctuation.
    public static func firstLink(in text: String) -> URL? {
        guard let range = text.range(of: "https?://[^\\s<>\"'`]+", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var found = String(text[range])
        while let last = found.last, "),.;:!?]}".contains(last) { found.removeLast() }
        guard let url = URL(string: found), LinkInfo(url) != nil else { return nil }
        return url
    }

    /// `firstLink`'s rule for every link in `text`, in order, repeats folded (the same URL once), at most `limit`
    /// (CONTRACT-PARALLEL.md section 4.2). A link glued to the text before it by a newline is still found; one glued by
    /// nothing at all is read up to the next whitespace, like the API reads it.
    ///
    /// A clipboard can hold megabytes: only the first `scanLimit` characters are read (a link cut off by that edge is
    /// dropped with its half word), in one pass of one compiled expression, so the time is linear in what is read and
    /// never grows with the number of links.
    public static func allLinks(in text: String, limit: Int = 20) -> [URL] {
        guard limit > 0, !text.isEmpty else { return [] }
        var scanned = Substring(text)
        if let cut = text.index(text.startIndex, offsetBy: scanLimit, limitedBy: text.endIndex), cut < text.endIndex {
            scanned = text[..<cut]
            if !text[cut].isWhitespace {
                scanned = scanned.lastIndex(where: \.isWhitespace).map { scanned[..<$0] } ?? scanned
            }
        }
        let string = String(scanned)
        let whole = NSRange(string.startIndex..., in: string)
        let ns = string as NSString
        var found: [URL] = []
        var seen = Set<String>()
        linkExpression.enumerateMatches(in: string, options: [], range: whole) { match, _, stop in
            guard let match else { return }
            var candidate = ns.substring(with: match.range)
            while let last = candidate.last, "),.;:!?]}".contains(last) { candidate.removeLast() }
            if let url = URL(string: candidate), LinkInfo(url) != nil, seen.insert(url.absoluteString).inserted {
                found.append(url)
                if found.count >= limit { stop.pointee = true }
            }
        }
        return found
    }

    /// How much of a paste `allLinks` reads (characters).
    public static let scanLimit = 200_000

    private static let linkExpression: NSRegularExpression = {
        // The same expression as `firstLink`; it is a constant, so it always compiles.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "https?://[^\\s<>\"'`]+", options: [.caseInsensitive])
    }()
}
