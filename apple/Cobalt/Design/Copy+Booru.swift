import CobaltKit
import Foundation

/// Copy for the booru tab (APP-API-CONTRACT 72; all new, lowercase). There is no explicit level anywhere in capystore, so
/// none of this ever names one.
extension Copy {
    enum Booru {
        static let title = "booru"

        // MARK: search

        static let searchPrompt = "tags, like hatsune_miku umbrella"
        static func tagsUsed(_ n: Int) -> String { "tags \(n) of \(BooruQuery.maxTags)" }
        static let tooManyTags = "danbooru takes 2 tags per search. take one out."
        static func hidden(_ n: Int) -> String { n == 1 ? "1 hidden by your filters" : "\(n) hidden by your filters" }
        static let loading = "loading…"
        static let empty = "nothing here at this level"
        static let emptyHint = "try other tags, or look at your filters."
        static let failed = "danbooru didn't answer"
        static let busy = "danbooru is busy, try again in a moment"
        static let retry = "try again"
        static let tapToShow = "tap to show"
        static let more = "load more"
        static let dropped = "danbooru's 2-tag limit left out the order; filters still apply."
        static func failure(_ code: String) -> String {
            switch code {
            case "error.booru.too_many_tags": return tooManyTags
            case "error.booru.busy": return busy
            case "error.network": return "you're offline"
            default: return failed
            }
        }

        // MARK: levels

        static func level(_ l: BooruLevel) -> String {
            switch l {
            case .general: return "general"
            case .sensitive: return "sensitive"
            }
        }
        static func levelDetail(_ l: BooruLevel) -> String {
            switch l {
            case .general: return "safe for anyone"
            case .sensitive: return "swimsuits, mild"
            }
        }
        static func upTo(_ l: BooruLevel) -> String { l == .general ? "general" : "up to \(level(l))" }
        static let safeMode = "safe mode: your screen is shared or recorded, so only general shows"
        static let raiseReason = "raise the booru level on this device"

        // MARK: filters

        static let filters = "filters"
        static let contentLevel = "content level"
        static let thisDevice = "this device only. going up asks for face id."
        static let presets = "presets"
        static let presetSafe = "stream safe"
        static let presetSafeDetail = "general only, gore hidden"
        static let presetCozy = "cozy"
        static let presetCozyDetail = "up to sensitive"
        static let themes = "themes"
        static let themesHint = "what to do with posts a theme matches, inside your level."
        static func mode(_ m: BooruThemeMode) -> String { m.rawValue }
        static let aboveLevel = "only matters at a higher level"
        static let alwaysHidden = "always hidden"
        static let hardBlock = "sexual content with child-like characters"
        static let hardBlockDetail = "every level, every device. not a setting."
        static let refine = "sort and refine"
        static let order = "order"
        static func order(_ o: BooruOrder) -> String {
            switch o {
            case .new: return "newest"
            case .popular: return "popular"
            case .score: return "score"
            case .favs: return "favourites"
            case .random: return "random"
            }
        }
        static let minScore = "score at least"
        static let any = "any"
        static let media = "type"
        static func media(_ m: BooruMedia) -> String {
            switch m {
            case .image: return "pictures"
            case .animated: return "animated"
            case .video: return "video"
            }
        }
        static let shape = "shape"
        static func shape(_ s: BooruShape) -> String { s.rawValue }
        static let blacklist = "blacklist"
        static let blacklistHint = "one rule per line. tags on a line must all match. -tag means not, ~a ~b means either. # starts a note."
        static let saveBlacklist = "save blacklist"
        static let saved = "saved"
        static let saveFailed = "couldn't save, try again"
        static let done = "done"

        // MARK: a post

        static let save = "save"
        static let saving = "saving…"
        static let savedToLibrary = "saving to your library"
        static let openDanbooru = "open on danbooru"
        static let share = "share"
        static let artist = "artist"
        static let character = "character"
        static let copyright = "series"
        static let general = "tags"
        static let meta = "meta"
        static let searchTag = "search this"
        static let addTag = "add to search"
        static let hideTag = "hide this tag"
        static func score(_ n: Int) -> String { "\(n)" }
        static func favs(_ n: Int) -> String { "\(n)" }
        static func size(_ w: Int, _ h: Int, _ ext: String) -> String { "\(w) × \(h) · \(ext)" }
        static let close = "close"
    }
}
