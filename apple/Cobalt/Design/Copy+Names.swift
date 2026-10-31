import CobaltKit
import Foundation

/// Copy for search names (APP-API-CONTRACT 48.6; all new, lowercase, terse): library › names, the name screen, the detail's
/// names row and a post's "this is…" menu. Plain values only (counts, strings, CobaltKit types), since `Cobalt/Design` is
/// compiled into the extensions too.
extension Copy {
    enum Names {
        // MARK: the library's menu

        static let menuItem = "names"

        // MARK: the list

        static let title = "names"
        static let hint = "words you've taught search. a search that says one of them looks for what it means."
        static let tip = "tip: hold any post in the library and pick \"this is…\" to add it to a name."
        static let empty = "no names yet. teach search a word: who Lia is, what capy means."
        static let loading = "loading names…"
        static let newName = "new name"
        static let delete = "delete name"
        static let retry = "try again"
        static let done = "done"
        static func on(_ name: String) -> String { "use \(name) in search" }

        /// "14 posts · 2 other words".
        static func summary(_ name: TaughtName) -> String {
            var parts = [posts(name.posts)]
            if !name.aliases.isEmpty { parts.append(name.aliases.count == 1 ? "1 other word" : "\(name.aliases.count) other words") }
            if !name.enabled { parts.append("off") }
            return parts.joined(separator: " · ")
        }

        /// The meaning line: a name with no examples is a plain "same as" word.
        static func meaningLine(_ name: TaughtName) -> String {
            name.yes.isEmpty && name.no.isEmpty ? "same as: \(name.meaning)" : name.meaning
        }

        static func posts(_ n: Int) -> String { n == 1 ? "1 post" : "\(n) posts" }

        // MARK: the name screen

        static let newTitle = "new name"
        static let namePlaceholder = "a word, like Lia"
        static let nameA11y = "name"
        static let alsoCalled = "also called"
        static let addAlias = "+ also called"
        static let aliasPlaceholder = "another word"
        static func removeAlias(_ word: String) -> String { "remove \(word)" }
        static let means = "means"
        static let meaningPlaceholder = "what it means, in a few words: pink-haired cat girl with cat ears"
        static let meaningA11y = "what the name means"
        static func thisIs(_ name: String) -> String { "this is \(display(name))" }
        static func notName(_ name: String) -> String { "not \(display(name))" }
        static let noExamples = "nothing yet. tap a post below to make it an example."
        static let noNots = "nothing yet. tap a post below twice to mark it."
        static let unmark = "take the mark off"
        static func listenTo(_ strength: Double) -> String { "listen to · \(percent(strength)) examples" }
        static let theWords = "the words"
        static let theExamples = "the examples"
        static let strengthA11y = "listen to the words or the examples"
        static func cutoff(_ value: Double) -> String { "cut-off · \(score(value))" }
        static let morePosts = "more posts"
        static let stricter = "stricter"
        static let cutoffA11y = "cut-off"
        static func whosIn(_ n: Int) -> String { "who's in · \(posts(n))" }
        static let whosInHint = "tap a post: example, then not, then back."
        static let cutLine = "cut-off"
        static let example = "example"
        static let notIt = "not"
        static let previewing = "looking…"
        static let previewFailed = "couldn't look just now."
        static let notEmbedded = "the meaning isn't read yet, so this uses the examples alone. it's read again within 15 minutes."
        static let noPreview = "write what it means to see who's in."
        static func save(_ name: String) -> String { name.isEmpty ? "save" : "save \(display(name))" }
        static let saving = "saving…"
        static let saved = "saved"
        static let enabled = "use in search"

        static func problem(_ problem: SearchNameSaveProblem) -> String {
            switch problem {
            case .taken(word: let word?): return "\"\(word)\" is already another name's word."
            case .taken(word: nil): return "one of these words is already another name's."
            case .invalid: return "give it a name (up to 40 letters) and what it means (up to 300)."
            case .tooMany: return "that's 100 names, the most there can be. delete one first."
            case .notFound: return "this name was deleted somewhere else."
            case .failed(let failure?): return Copy.failure(failure)
            case .failed(nil): return "couldn't save it. try again."
            }
        }

        static func rowA11y(_ title: String, mark: NameMark?, carries: Bool, score: Double) -> String {
            let state: String
            switch mark {
            case .yes?: state = "example"
            case .no?: state = "marked not"
            case nil: state = carries ? "in, \(Copy.Names.score(score))" : "out, \(Copy.Names.score(score))"
            }
            return "\(title), \(state)"
        }
        static let rowA11yHint = "cycles example, not, no mark"

        // MARK: try a search

        static let trySearch = "try a search"
        static let tryPlaceholder = "Lia dancing"
        static let tryRun = "search"
        static let tryHint = "uses the saved names."
        static let without = "without names"
        static let with = "with names"
        static func used(_ names: [SearchNameRef]) -> String {
            names.isEmpty ? "no name was said." : "used: " + names.map(\.name).joined(separator: ", ")
        }
        static let nothingFound = "nothing"
        static let tryFailed = "couldn't search just now."

        // MARK: the detail's names row

        static let detailRow = "names"
        static func detailChip(_ name: PostName) -> String {
            switch name.mark {
            case .yes?: return "\(name.name) · example"
            case .no?: return "\(name.name) · not"
            case nil: return name.score.map { "\(name.name) \(score($0))" } ?? name.name
            }
        }
        static func notThis(_ name: String) -> String { "not \(display(name))" }
        static func notThisA11y(_ name: String) -> String { "mark this post as not \(display(name))" }
        static func openName(_ name: String) -> String { "open \(display(name))" }
        static let detailNone = "no name fits this post."
        static let detailFailed = "couldn't read its names."
        static let markFailed = "couldn't change the mark. try again."

        // MARK: a post's menu

        static let thisIsMenu = "this is…"
        static let newNameFromPost = "new name…"
        static func markedYes(_ name: String) -> String { "an example of \(display(name)) now" }
        static func markedNo(_ name: String) -> String { "marked not \(display(name))" }
        static func unmarked(_ name: String) -> String { "no longer an example of \(display(name))" }

        // MARK: values

        static func score(_ value: Double) -> String { String(format: "%.2f", value) }
        static func percent(_ value: Double) -> String { "\(Int((max(0, min(1, value)) * 100).rounded()))%" }
        /// A name as typed: it is the owner's word, so its case stays.
        static func display(_ name: String) -> String {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "it" : t
        }
    }
}
