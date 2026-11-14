import CobaltKit
import Foundation

/// Copy for 7TV (APP-API-CONTRACT 57.7; all new, lowercase): the 7tv tab, the studio's shortcut row, the link sheet, the set
/// screen, the emote sheet, the name clash sheet and the refusals. Plain values only, since `Cobalt/Design` is compiled into the extensions too.
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
        static let unlinkMessageSession = "capystore forgets the token and ends its own 7tv session. your twitch, discord or kick login stays."
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

        // MARK: the login sheet (57.12)

        static let loginTitle = "log in with 7tv"
        static let loginNote = "7tv logs in through twitch, discord or kick. capystore keeps its own 7tv session."
        static let otherWays = "other ways to link"
        static let loginLoading = "loading…"
        static func loginLinked(_ name: String) -> String { name.isEmpty ? "linked" : "linked as \(name)" }
        static let loginPageA11y = "7tv login page"
        static let loginPlaceholder = "the 7tv login page shows here"
        static let forgetLogin = "forget 7tv login"
        static let loginForgotten = "7tv login forgotten"

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

        // MARK: uploading a picture (57.9)

        static let uploadAction = "upload to 7tv"
        static let uploadTitle = "upload to 7tv"
        static let uploadNew = "new emote"
        static let emoteName = "emote name"
        static let nameRule = "1–100 characters: letters, digits, emoji and _-():!+|.'?><*$#. no spaces."
        static let tooBigNote = "this file is over 7 mb · 7tv won't take it"
        static let tooWideNote = "this file is over 1000 px a side · 7tv won't take it"
        static let shrinkBytesNote = "over 7 mb · will be shrunk to fit"
        static let shrinkSideNote = "over 1000 px a side · will be shrunk to fit"
        static let needsCropNote = "7tv only keeps shapes from 1:32 to 3:1 · crop it first"
        static let sizeLabel = "size"
        static let sizeAuto = "auto"
        static func sizeChoice(_ px: Int?) -> String { px.map { "\($0)" } ?? sizeAuto }
        static let sizeNote = "longest side in px · auto keeps it unless it's too big"
        static let sizeA11y = "longest side"
        static let cropAction = "crop…"
        static let cropSet = "crop set"
        static func cropLine(_ width: Int, _ height: Int) -> String { "crop \(width)×\(height)" }
        static let clearCrop = "clear"
        static let useCrop = "use this crop"
        static let cropNote = "7tv gets the box only · turning, flipping and removing the background stay off"
        static let cropBoxOnly = "7tv crop takes the box only"
        static func sentAs(width: Int, height: Int, frames: Int, bytes: Int64) -> String {
            let kb = max(1, Int((Double(bytes) / 1024).rounded()))
            let frameWord = frames == 1 ? "1 frame" : "\(frames) frames"
            return "sent as \(width)×\(height) · \(frameWord) · \(kb) kb"
        }
        static let privateToggle = "private"
        static let privateNote = "only you see it on 7tv"
        static let zeroWidthToggle = "zero-width"
        static let zeroWidthNote = "sits on top of the emote before it in chat"
        static let addToSetToggle = "add to a set"
        static let noEditableChannels = "none of your channels lets you edit its sets"
        static let setLabel = "set"
        static func setChoice(_ name: String, live: Bool) -> String { live ? "\(name) · live" : name }
        static let uploadButton = "upload"
        static let uploading = "uploading…"
        static let processing = "processing on 7tv…"
        static let processingNote = "7tv makes its sizes first. this usually takes a minute; you can close this."
        static let ready = "ready on 7tv"
        static let stillProcessing = "7tv is still processing it · its page shows it once it's done"
        static let openOn7tv = "open on 7tv"
        static let done = "done"
        static func uploaded(_ name: String) -> String { "uploaded \(name) to 7tv" }
        static func addedTo(_ set: String) -> String { "added to \(set)" }
        static let addedToSet = "added to the set"
        static func addFailed(_ why: String) -> String { "uploaded, but not added to the set · \(why)" }

        // MARK: the 7tv tab (mockup `7tv-tab/`)

        static let segmentSets = "sets"
        static let segmentSearch = "search"
        static let segmentUpload = "upload"
        static let segmentsA11y = "what to show"
        static let accountMenuA11y = "7tv account"
        static func signsOutIn(days: Int?) -> String {
            switch days {
            case nil: return "linked"
            case 0?: return "linked · signs out today"
            case 1?: return "linked · signs out in 1 day"
            case let n?: return "linked · signs out in \(n) days"
            }
        }
        static let tabNotLinkedBody =
            "link your 7tv account to manage the emote sets of your channel and the channels you edit, and upload webps from your library."
        static let withoutLinking = "without linking"
        static let browseBody = "browse and save emotes into your library, like today"
        static let liveNow = "live now"
        static func emotesOf(_ count: Int, capacity: Int?) -> String {
            capacity.map { "\(count) of \($0) emotes" } ?? (count == 1 ? "1 emote" : "\(count) emotes")
        }
        static func emotesLine(_ count: Int, capacity: Int?, channel: String) -> String {
            channel.isEmpty ? emotesOf(count, capacity: capacity) : "\(emotesOf(count, capacity: capacity)) · \(channel)"
        }
        static let noLiveSet = "no live set in this channel"
        static let otherSets = "other sets"
        static let allSets = "sets"
        static let seeSet = "see all"
        static func seeSetA11y(_ name: String) -> String { "open \(name)" }
        static let addingTo = "adding to"
        static let pickSet = "pick a set"
        static let noEditableSet = "no set here you can edit · pick another channel or make a set"
        static let uploadIntro = "animated webps and gifs from your library · tap one to name it, crop it and send it to 7tv"
        static let onSevenTv = "on 7tv"
        static let yourUploads = "your uploads"
        static let noUploads = "nothing uploaded from capystore yet"
        static let noLibraryPictures = "no webps or gifs in your library yet · make one from a video in the library"
        static let loadingLibrary = "loading your library…"
        static let uploadNeedsLink = "link 7tv to upload"
        static let processingPill = "processing"
        static let readyPill = "ready"
        static let gonePill = "not on 7tv"
        static func uploadLine(set: String?, ago: String?) -> String {
            switch (set, ago) {
            case let (set?, ago?): return "added to \(set) · \(ago)"
            case let (set?, nil): return "added to \(set)"
            case let (nil, ago?): return "uploaded \(ago)"
            default: return "uploaded"
            }
        }
        static func libraryTileA11y(_ name: String, onSevenTv: Bool) -> String { onSevenTv ? "\(name), on 7tv" : name }
        static func uploadRowA11y(_ name: String, state: String) -> String { "\(name), \(state)" }
        /// "2 min. ago", "3 days ago".
        static func ago(_ date: Date, now: Date) -> String {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return f.localizedString(for: min(date, now), relativeTo: now)
        }

        // the Mac's middle column
        static let more = "more"
        static let searchSevenTv = "search 7tv"
        static let uploadFromLibrary = "upload from library"
        static let addEmotes = "add emotes"
        static let pickASet = "pick a set on the left"

        // the studio tab's row
        static let shortcutBody = "emote sets, search and uploads"
        static let shortcutNotLinked = "link 7tv to manage your emote sets"
        static let shortcutA11y = "open the 7tv tab"

        // MARK: picking several

        static let select = "select"
        static let doneSelecting = "done"
        static func selected(_ n: Int) -> String { "\(n) selected" }
        static let copyTo = "copy to…"
        static func removeN(_ n: Int) -> String { "remove \(n)" }
        static func removeManyTitle(_ n: Int) -> String { n == 1 ? "remove 1 emote from this set?" : "remove \(n) emotes from this set?" }
        static func copiedMany(_ n: Int, to set: String) -> String { n == 1 ? "copied 1 emote to \(set)" : "copied \(n) emotes to \(set)" }
        static func removedMany(_ n: Int) -> String { n == 1 ? "removed 1 emote" : "removed \(n) emotes" }
        static func alreadyThere(_ n: Int) -> String { n == 1 ? "1 name was already there" : "\(n) names were already there" }
        static let selectHintA11y = "hold to pick several"
        static let pickA11y = "pick"

        // MARK: the emote sheet

        static func sevenTvNameLine(_ name: String, animated: Bool) -> String {
            animated ? "7tv name: \(name) · animated" : "7tv name: \(name)"
        }
        static let aliasRuleLong = "letters, digits and _-():!+|.'?> · no spaces"
        static let saveName = "save name"
        static func resetTo(_ name: String) -> String { "reset to \(name)" }

        // MARK: name clashes

        static func clashTitle(_ alias: String, set: String) -> String {
            set.isEmpty ? "\"\(alias)\" is already in that set" : "\"\(alias)\" is already in \(set)"
        }
        static let inTheSetNow = "in the set now"
        static let addingNow = "adding"
        static func addedAgo(_ ago: String) -> String { "added \(ago)" }
        static let pickOne = "pick one"
        static let addUnderOther = "add it under another name"
        static let renameExisting = "rename the one in the set"
        static func renameExistingNote(_ alias: String) -> String { "then add the new one as \(alias)" }
        static let replaceIt = "replace it"
        static let replaceNote = "the old one leaves the set"
        static func addAs(_ name: String) -> String { "add as \(name)" }
        static let renameAndAdd = "rename and add"
        static let replace = "replace"
        static let unknownEmote = "another emote"

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
            case .nameTaken(_, let alias): return alias.map { "\($0) is already in this set" } ?? "that name is already in this set"
            case .unavailable: return "7tv didn't answer · try again"
            case .notReady: return "7tv isn't ready on this server yet"
            case .fileNotFound: return "that file isn't in the library any more"
            case .fileType: return "7tv takes webp, gif, png, avif and jpeg"
            case .tooBig: return "too big for 7tv even shrunk · pick a smaller size or a crop"
            case .tooLarge: return "7tv only keeps shapes from 1:32 to 3:1 · pick a crop box"
            case .fitFailed(let words): return words.map { "couldn't fit it for 7tv · \($0)" } ?? "couldn't fit it for 7tv · try again"
            case .busy: return "the server is fitting another picture · try again in a minute"
            case .off: return "7tv isn't on this server"
            case .offline: return "can't reach the server"
            case .other: return Copy.actionFailed
            }
        }
    }
}
