import Foundation

public struct LinkInfo: Sendable, Equatable {
    public var url: URL
    /// The host's second-level label; "twitter" shows as "x".
    public var service: String
    /// The last non-empty path component (the host when the path is empty).
    public var ref: String

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        self.url = url
        let labels = host.lowercased().split(separator: ".").map(String.init)
        let label = labels.count >= 2 ? labels[labels.count - 2] : (labels.first ?? host)
        service = label == "twitter" ? "x" : label
        let last = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }.last
        ref = last ?? host
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
    public static func allLinks(in text: String, limit: Int = 20) -> [URL] {
        guard limit > 0 else { return [] }
        var found: [URL] = []
        var seen = Set<String>()
        var rest = text[...]
        while found.count < limit, let range = rest.range(of: "https?://[^\\s<>\"'`]+", options: [.regularExpression, .caseInsensitive]) {
            var candidate = String(rest[range])
            rest = rest[range.upperBound...]
            while let last = candidate.last, "),.;:!?]}".contains(last) { candidate.removeLast() }
            guard let url = URL(string: candidate), LinkInfo(url) != nil, seen.insert(url.absoluteString).inserted else { continue }
            found.append(url)
        }
        return found
    }
}
