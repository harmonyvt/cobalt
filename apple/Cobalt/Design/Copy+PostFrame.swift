import CobaltKit
import Foundation

/// Copy for post frames (APP-API-CONTRACT 52, the mockup's sections 1 to 3): the item page's button and sheet, the editor's
/// "post" tool, the switch on save. All lowercase, except the few words drawn inside a card, which read like the site.
/// Plain values and CobaltKit types only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum PostFrame {
        static let postFrame = "post frame"
        static let sheetTitle = "post frame"
        static let editorTitle = "post frame"
        static let toolPost = "post"
        static let fromThePost = "from the post"
        static let framedCopies = "framed copies"

        // MARK: the sheet

        static let style = "style"
        static func styleFound(_ host: String) -> String { "style · found \(host) in the link" }
        static let look = "look"
        static let size = "size"
        static let canvas = "canvas"
        static let show = "show"
        static let avatar = "avatar"
        static let text = "text"
        static let postText = "post text"
        static let counts = "likes and views"
        static let time = "time"
        static let preview = "preview of the framed copy"
        static let make = "make framed copy"
        static let making = "making a framed copy…"
        static let openInEditor = "open in editor for more"
        static let note = "frames the whole video. the original is kept."
        static let editorNote = "frames the main clip with its trim. text and overlays aren't drawn into a framed copy yet."
        static let shownAsPosted = "times are shown as posted: \"4h\" becomes the date"

        static func styleName(_ style: PostFrameStyle) -> String {
            switch style {
            case .x: return "x"
            case .instagram: return "instagram"
            case .twitch: return "twitch"
            case .youtube: return "youtube"
            case .generic: return "generic"
            }
        }

        static func themeName(_ theme: PostFrameTheme) -> String {
            switch theme {
            case .light: return "light"
            case .dark: return "dark"
            }
        }

        static func canvasName(_ canvas: PostFrameCanvas) -> String {
            switch canvas {
            case .fit: return "fit the post"
            case .portrait: return "9:16"
            case .square: return "1:1"
            }
        }

        /// The short form of a size on a framed copy's line.
        static func canvasShort(_ canvas: PostFrameCanvas) -> String {
            switch canvas {
            case .fit: return "fit"
            case .portrait: return "9:16"
            case .square: return "1:1"
            }
        }

        // MARK: the details

        static let looking = "looking up the post…"
        static let gone = "couldn't find the post. type the details in the editor."
        static let goneShort = "the post is gone"
        static let noLink = "this video has no post to frame it in"
        static let off = "post frames are off on this server"
        static let failed = "couldn't read the post"
        static let tryAgain = "try again"
        static let lookUpAgain = "look up again"
        static let edited = "edited"
        static let detailsHeader = "details · from the post, edit if wrong"
        static let name = "name"
        static let handle = "handle"
        static let title = "title"
        static let channel = "channel"
        static let game = "game"
        static let detailsSaved = "details saved"
        static let detailsNotSaved = "couldn't save the details"

        /// The line under "from the post": `mochi · @mochibytes · nov 8`.
        static func whoLine(_ d: PostDetails) -> String {
            var parts: [String] = []
            if let name = d.displayName { parts.append(name) }
            if let handle = d.handle, handle != d.displayName, "@\(d.displayName ?? "")" != handle { parts.append(handle) }
            if let at = d.postedAt { parts.append(shortDate(at)) }
            return parts.isEmpty ? (d.host ?? d.link) : parts.joined(separator: " · ")
        }

        /// `18K likes · 402K views`, from what the post has.
        static func countsLine(_ c: PostCounts) -> String? {
            var parts: [String] = []
            if let n = c.likes { parts.append("\(PostCounts.compact(n)) likes") }
            if let n = c.views { parts.append("\(PostCounts.compact(n)) views") }
            if parts.isEmpty, let n = c.comments { parts.append("\(PostCounts.compact(n)) comments") }
            if parts.isEmpty, let n = c.subscribers { parts.append("\(PostCounts.compact(n)) subscribers") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// `nov 8`, or `nov 8, 2024` in another year (lowercase, the app's own lines).
        static func shortDate(_ date: Date) -> String { cardDate(date).lowercased() }

        // MARK: framed copies

        /// `x · dark · fit` under a copy, `rendering 42%` while it is made.
        static func copyLine(style: PostFrameStyle?, created: Date) -> String {
            let when = shortDate(created)
            guard let style else { return when }
            return "\(styleName(style)) · \(when)"
        }
        static func rendering(_ pct: Int) -> String { "rendering \(pct)%" }
        static let queuedLine = "waiting to render"
        static let renderFailed = "the frame failed"
        static func queueTitle(_ title: String) -> String { "post frame · \(title)" }

        // MARK: after "make framed copy"

        static let queued = "making a framed copy"
        static let queuedDetail = "original kept · it lands in your library, private"
        static let openQueue = "open queue"

        /// What a refused "make framed copy" says.
        static func message(for error: Error) -> String {
            switch error {
            case PostFrameError.noLink: return noLink
            case PostFrameError.notVideo: return "only videos can be framed"
            case PostFrameError.notFound: return "that video is gone"
            case PostFrameError.badRequest: return "the server didn't take those details"
            case PostFrameError.off: return off
            case let e as EditError: return Copy.Editor.errorLine(e)
            default: return Copy.actionFailed
            }
        }

        // MARK: the editor

        static let noClip = "add a video to frame first"
        static let notOnServer = "this clip's file isn't in your library"
        static let apply = "make framed copy"

        // MARK: on save (settings)

        static let saveSection = "post frame on save"
        static let saveFooter = "when a site is on, each video saved from it also gets a framed copy, as soon as the save finishes. the plain video is always kept. galleries and photos are left alone."
        static func siteRow(_ style: PostFrameStyle) -> String {
            switch style {
            case .x: return "x links"
            case .instagram: return "instagram links"
            case .twitch: return "twitch links"
            case .youtube: return "youtube links"
            case .generic: return "other sites"
            }
        }

        // MARK: inside the cards (read like the sites)

        enum Card {
            static let subscribe = "Subscribe"
            static let follow = "follow"
            static let clip = "CLIP"
            static func clippedBy(_ name: String) -> String { "clipped by \(name)" }
            static func likes(_ n: Int) -> String { "\(n.formatted()) likes" }
            static func comments(_ n: Int) -> String { "view all \(n.formatted()) comments" }
            static func views(_ n: Int) -> String { "\(PostCounts.compact(n)) views" }
            static func subscribers(_ n: Int) -> String { "\(PostCounts.compact(n)) subscribers" }
            static let savedWith = "saved with capystore"
        }

        /// `Nov 8`, or `Nov 8, 2024` in another year: how the sites show a post's date (a card shows it as posted).
        static func cardDate(_ date: Date, now: Date = Date()) -> String {
            let cal = Calendar.current
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
            let style = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
            let base = date.formatted(style)
            return sameYear ? base : "\(base), \(cal.component(.year, from: date))"
        }
    }
}
