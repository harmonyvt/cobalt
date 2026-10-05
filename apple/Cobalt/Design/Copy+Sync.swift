import Foundation

/// Copy for the share sheet's automatic continue and the photos album (CONTRACT-SYNC.md section 2).
/// All lowercase. Its own file so this lane never edits `Copy.swift`; compiled into the app, the
/// share extension and the widgets (`Cobalt/Design` is shared by all three).
extension Copy {
    enum Sync {
        // settings · share sheet
        static let shareGroup = "share sheet"
        static let autoContinue = "continue in background automatically"
        static let wait = "wait"
        static func seconds(_ s: Int) -> String { "\(s) s" }
        static let autoContinueFooter = "after you share a link, the sheet waits this long, then closes and cobalt finishes on its own. tap stay to keep it open."
        // settings · photos
        static let photosGroup = "photos"
        static let albumToggle = "save to a photos album"
        static let includeWebps = "include webps"
        static let albumRow = "album"
        static let openSettings = "open settings"
        static func albumCount(_ n: Int) -> String { "\u{201C}cobalt\u{201D} · \(n) added" }
        static func adding(_ done: Int, of total: Int) -> String { "adding \(done) of \(total)" }
        static func waiting(_ n: Int) -> String { "\(n) waiting" }
        static let libraryLimited = "your library · limited access"
        static let libraryAddOnly = "your library · add-only access"
        static let accessOff = "photos access is off"
        static let paused = "paused · keep videos is off"
        static func outOfSpace(_ n: Int) -> String { "photos is full · \(n) waiting" }
        static func gaveUp(_ n: Int) -> String { n == 1 ? "1 couldn't be added" : "\(n) couldn't be added" }
        static let footerAlbum = "videos cobalt keeps on this iphone go into a \u{201C}cobalt\u{201D} album in photos, once each. deleting one here or in photos never adds it back."
        static let footerLimited = "with limited access cobalt can add to your library but not make an album. allow full access in settings to use the album."
        static let footerAddOnly = "cobalt can only add to your library. allow full access in settings to use the album."
        static let footerDenied = "cobalt can't add to photos. allow access in settings."
        static let footerNeedsKeep = "turn on keep videos on this iphone first: the album is filled from what cobalt keeps."
        static let webpStill = "photos shows a webp as a still picture; its link still plays."   // gate G-W: PhotoKit classifies a webp as a still (core lane, 2026-10-04)
        static func backfillTitle(_ n: Int) -> String { n == 1 ? "also add the video already in cobalt?" : "also add the \(n) videos already in cobalt?" }
        static func backfillAdd(_ n: Int) -> String { "add \(n)" }
        static let backfillSkip = "only new ones"
        // the save-to-photos button
        static let inAlbum = "in your cobalt album"
        static let inLibrary = "in your photos"
    }
}
