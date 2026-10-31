import CobaltKit
import Foundation

/// Copy for the chat's tool cards (APP-API-CONTRACT section 38; all new, lowercase): the call chips under a code step and
/// the cards for what the calls did. Plain values only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum ChatCards {
        // MARK: the chips

        /// "library.search" as a chip: the op name as the model calls it.
        static func chip(_ op: String) -> String { op }
        static func ms(_ ms: Int) -> String { ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000) }
        static func calls(_ n: Int) -> String { "\(n) \(n == 1 ? "call" : "calls")" }
        static let asked = "asks first"
        static func chipA11y(_ call: ChatToolCall) -> String {
            switch call.status {
            case .done: return "\(call.op), \(ms(call.ms))"
            case .asked: return "\(call.op), waiting for your ok"
            case .error: return "\(call.op) failed: \(call.error ?? "")"
            }
        }

        // MARK: search and look

        static let searched = "searched"
        static func searchSub(query: String, within: String?, total: Int) -> String {
            let q = query.isEmpty ? "" : "“\(query)”"
            let w = within.map { " in \($0)" } ?? ""
            return "\(q)\(w) · \(total) \(total == 1 ? "post" : "posts")"
        }
        static let lookedAt = "looked at"
        static func pictures(_ n: Int) -> String { "\(n) \(n == 1 ? "picture" : "pictures")" }

        // MARK: emotes

        static let emotes = "7TV emotes"
        static let emoteSaved = "saved emote"
        /// The 7TV list a search came from (section 20.1's `sort`).
        static func sort(_ key: String?) -> String? {
            guard let key else { return nil }
            switch key {
            case "top": return "top of all time"
            case "top_daily": return "top today"
            case "top_weekly": return "top this week"
            case "top_monthly": return "top this month"
            case "trending_daily": return "trending today"
            case "trending_weekly": return "trending this week"
            case "trending_monthly": return "trending this month"
            case "new": return "newest"
            case "global": return "global emotes"
            default: return key.replacingOccurrences(of: "_", with: " ")
            }
        }
        static func emotesSub(_ e: ChatToolCard.Emotes) -> String {
            [sort(e.sort), e.query.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " · ")
        }
        static func emoteLine(_ name: String, saved: Bool) -> String { saved ? "\(name) · in your library" : name }
        static let inLibrary = "in your library"

        // MARK: an edit

        static let edit = "edit"
        static func editChange(_ c: ChatToolCard.Edit.Change) -> String {
            switch c {
            case .created: return "new edit"
            case .updated: return "edit changed"
            case .viewed: return "edit"
            }
        }
        static let main = "main"
        static func layer(_ i: Int) -> String { "over \(i + 1)" }
        static func revision(_ r: Int) -> String { "rev \(r)" }
        static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }
        static func size(_ w: Int, _ h: Int) -> String { "\(w)×\(h)" }
        static func added(_ clips: [ChatToolCard.Edit.Clip]) -> String {
            guard let first = clips.first else { return "" }
            let name = first.title ?? kind(first.kind)
            let more = clips.count > 1 ? " +\(clips.count - 1)" : ""
            return "+ \(name) at \(String(format: "%.1f", first.at)) s\(more)"
        }
        static func kind(_ k: ChatToolCard.Edit.Clip.Kind?) -> String {
            switch k {
            case .video: return "video"
            case .photo: return "image"
            case .gif: return "gif"
            case .webp: return "webp"
            case .emote: return "emote"
            case .cutout: return "cutout"
            case nil: return "removed"
            }
        }
        static func clipDetail(_ c: ChatToolCard.Edit.Clip) -> String {
            var parts = [
                String(format: "%.1f–%.1f s on the timeline", c.at, c.at + c.length),
                String(format: "from %.1f–%.1f s", c.sourceIn, c.sourceOut),
            ]
            if abs(c.speed - 1) > 0.001 { parts.append(String(format: "%g× speed", c.speed)) }
            if let p = c.pitch, p != 0 { parts.append(String(format: "pitch %+g", p)) }
            return parts.joined(separator: " · ")
        }
        static let addedHere = "added here"
        static let openEditor = "open in editor"
        static func rendered(_ status: String) -> String { status == "done" ? "rendered" : "render \(status)" }
        static func editA11y(_ e: ChatToolCard.Edit) -> String {
            let clips = e.tracks.flatMap(\.clips).count
            return "\(editChange(e.change)) \(e.title ?? ""), \(clips) \(clips == 1 ? "clip" : "clips"), \(seconds(e.duration))"
        }

        // MARK: jobs

        static func jobTitle(_ op: String) -> String {
            switch op {
            case "make.webp": return "making a webp"
            case "make.still": return "making a still webp"
            case "make.slideshow": return "making a slideshow"
            case "make.galleryImage": return "making a gallery image"
            case "make.trim": return "trimming"
            case "make.crop": return "cropping"
            case "make.cutout": return "cutting out"
            case "edits.render": return "rendering"
            default: return "making it"
            }
        }
        static func jobStatus(_ j: ChatToolCard.Job) -> String {
            switch j.status {
            case "done": return "done"
            case "error": return "failed\(j.error.map { " · \($0)" } ?? "")"
            case "cancelled": return "cancelled"
            case "opening": return "opening the file…"
            case "queued": return j.watching ? "queued · the chat carries on when it's ready" : "queued"
            default:
                let p = j.progress.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
                return "running\(p)\(j.watching ? " · the chat carries on when it's ready" : "")"
            }
        }
        static func jobResult(_ j: ChatToolCard.Job) -> String {
            var parts: [String] = []
            if let s = j.seconds, s > 0 { parts.append(seconds(s)) }
            if let w = j.width, let h = j.height { parts.append(size(w, h)) }
            if let b = j.bytes { parts.append(Copy.Storage.size(b)) }
            return parts.joined(separator: " · ")
        }

        // MARK: the box

        static let box = "box"
        static func exit(_ code: Int?, timedOut: Bool) -> String { timedOut ? "timed out" : "exit \(code.map(String.init) ?? "?")" }
        static let showAll = "show all"
        static let showLess = "show less"
        static func pulled(_ n: Int) -> String { "pulled into the box · \(n) \(n == 1 ? "file" : "files")" }
        static let savedFromBox = "saved from the box"
        static func file(_ f: ChatToolCard.Files.File) -> String { f.bytes.map { "\(f.name) · \(Copy.Storage.size($0))" } ?? f.name }

        // MARK: links, collections, saves

        static let link = "share link"
        static func linkSub(_ l: ChatToolCard.Link) -> String {
            let files = l.files.map { "\($0) \($0 == 1 ? "file" : "files")" }
            return [files, l.isPrivate ? "private" : "public"].compactMap { $0 }.joined(separator: " · ")
        }
        static let copy = "copy"
        static let open = "open"
        static let copied = "link copied"
        /// The link card's icon names (held, hovered, read by VoiceOver).
        static let copyLink = "copy share link"
        static let openLink = "open share link"
        static func folder(_ c: ChatToolCard.Folder) -> String { c.isSet ? "set" : "collection" }
        static func folderChange(_ c: ChatToolCard.Folder) -> String {
            switch c.change {
            case .created: return "made"
            case .added: return "added to"
            case .updated: return "changed"
            }
        }
        static func folderCount(_ c: ChatToolCard.Folder) -> String? {
            c.count.map { n in c.isSet ? "\(n) \(n == 1 ? "collection" : "collections")" : "\(n) \(n == 1 ? "link" : "links")" }
        }
        static let saved = "saved to your library"
        static func saveStatus(_ s: String?) -> String? {
            switch s {
            case "saving", "queued": return "still saving"
            case "error": return "the save failed"
            default: return nil
            }
        }
    }
}
