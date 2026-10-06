import CobaltKit
import Foundation

/// Copy for offline media (CONTRACT-OFFLINE section 3): keep offline, stop downloading, the confirms, the status
/// lines under the detail's toggle, the library's filter and column, the badge's VoiceOver words and the
/// settings rows. All lowercase. Plain values only (no model types), so it compiles into the share extension and
/// the widgets too (`Cobalt/Design` is shared). The words that depend on a model state live next to the screen
/// that draws them (`OfflineWords` in `Screens/Detail/OfflineCopy.swift`).
extension Copy.Offline {
    // actions: the context menus, the detail toggle and its `more` menu
    static let keep = "keep offline"                                   // the menu item, the toggle; also "fetches the rest"
    static let keepEverything = "keep everything offline"              // the detail's `more` menu when some is offline
    static let stop = "stop downloading"
    static let stopAll = "stop all"
    static let showInFiles = "show in files"                           // iOS: the media's folder in the files app
    static let openInFiles = "open in files"                           // iOS: the settings row

    // the library: the show filter's word and the table's column
    static let filter = "offline"
    static let column = "offline"
    /// The table's cell, in words (the tile and the row use the badge's glyph alone).
    static let cellAll = "offline"
    static let cellSome = "partly"
    static let cellFailed = "failed"
    static let cellWaiting = "waiting"

    // the confirm of "remove offline copy" (decision 10): the server keeps a copy, or this is the only one
    static let removeCopyTitle = "remove the offline copy?"
    static let removeCopyMessage = "the server keeps its copy. you can keep it offline again any time."
    static let onlyCopyTitle = "remove the only copy?"
    static let onlyCopyMessage = "this isn't on your server. once it's removed it can't be downloaded again."

    // the status line under the detail's toggle
    /// Kept: where it is and how big. The iPhone and iPad keep it in the files app; the Mac (wave 1) in its own
    /// store (wave M: the folder's display path).
    static func kept(bytes: Int64) -> String {
        #if os(macOS)
        "on this \(Copy.device) · \(Copy.Storage.size(bytes))"
        #else
        "in the files app · \(Copy.Storage.size(bytes))"
        #endif
    }
    static func cached(bytes: Int64) -> String {
        "in the cache · \(Copy.Storage.size(bytes)) · leaves when space runs low"
    }
    /// "downloading… 12 of 54 MB"; with no total "downloading… 12 MB". The unit is said once when both sides share it.
    static func downloading(bytes: Int64, total: Int64?) -> String {
        let done = Copy.Storage.size(bytes)
        guard let total, total > 0 else { return "downloading… \(done)" }
        let all = Copy.Storage.size(total)
        return "downloading… \(sharedUnit(done, all)) of \(all)"
    }
    static let waiting = "waiting for the network"
    static let unavailable = "nothing to download it from"
    static let authRefused = "your key was refused. check it in settings."
    static var full: String { "this \(Copy.device) is full." }

    /// "12 MB" and "54 MB" read "12 of 54 MB": the first drops the unit the second already says.
    private static func sharedUnit(_ first: String, _ second: String) -> String {
        guard let a = first.split(separator: " ").last, let b = second.split(separator: " ").last, a == b,
            let number = first.split(separator: " ").first
        else { return first }
        return String(number)
    }

    // VoiceOver on a badge, a row or a cell
    static let a11yAll = "offline"
    static let a11ySome = "partly offline"
    static let a11yFailed = "couldn't download"
    static let a11yWaiting = "waiting for the network"
    static func a11yDownloading(percent: Int?) -> String {
        percent.map { "downloading, \($0) percent" } ?? "downloading"
    }

    // settings, "on this iphone"
    static let keepNewSaves = "keep new saves offline"                 // replaces `Copy.keepVideos`
    static let rowOffline = "offline"
    static let rowDownloading = "downloading"
    static let rowCache = "cache"
    static let clearCache = "clear cache"
    static let clear = "clear"
    static let clearCacheTitle = "clear the cache?"
    static let clearCacheMessage = "offline videos stay. the server keeps its copies."
    /// "2 left · 120 of 300 MB"; with no total "2 left · 120 MB".
    static func queueLine(left: Int, bytes: Int64, total: Int64?) -> String {
        "\(left) left · " + String(downloading(bytes: bytes, total: total).dropFirst("downloading… ".count))
    }
    /// The section's footer (the Mac says nothing of the files app until wave M).
    static var footer: String {
        #if os(macOS)
        "offline videos stay on this \(Copy.device) until you remove them here. the cache makes room by itself."
        #else
        "offline videos stay on this \(Copy.device) until you remove them, here or in files › on my \(Copy.device) › cobalt. the cache makes room by itself."
        #endif
    }
}
