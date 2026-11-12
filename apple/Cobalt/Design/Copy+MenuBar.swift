import Foundation

/// Copy for the Mac menu bar extra. Lowercase, like the rest of `Copy`. The rows reuse the queue,
/// jobs, account and folder strings; only the lines that did not exist yet are here.
extension Copy {
    enum MenuBar {
        static let section = "menu bar"
        static let showIcon = "show in the menu bar"
        static let showIconFooter = "the icon stays up while capystore is open, including with the window closed. turn it off and closing the window quits, as before."

        // saving from other apps: the global keys and the right-click service (`QuickSave`)
        static let quickSection = "from other apps"
        static let quickPaste = "paste from anywhere"
        static let quickSet = "set keys"
        static let quickRecording = "press the keys…"
        static let quickClear = "remove the keys"
        static let quickNeedsModifier = "use ⌘, ⌃ or ⌥ with a key."
        static let quickTaken = "those keys are taken. try others."
        static let quickFooter = "the keys save the link or file on your clipboard from any app while capystore is running. or right-click: select a link, or a video or image file in finder, then services › save to capystore. that one can have its own keys in system settings › keyboard › keyboard shortcuts › services."

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

        // the read-only Finder location. the switch and the footnote are `Copy.Folder`'s.
        static let finderTitle = "library in finder"
        static let finderUpToDate = "up to date"
        static let finderUpdating = "updating"
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
