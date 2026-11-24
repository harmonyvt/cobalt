import CobaltKit
import Foundation

/// The iPhone's four tabs, its header and its tools list (apple 04-PHASE4 4.1). Lowercase house copy. A tab's own screens keep their
/// own copy tables; this is only what the shell and the two hubs (live, tools) say themselves.
extension Copy {
    enum PhoneNav {
        // the four tabs
        static let capture = "capture", library = "library", live = "live", tools = "tools"

        // the header's gear and the settings sheet it opens
        static let settings = "settings"
        static let settingsHint = "opens settings"
        static let done = "done"

        // live: the segments (what the picker under the bar says)
        static let liveStage = "stage", liveTwitch = "twitch", liveSevenTv = "7tv"
        static let liveSegments = "live view"

        // tools: the list
        static let toolsLinks = "links & collections", toolsLinksNote = "share links, sets and collections"
        static let toolsAssistants = "chat & swarms", toolsAssistantsNote = "ask the library, or send helpers off"
        static let toolsEditor = "video edits", toolsEditorNote = "projects you cut in the editor"
        static let toolsBooru = "booru", toolsBooruNote = "browse tags and save what you find"
        static let toolsNames = "search names", toolsNamesNote = "what the library calls things"
        static let sectionShare = "share", sectionAssistants = "assistants", sectionMake = "make", sectionFind = "find"

        // chat & swarms: the toggle
        static let assistantChat = "chat", assistantSwarms = "swarms"
        static let assistantSegments = "chat or swarms"
        static func swarmsWaiting(_ n: Int) -> String { "swarms · \(n)" }
        static func swarmsWaitingA11y(_ n: Int) -> String { n == 1 ? "swarms, 1 waits for you" : "swarms, \(n) wait for you" }

        // video edits
        static let editsEmpty = "no edits yet"
        static let editsEmptyBody = "pick videos in the library and tap edit to start one."
        static let editsFailed = "can't read your edits"
        static let editsRetry = "try again"
    }
}

extension Symbol {
    enum PhoneNav {
        static let capture = Symbol.save
        static let library = Symbol.library
        static let live = Symbol.stage
        static let tools = "square.grid.2x2"
        static let settings = Symbol.settings
        static let editor = "film.stack"
    }
}
