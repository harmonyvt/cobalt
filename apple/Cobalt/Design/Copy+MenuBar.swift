import Foundation

/// Copy for the Mac menu bar extra. Lowercase, like the rest of `Copy`. The rows reuse the queue,
/// jobs, account and folder strings; only the lines that did not exist yet are here.
extension Copy {
    enum MenuBar {
        static let section = "menu bar"
        static let showIcon = "show in the menu bar"
        static let showIconFooter = "the icon stays up while capystore is open, including with the window closed. turn it off and closing the window quits, as before."

        static let pasteLink = "paste link"
        static let pasteHint = "reads your clipboard and saves it"
        static let activity = "activity"
        static let connected = "connected"
        /// "waking the server · it sleeps when idle."
        static var waking: String { "\(Copy.waking) · \(Copy.wakingNote)" }
        static let openApp = "open capystore"
        static let settings = "settings…"
        static let quit = "quit capystore"
        static let collapse = "collapse"
        static let expand = "expand"

        // the read-only Finder location. hidden until the File Provider from #109 is connected.
        // the toggle's words match that branch's `Copy.Folder.finderToggle`, so the two can fold together.
        static let finderTitle = "library in finder"
        static let finderToggle = "show library in finder"
        static let finderUpToDate = "up to date"
        static let finderUpdating = "updating"
        static let finderReadOnly = "read-only · a file downloads when you open it. finder can't change the library."
        static let openInFinder = "open in finder"

        static let shortcutPaste = "⌘V"
        static let shortcutOpen = "⇧⌘O"
        static let shortcutQueue = "⇧⌘J"
        static let shortcutSettings = "⌘,"
        static let shortcutQuit = "⌘Q"

        static func iconLabel(live: Int, failed: Int) -> String {
            var parts = ["capystore"]
            if live > 0 { parts.append(Copy.Queue.inProgressA11y(live)) }
            if failed > 0 { parts.append(Copy.Queue.header(running: 0, waiting: 0, failed: failed)) }
            return parts.joined(separator: ", ")
        }
    }
}
