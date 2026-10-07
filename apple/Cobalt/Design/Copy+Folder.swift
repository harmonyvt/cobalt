import Foundation

/// Copy for the Mac's folder (CONTRACT-OFFLINE.md 13.10): the Finder folder that holds the kept files, the choose dialog,
/// the problem lines and the "saves from other devices" row. Lowercase, exact. Its own file so the folder lane never edits
/// `Copy.swift`; compiled into the app, the share extension and the widgets (`Cobalt/Design` is shared by all three), so plain
/// values only. The copier's strings (the `save to a folder` toggle, the backfill offer, its counters) went with it.
extension Copy {
    enum Folder {
        // the folder row and its buttons
        static let row = "folder"
        static let choose = "choose…"
        static let showInFinder = "show in finder"
        static let useDefault = "use ~/Movies/cobalt"

        // the open panel
        static let choosePrompt = "choose"
        static let chooseMessage = "offline files are kept in this folder."

        // the choose dialog: "move the 24 offline files to <path>?"
        static func moveTitle(count: Int, path: String) -> String {
            count == 1 ? "move the 1 offline file to \(path)?" : "move the \(count) offline files to \(path)?"
        }
        static let move = "move"
        static let leaveThem = "leave them"
        static let moveMessage = "left behind, they stay in the old folder and aren't offline here any more."
        static func moving(done: Int, of total: Int) -> String { "moving… \(done) of \(total)" }
        static let refusedICloud = "pick a folder on this mac or an external disk. icloud drive folders can't hold offline files."
        static let chooseFailed = "cobalt couldn't use that folder."

        // the problem line (only when there is one)
        static let unreachable = "this folder isn't connected. new saves wait on this mac until it's back."
        static let notAllowed = "cobalt can't write to this folder."
        static let wrongFolder = "this isn't the folder cobalt was using. choose it again."
        static let diskFull = "the disk is full."

        // the detail's line while the disk is away
        static func notConnected(path: String) -> String { "on \(path), which isn't connected" }

        // "saves from other devices": what the pull is doing
        static let pullRow = "saves from other devices"
        static let pullNotChecked = "not checked yet"
        static func pullChecked(_ ago: String) -> String { "checked \(ago)" }
        static func pullDownloading(_ n: Int) -> String { "downloading \(n)" }
        static let pullKeepOff = "paused while keep new saves offline is off"
        static let pullFolderAway = "paused until the folder is back"
        static let pullAuth = "your key was refused. check it above."
        static let pullNoServer = "paused until a server and key are set above"

        /// "just now", "2 min ago", "3 hr ago", "2 days ago": how long ago a check ran.
        static func ago(seconds: TimeInterval) -> String {
            let s = max(0, Int(seconds))
            if s < 60 { return "just now" }
            if s < 3600 { return "\(s / 60) min ago" }
            if s < 86_400 { return "\(s / 3600) hr ago" }
            let days = s / 86_400
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }

        static let footer = "offline files stay in this folder until you remove them, here or in finder. while cobalt is open, saves from your iphone, the share sheet, shortcuts and the web download here too. the cache makes room by itself."
    }
}

extension Symbol {
    enum Folder {
        static let row = "folder"
        static let choose = "folder.badge.gearshape"
        static let showInFinder = "folder"
        static let reset = "arrow.uturn.backward"
        static let pull = "arrow.triangle.2.circlepath"
    }
}
