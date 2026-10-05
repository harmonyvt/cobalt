import CobaltKit
import Foundation

/// Copy for one media with many renditions (CONTRACT-MEDIA.md section 3): the tabs, the planet's
/// accessibility value, the detail's buttons and menu, the three ways to get rid of things and
/// their words. All lowercase. Its own file so the lanes that build the screens never edit `Copy.swift`;
/// compiled into the share extension and the widgets too (`Cobalt/Design` is shared).
extension Copy {
    enum Media {
        static let video = "video"
        static let webp = "webp"
        static func webpTab(_ n: Int) -> String { "webp \(n)" }                  // 1-based, creation order
        static func webpCount(_ n: Int) -> String { n > 1 ? "webp ×\(n)" : "webp" }   // badge and chip
        static let tabsA11y = "which file"
        static func tabA11y(_ name: String, _ i: Int, of n: Int) -> String { "\(name), \(i) of \(n)" }
        static func planetA11y(title: String, webps: Int, hasVideo: Bool) -> String {
            let w = webps == 0 ? "" : (webps == 1 ? "1 webp" : "\(webps) webps")
            switch (hasVideo, webps) {
            case (true, 0): return "open \(title), video"
            case (true, _): return "open \(title), video and \(w)"
            default: return "open \(title), \(w)"
            }
        }
        static let makeAWebp = "make a webp"
        static let makeAnotherWebp = "make another webp"
        static let anotherWebp = "another webp"
        static let copyWebpLink = "copy webp link"
        static let copyVideoLink = "copy video link"
        static let publicShare = "public share"
        static let share = "share"
        static let savePhotos = "save to photos"
        static let copied = "copied"
        static let more = "more"
        static let deleteWebp = "delete this webp"
        static let deleteWebpTitle = "delete this webp for everyone?"
        static let deleteWebpMessage = "discord embeds stop working. the video and its other webps stay."
        static var removeWebpTitle: String { "remove this webp from this \(Copy.device)?" }
        static let removeWebpMessage = "the public link keeps working."
        static var removeMedia: String { "remove from this \(Copy.device)" }
        static var removeMediaTitle: String { "remove from this \(Copy.device)?" }
        static func removeMediaMessage(webps: Int) -> String {
            let what = webps == 0 ? "the video" : "the video and its \(webps == 1 ? "webp" : "\(webps) webps")"
            return "\(what) leave this \(Copy.device). your library and public links keep them."
        }
        static let deleteEverything = "delete everything"
        static let deleteEverythingTitle = "delete everything?"
        /// (b): "the video, its public link and its 3 webps are deleted for everyone. links you shared
        /// stop working. this can't be undone." Parts that do not exist are left out.
        static func deleteEverythingMessage(video: Bool, hosted: Bool, webps: Int) -> String {
            var parts: [String] = []
            if video { parts.append("the video") }
            if hosted { parts.append("its public link") }
            if webps > 0 { parts.append(webps == 1 ? "its webp" : "its \(webps) webps") }
            let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : (parts.first ?? "everything")
            let plural = parts.count > 1 || webps > 1
            return "\(list) \(plural ? "are" : "is") deleted for everyone. links you shared stop working. this can't be undone."
        }
        /// (a), an older server: only the webps can go.
        static func deleteEverythingFallbackMessage(webps: Int) -> String {
            let w = webps == 1 ? "its webp is" : "its \(webps) webps are"
            return "\(w) deleted for everyone and \(webps == 1 ? "its link stops" : "their links stop") working. the private copy and the video's public link stay on the server; delete those on the web."
        }
        static let deleting = "deleting…"
        static let deleted = "deleted."
        static func deletePartial(remaining: Int) -> String {
            "couldn't delete all of it. \(remaining == 1 ? "1 file is" : "\(remaining) files are") still there."
        }
        static let stillOnServer = "the private copy and the video's public link are still on the server. delete them on the web."
        static let deleteBusy = "still making a webp from this. try again when it's done."
        static let tryAgain = "try again"
        static let openInLibrary = "open in library"
        static let delete = "delete"
        static let remove = "remove"
        static let keep = "keep"
        static let deleteFailed = "couldn't delete that. it is still there."

        /// "14.8 s · 720×1280 · 4.3 MB · saved yesterday 13:59": the non-nil parts joined with " · ",
        /// then `when` prefixed with "saved " (`Format.when`).
        static func videoMeta(seconds: String?, size: String?, bytes: String?, when: String) -> String {
            ([seconds, size, bytes].compactMap { $0 } + ["saved \(when)"]).joined(separator: " · ")
        }
        /// "00:02.0 → 00:12.0 · crop 1:1 · 480×480 · 2.4 MB · made today 20:52": `range` is
        /// `Copy.timecodeRange` (or `Format.seconds(duration)` when no trim is known).
        static func webpMeta(range: String?, crop: String?, size: String?, bytes: String?, when: String) -> String {
            ([range, crop, size, bytes].compactMap { $0 } + ["made \(when)"]).joined(separator: " · ")
        }
        /// "crop 1:1", "crop 4:5"; just "crop" for a free crop (an empty or "free" aspect).
        static func cropBadge(_ aspect: String) -> String {
            aspect.isEmpty || aspect == "free" ? "crop" : "crop \(aspect)"
        }

        // The wide detail's rows (CONTRACT-MEDIA 5), the menu entry for a webp the server cannot delete with a key
        // (it only leaves this device: the confirm's title without its question mark), the hero's words.
        static let length = "length"
        static let trim = "trim"
        static let crop = "crop"
        static let size = "size"
        static let fileSize = "file size"
        static let made = "made"
        static let saved = "saved"
        static let link = "link"
        static var removeWebp: String { String(removeWebpTitle.dropLast()) }
        /// VoiceOver for the hero: its name, and where it is when the file is not here.
        static func heroA11y(_ name: String, evicted: Bool) -> String {
            evicted ? "\(name), not on this \(Copy.device)" : name
        }
        /// The hero's full-screen button, and its way back.
        static let fullScreen = "full screen"
        static let exitFullScreen = "exit full screen"
        /// VoiceOver on the full-screen webp viewer (it closes with a tap, a swipe down or Escape).
        static func webpViewerA11y(_ name: String) -> String { "\(name), full screen. tap to close" }
    }
}
