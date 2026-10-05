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
}
