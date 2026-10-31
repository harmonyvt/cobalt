import Foundation

/// Copy for a reply's activity row (the folded trail of code steps and tool calls), the reply's actions, helpers on a
/// reply, and the composer's attach sheet. Lowercase, like the rest of chat.
extension Copy {
    enum ChatActivity {
        static func searches(_ n: Int) -> String { n == 1 ? "1 search" : "\(n) searches" }
        static func looked(_ n: Int) -> String { n == 1 ? "1 post looked at" : "\(n) posts looked at" }
        static func edits(_ n: Int) -> String { n == 1 ? "1 edit" : "\(n) edits" }
        static func jobs(_ n: Int) -> String { n == 1 ? "1 thing made" : "\(n) things made" }
        static func links(_ n: Int) -> String { n == 1 ? "1 link" : "\(n) links" }
        static func emotes(_ n: Int) -> String { n == 1 ? "1 emote search" : "\(n) emote searches" }
        static func box(_ n: Int) -> String { n == 1 ? "1 box run" : "\(n) box runs" }
        static func folders(_ n: Int) -> String { n == 1 ? "1 collection change" : "\(n) collection changes" }
        static func helpers(_ n: Int) -> String { n == 1 ? "1 helper" : "\(n) helpers" }
        static func saved(_ n: Int) -> String { n == 1 ? "1 save" : "\(n) saves" }
        static func calls(_ n: Int) -> String { n == 1 ? "1 call" : "\(n) calls" }
        static func failed(_ n: Int) -> String { n == 1 ? "1 failed" : "\(n) failed" }
        static func seconds(_ ms: Int) -> String { ms < 10_000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms / 1000) s" }
        static let ranCode = "ran code"
        static let working = "working…"
        static func doing(_ op: String) -> String { "\(op)…" }
        static let open = "show what it did"
        static let close = "hide what it did"
        static func a11y(_ title: String, _ sub: String, open: Bool) -> String {
            "\(title), \(sub), \(open ? "open" : "closed")"
        }

        // the reply's actions
        static let copy = "copy reply"
        static let again = "ask again"

        // helpers on the reply that started them
        static let helpersA11y = "helpers this reply started"

        // the composer's attach sheet
        static let attach = "attach posts"
        static let attachTitle = "attach"
        static func attachConfirm(_ n: Int) -> String { n == 0 ? "attach" : "attach \(n)" }
        static let attachCancel = "cancel"
        static let attachSearch = "search titles"
        static let attachEmpty = "nothing loaded in your library yet"
        static func attachFull(_ limit: Int) -> String { "\(limit) posts at most" }
    }
}
