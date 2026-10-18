import Foundation

/// A reply's Markdown cut into the blocks the chat screen draws (APP-API-CONTRACT 27: `text` is Markdown). SwiftUI's
/// `Text` renders inline Markdown (bold, italic, `code`, links) but flattens paragraphs, lists and fences, so the blocks
/// are found here, without a dependency, and each block's text is left for `AttributedString(markdown:)`.
///
/// Understood: paragraphs (a line break inside one is kept), `#` headings, `-` `*` `+` bullets and `1.` numbered items (nested by
/// indent), `>` quotes, ``` fences (an unclosed fence, as a half-streamed reply has, runs to the end), and `---`. Anything else is
/// a paragraph. It never fails and never drops text.
public enum ChatBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ChatListItem])
    case quote(String)
    case code(language: String?, text: String)
    case rule
}

public struct ChatListItem: Sendable, Equatable {
    /// `•`, or the item's own number with its dot (`3.`).
    public var marker: String
    public var text: String
    /// 0 for the outer list, 1 for items nested once, up to 3.
    public var level: Int

    public init(marker: String, text: String, level: Int = 0) {
        self.marker = marker
        self.text = text
        self.level = level
    }
}

public enum ChatMarkdown {
    public static func blocks(_ markdown: String) -> [ChatBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [ChatBlock] = []
        var paragraph: [String] = []
        var list: [ChatListItem] = []
        var quote: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { out.append(.list(list)); list = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // a fence: everything to the closing fence (or the end) is code
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1                                          // the closing fence
                out.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let heading = Self.heading(trimmed) {
                flush()
                out.append(heading)
            } else if Self.isRule(trimmed) {
                flush()
                out.append(.rule)
            } else if let item = Self.listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                list.append(item)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !list.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") {
                // an indented continuation of the last item
                list[list.count - 1].text += "\n" + trimmed
            } else {
                if !list.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(trimmed)
            }
            i += 1
        }
        flush()
        return out
    }

    private static func heading(_ trimmed: String) -> ChatBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes <= 6, trimmed.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        return compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" }
    }

    /// `- item`, `* item`, `+ item`, `3. item` (or `3) item`), indented two spaces (or a tab) per level.
    private static func listItem(_ line: String) -> ChatListItem? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 2 : 1
            rest = rest.dropFirst()
        }
        let level = min(3, indent / 2)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ChatListItem(marker: "•", text: text, level: level)
        }
        let digits = rest.prefix { $0.isNumber && $0.isASCII }
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : ChatListItem(marker: "\(digits).", text: text, level: level)
            }
        }
        return nil
    }
}
