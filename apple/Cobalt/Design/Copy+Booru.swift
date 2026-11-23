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
        static let empty = "nothing here"
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

        // MARK: filters

        static let filters = "filters"
        static let alwaysHidden = "always hidden"
        static let hardBlock = "sexual content with child-like characters"
        static let hardBlockDetail = "every device. not a setting."
        static let generalOnly = "anything above general, plus swimsuits, suggestive, nudity, gore and body horror"
        static let generalOnlyDetail = "general only, every device. not a setting."
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

/// Copy for finding a picture's booru post (APP-API-CONTRACT 72.11; lowercase).
extension Copy {
    enum BooruFind {
        static let header = "booru"
        static let find = "find on booru"
        static let findAgain = "find on booru again"
        static func linkedTo(_ url: URL) -> String { "linked: danbooru #\(url.lastPathComponent)" }
        static let title = "find on booru"
        static let searching = "looking for this picture on danbooru…"
        static func waited(_ s: Int) -> String { s < 5 ? "this can take up to a minute" : "\(s) s · this can take up to a minute" }
        static let none = "no booru post found"
        static let noneHint = "only general posts count. a very new post may not be searchable yet."
        static let pick = "close matches, best first. tap one to link it."
        static let linking = "linking…"
        static let linked = "linked: this post's source is now the danbooru page"
        static let wrongOne = "wrong one? pick another"
        static let use = "use"
        static func similarity(_ n: Int) -> String { "\(n)% match" }
        static func who(_ p: BooruPost) -> String {
            let words = { (tags: [String]) in tags.prefix(2).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ") }
            let artist = p.tags.artist.first.map { "by \($0.replacingOccurrences(of: "_", with: " "))" }
            let what = p.tags.character.isEmpty ? words(p.tags.copyright) : words(p.tags.character)
            return [artist, what.isEmpty ? nil : what, "#\(p.id)"].compactMap { $0 }.joined(separator: " · ")
        }
        static func failure(_ code: String) -> String {
            switch code {
            case "error.network": return "you're offline"
            case "error.booru.no_picture": return "couldn't read this picture"
            case "error.booru.not_general": return "that post isn't general, so it can't be linked"
            case "error.booru.too_large": return "this picture is too big to search"
            case "error.booru.upstream", "error.booru.busy": return Copy.Booru.failed
            default: return "the picture search didn't answer. try again in a bit."
            }
        }
    }
}
