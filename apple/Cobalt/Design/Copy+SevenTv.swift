import CobaltKit
import Foundation

/// Copy for 7TV in the studio tab (APP-API-CONTRACT 57.7; all new, lowercase): the card, the link sheet, the set screen, the
/// emote sheet and the refusals. Plain values only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum SevenTv {
        static let title = "7tv"

        // MARK: the card

        static let loading = "loading 7tv…"
        static let notLinkedBody = "link your 7tv account to manage the emote sets of your channel and the channels you edit."
        static let link = "link 7tv"
        static let linkAgain = "link again"
        static let signedOut = "7tv signed you out"
        static let signedOutBody = "log in on 7tv.app, then tap the bookmark again."
        static let unlink = "unlink"
        static let unlinkTitle = "unlink 7tv?"
        static let unlinkMessage = "capystore forgets the token. you stay logged in on 7tv.app until you log out there."
        static let keep = "keep"
        static let unlinked = "7tv unlinked"
        static let retry = "try again"
        static func linkedLine(channels: Int) -> String {
            channels == 1 ? "linked · 1 channel you can edit" : "linked · \(channels) channels you can edit"
        }
        static func expiresIn(days: Int) -> String {
            switch days {
            case 0: return "7tv signs you out today · link again soon"
            case 1: return "expires in 1 day"
            default: return "expires in \(days) days"
            }
        }
        static let channelsA11y = "channels"
        static let live = "live"
        static let open = "open"
        static let makeLive = "make live"
        static let newSet = "new set"
        static let noSets = "no sets in this channel yet"
        static let loadingSets = "loading sets…"
        static func count(_ count: Int, capacity: Int?) -> String {
            capacity.map { "\(count) / \($0)" } ?? "\(count)"
        }
        static func setA11y(_ name: String, count: Int, capacity: Int?, live: Bool) -> String {
            let emotes = capacity.map { "\(count) of \($0) emotes" } ?? "\(count) emotes"
            return live ? "\(name), live, \(emotes)" : "\(name), \(emotes)"
        }
        static func madeLive(_ set: String) -> String { "\(set) is live" }
        static func created(_ set: String) -> String { "made \(set)" }
        static let newSetTitle = "new set"
        static let newSetMessage = "an empty set in this channel. 1–100 characters."
        static let setName = "set name"
        static let make = "make"
        static let cancel = "cancel"

        // MARK: linking

        static let linkTitle = "link 7tv"
        static let once = "once"
        static let easiest = "easiest"
        static let why = "7tv has no \"sign in with 7tv\" for other apps, so capystore borrows the login you already have on 7tv.app."
        static let step1 = "open 7tv.app and log in with twitch"
        #if os(macOS)
        static let step2 = "click the capystore link bookmark"
        #else
        static let step2 = "tap the capystore link bookmark"
        #endif
        static let step3 = "capystore opens and links. done"
        static let copyBookmark = "copy the bookmark"
        static let bookmarkCopied = "bookmark copied"
        static let bookmarkHow = "add a bookmark named \"capystore link\" and paste this as its address."
        static let openWebsite = "open 7tv.app"
        static let orPaste = "or paste it"
        static let pasteHow = "on 7tv.app, open the browser console and copy the value of localStorage key 7tv-token."
        static let tokenField = "7tv token"
        static let tokenHint = "stays on this device until you tap link"
        static let linkButton = "link"
        static let linking = "linking…"
        static let footer = "capystore checks the token with 7tv, shows whose account it is, stores it encrypted, and never shows it again."
        static func linked(_ name: String) -> String { name.isEmpty ? "7tv linked" : "linked 7tv as \(name)" }

        // MARK: a set

        static let setFallbackTitle = "set"
        static let inThisSet = "in this set"
        static let addFrom7tv = "add from 7tv"
        static let tabsA11y = "what to show"
        static func filter(_ count: Int) -> String { "filter \(count) emotes…" }
        static let filterMiss = "no emote by that name in this set"
        static let empty = "this set is empty · add some from 7tv"
        static let loadingSet = "loading the set…"
        static let failedSet = "can't load this set"
        static let addHint = "+ adds under its own name; hold to add with another name. a name already in the set asks before it swaps."
        #if os(macOS)
        static let addHintShort = "+ adds under its own name; right-click to add with another name."
        #else
        static let addHintShort = "+ adds under its own name; hold to add with another name."
        #endif
        static let searchField = "search 7tv"
        static let searchMiss = "nothing on 7tv for that"
        static let searchDown = "7tv didn't answer."
        static let addWithName = "add with another name…"
        static let addAsTitle = "add with another name"
        static func addAsMessage(_ name: String) -> String { "\(name) goes in under this name. no spaces." }
        static let alias = "name in this set"
        static let add = "add"
        static func added(_ alias: String) -> String { "added \(alias)" }
        static let alreadyIn = "already in this set"
        static func swapTitle(_ alias: String) -> String { "\(alias) is already in this set" }
        static let swapMessage = "swap it for this one?"
        static let swap = "swap"
        static let renameSet = "rename set"
        static let renameSetMessage = "1–100 characters."
        static let save = "save"
        static func setRenamed(_ name: String) -> String { "renamed to \(name)" }
        static let readOnly = "this channel lets you look, not edit"
        static func tileA11y(_ alias: String, name: String, renamed: Bool) -> String {
            renamed ? "\(alias), 7tv name \(name)" : alias
        }
        static func hitA11y(_ name: String, inSet: Bool) -> String { inSet ? "\(name), in this set" : name }
        static let addHintA11y = "tap to add to this set"

        // MARK: an emote

        static func ownName(_ name: String) -> String { "7tv name \(name)" }
        static func was(_ name: String) -> String { "was \(name)" }
        static let rename = "rename"
        static let copyToSet = "copy to set…"
        static let remove = "remove"
        static let aliasRule = "1–100 characters, no spaces"
        static func removeTitle(_ alias: String) -> String { "remove \(alias) from this set?" }
        static let removeMessage = "chat can't use it in this set any more. you can add it again from 7tv."
        static func removed(_ alias: String) -> String { "removed \(alias)" }
        static func renamed(_ alias: String) -> String { "renamed to \(alias)" }
        static func copied(_ alias: String, to set: String) -> String { "copied \(alias) to \(set)" }
        static let noOtherSets = "no other sets in this channel"

        // MARK: refusals

        /// The status line for a refused or failed 7TV call; 7TV's own words where it gave them.
        static func message(for error: Error) -> String {
            switch SevenTvError.from(error) {
            case .notLinked: return "link 7tv first"
            case .relink: return "7tv signed you out · link again"
            case .tokenInvalid: return "7tv didn't take that token · log in on 7tv.app and try again"
            case .forbidden(let words): return words ?? "this channel didn't give you that right"
            case .notFound: return "that isn't on 7tv any more"
            case .rateLimited: return "7tv says slow down · try again in a minute"
            case .rejected(let words): return words ?? "7tv said no to that"
            case .unavailable: return "7tv didn't answer · try again"
            case .notReady: return "7tv isn't ready on this server yet"
            case .off: return "7tv isn't on this server"
            case .offline: return "can't reach the server"
            case .other: return Copy.actionFailed
            }
        }
    }
}
