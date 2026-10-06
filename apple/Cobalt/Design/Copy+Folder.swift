import Foundation

/// Copy and symbols for the Mac's "save to a folder" (a copy of every video and webp cobalt keeps, in a
/// folder in Finder). All lowercase, like the rest. Its own file so the folder lane never edits `Copy.swift`;
/// compiled into the app, the share extension and the widgets (`Cobalt/Design` is shared by all three).
extension Copy {
    enum Folder {
        static let group = "folder"
        static let toggle = "save to a folder"
        static let row = "folder"
        static let choose = "choose…"
        static let showInFinder = "show in finder"
        static let resetToDefault = "reset to default"
        static let chooseMessage = "cobalt copies the videos and webps it keeps into this folder."
        static let choosePrompt = "choose"
        static func saved(_ n: Int) -> String { n == 1 ? "1 saved" : "\(n) saved" }
        static func waiting(_ n: Int) -> String { "\(n) waiting" }
        static func saving(_ done: Int, of total: Int) -> String { "saving \(done) of \(total)" }
        static let statusRow = "saved"
        static func gaveUp(_ n: Int) -> String { n == 1 ? "1 couldn't be saved" : "\(n) couldn't be saved" }
        static let folderMissing = "the folder isn't there · choose another or put it back"
        static let notAllowed = "cobalt can't write to this folder · choose another"
        static func diskFull(_ waiting: Int) -> String { "the disk is full · \(waiting) waiting" }
        static let chooseFailed = "cobalt couldn't use that folder."
        // the offer for what cobalt already holds
        static func backfillTitle(_ n: Int) -> String {
            n == 1 ? "also save the video already in cobalt to this folder?" : "also save the \(n) videos already in cobalt to this folder?"
        }
        static func backfillAdd(_ n: Int) -> String { "save \(n)" }
        static let backfillSkip = "only new ones"
        static func existingRow(_ n: Int) -> String { n == 1 ? "save the 1 already in cobalt" : "save the \(n) already in cobalt" }
        // the more menu and the library's context menu
        static let menuShowInFinder = "show in finder"
        static let footer = "videos and webps cobalt keeps on this mac are copied here, once each, with a name you can read. delete or rename one in finder and cobalt leaves it alone, and renaming something in cobalt doesn't rename its file."
        static let footerOff = "turn this on to copy the videos and webps cobalt keeps into a folder in finder."
    }
}

extension Symbol {
    enum Folder {
        static let toggle = "folder.badge.plus"
        static let row = "folder"
        static let choose = "folder.badge.gearshape"
        static let showInFinder = "magnifyingglass"
        static let reset = "arrow.uturn.backward"
        static let status = "externaldrive.badge.checkmark"
        static let problem = "externaldrive.badge.exclamationmark"
        static let existing = "tray.and.arrow.down"
    }
}
