import Foundation

/// The words that name a group of posts, a port of the web's `wordsOf` / `keywords` (page.html 1330 to 1367 and 1573 to
/// 1581): each post's title and text are cut into lower-case words (the link's host dropped, it would only name the
/// site), and a group is labelled with the words most of its posts share, weighted by how rare the word is across the
/// whole library (tf-idf).
public struct SkyWords: Sendable {
    /// The distinct words of each post, in the order they first appear.
    public let words: [[String]]
    private let documentFrequency: [String: Int]

    public init(posts: [MapPost]) {
        var df: [String: Int] = [:]
        let all = posts.map { Self.words(of: $0) }
        for list in all { for w in list { df[w, default: 0] += 1 } }
        self.words = all
        self.documentFrequency = df
    }

    /// The `max` best keywords for the posts at `members` (indices into the posts this was made from). With 4 or more
    /// posts a word must be in at least 2 of them; ties break alphabetically.
    public func keywords(of members: [Int], max count: Int) -> [String] {
        guard !members.isEmpty else { return [] }
        var tf: [String: Int] = [:]
        for m in members where words.indices.contains(m) { for w in words[m] { tf[w, default: 0] += 1 } }
        let minCount = members.count >= 4 ? 2 : 1
        let n = Double(words.count)
        let scored = tf.filter { $0.value >= minCount }.map { w, c -> (word: String, score: Double) in
            let df = Double(documentFrequency[w] ?? 0)
            return (w, Double(c) / Double(members.count) * log((n + 1) / (df + 1) + 1))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
            .prefix(count)
            .map(\.word)
    }

    // MARK: - Words of one post

    /// Words that name nothing: the web's `STOP` list (page.html 1331 to 1334), verbatim.
    static let stop: Set<String> = Set((
        "the and for with this that you your from are was but not all have has its it's our out who what when how why " +
        "com www http https status video videos mp4 mov gif webp jpg jpeg png heic heif img image images clip clips file files " +
        "untitled photo photos watch html php reel reels post posts share amp utm source original saved upload copy new " +
        "final edit edited export trim trimmed").split(separator: " ").map(String.init))

    /// `wordsOf` (page.html 1357): the title and the text split at " · ", the host stripped from each part, then the
    /// words of 3 to 24 letters or digits that are not stop words and hold no digit, each once.
    static func words(of post: MapPost) -> [String] {
        let joined = (post.title ?? "") + " · " + post.text
        let text = joined.components(separatedBy: " · ").map { strippingHost($0) }.joined(separator: " ").lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for token in tokens(text) {
            let length = token.utf16.count
            if length < 3 || length > 24 || stop.contains(token) || token.unicodeScalars.contains(where: { ("0"..."9").contains($0) }) {
                continue
            }
            if seen.insert(token).inserted { out.append(token) }
        }
        return out
    }

    /// `seg.replace(/^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(?=\/|$)/i, " ")`: a leading host name ("www.instagram.com")
    /// followed by a slash or the end becomes a space. Written by hand: the pattern can only match the whole run of
    /// host characters at the start, so there is nothing to backtrack over.
    static func strippingHost(_ segment: String) -> String {
        let scalars = Array(segment.unicodeScalars)
        var end = 0
        func isHostScalar(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x41 && s.value <= 0x5A)
                || (s.value >= 0x30 && s.value <= 0x39) || s == "-" || s == "."
        }
        while end < scalars.count, isHostScalar(scalars[end]) { end += 1 }
        guard end > 0, end == scalars.count || scalars[end] == "/" else { return segment }
        let labels = String(String.UnicodeScalarView(scalars[0..<end])).components(separatedBy: ".")
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return segment }
        let tld = labels[labels.count - 1].unicodeScalars
        guard tld.count >= 2, tld.allSatisfy({ ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x41 && $0.value <= 0x5A) }) else {
            return segment
        }
        return " " + String(String.UnicodeScalarView(scalars[end...]))
    }

    /// Split at everything that is not a letter or a number (Unicode `\p{L}` and `\p{N}`).
    private static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if isLetterOrNumber(s) {
                current.append(s)
            } else if !current.isEmpty {
                out.append(String(current)); current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    private static func isLetterOrNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}
