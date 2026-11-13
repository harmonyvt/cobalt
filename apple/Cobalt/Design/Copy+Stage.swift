import CobaltKit
import Foundation

/// Copy for the studio tab (APP-API-CONTRACT section 30; all new, lowercase): the header, the preview, the spotlight bar and
/// its pool sheet, the pool picker, the sliders, Twitch, the rewards, the redemptions feed and the links with the store lock.
/// The code says "stage"; only the words on screen say "studio". Plain values only (counts, dates, CobaltKit types), since
/// `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum Stage {
        static let title = "studio"

        // MARK: loading

        static let loading = "loading the studio…"
        static let failedTitle = "can't load the studio"
        static let retry = "try again"
        static let refresh = "refresh"
        static func failedBody(_ error: StageError) -> String {
            switch error {
            case .off: return "the studio is off on this server"
            case .unavailable: return "the server can't do that right now"
            case .offline: return "can't reach the server"
            default: return "something went wrong"
            }
        }
        /// Above the screen when a refresh failed but the last values are still shown.
        static let staleLine = "can't reach the server · showing the last values"

        // MARK: header and preview

        static let onAir = "on air"
        static let offAir = "off air"
        static let goLive = "go live"
        static let stop = "stop"
        static let copyObsLink = "copy obs link"
        static let copied = "copied"
        static let previewCaption = "preview · what obs sees"
        static let previewSize = "1920 × 1080"
        static let previewOffTitle = "off air"
        static let previewOffBody = "obs shows an empty, see-through canvas until you go live."
        static let previewA11y = "preview of the stream canvas"
        static func airA11y(onAir: Bool) -> String { onAir ? "the canvas is on air" : "the canvas is off air" }

        // MARK: the spotlight bar

        static let spotlight = "spotlight"
        static func spotlightBy(_ name: String) -> String { "spotlight · summoned by @\(name)" }
        static let spotlightOwner = "spotlight · your pick"
        static let spotlightNone = "nothing in the spotlight"
        static let spotlightNoneBody = "a summon or your pick takes it, then it clears."
        static let spotlightOffAir = "go live to use the spotlight"
        static let soundOn = "sound on"
        static let muted = "muted"
        static let soundA11yHint = "whether the spotlight plays its sound on stream"
        static let pin = "pin"
        static let pinned = "pinned"
        static let skip = "skip"
        static let pick = "pick"
        static let more = "more"
        static let shuffle = "shuffle the canvas"
        static let chaos = "chaos for 30 s"
        static func codeA11y(_ code: String) -> String { "code \(code)" }

        // MARK: the pick sheet

        static let pickTitle = "pick for the spotlight"
        static let pickLoading = "loading files…"
        static let pickEmpty = "nothing public in this pool"
        static let pickVideosEmpty = "the spotlight is videos only"
        static let pickFailed = "can't load the pool"
        static let pickMore = "load more"
        static let done = "done"
        static func pickCount(_ total: Int) -> String { "\(total) \(total == 1 ? "video" : "videos")" }
        static func pickItemA11y(title: String, kind: StageItem.Kind) -> String {
            "\(title), \(kind == .video ? "video" : "photo")"
        }
        static let pickItemHint = "puts it in the spotlight"

        // MARK: the pool

        static let pool = "pool"
        static let poolNote = "what the canvas and the store draw from. private items never show."
        static let poolPhoneNote = "private never shows"
        static let poolCollection = "collection"
        static let poolSet = "set"
        static let poolSearch = "search"
        static let poolLibrary = "whole library"
        static let poolLibraryNote = "everything in your library, minus anything private."
        static let poolPicker = "pool"
        static let chooseCollection = "choose a collection"
        static let chooseSet = "choose a set"
        static let noCollections = "no collections yet · make one in the links tab"
        static let noSets = "no sets yet · make one in the links tab"
        static let change = "change"
        static let searchPlaceholder = "words to search for"
        static let searchUse = "use these words"
        static let searchNote = "finds files by what they show"
        static let searchUnavailable = "search is asleep · try a collection, or try again in a bit"
        static let poolMissing = "that one is gone · the canvas is empty"
        static func poolCount(_ count: Int) -> String { "\(count) \(count == 1 ? "file" : "files")" }
        static func poolWords(_ words: String) -> String { "“\(words)”" }
        static func wordsCount(_ count: Int) -> String { "\(count) of \(StageRule.searchLimit)" }

        // MARK: sliders

        static let howCrazy = "how crazy"
        static func onScreen(_ count: Int) -> String { count == 0 ? "redeems only" : "\(count) on screen" }
        static let calm = "calm"
        static let chaosWord = "chaos"
        static let tileLife = "tile life"
        static func eachSeconds(_ seconds: Int) -> String { "\(seconds) s each" }
        static let flicker = "flicker"
        static let linger = "linger"
        static let playThrough = "play videos through"
        static let playThroughNote = "a video stays until it has played once, even past its time"
        static let soundAll = "unmute all videos"
        static let soundAllNote = "every playing video has sound on stream, not only the spotlight"
        static let moreOptions = "more"
        static let tileSize = "tile size"
        static func sizeValue(_ scale: Double) -> String { String(format: "×%.1f", scale) }
        static let small = "small"
        static let large = "large"
        static let spotlightTime = "spotlight time"
        static func spotlightSecondsValue(_ seconds: Int) -> String { "\(seconds) s" }
        static let videosAtOnce = "videos at once"
        static func videosValue(_ count: Int) -> String { count == 0 ? "none" : "\(count)" }
        static let few = "few"
        static let many = "many"
        static let spotlightAuto = "auto spotlight"
        static let spotlightAutoNote = "the canvas picks one now and then by itself"

        // MARK: Twitch

        static let twitch = "twitch"
        static func connectedAs(_ name: String) -> String { "connected as \(name)" }
        static let listening = "listening for redemptions. viewers never need the app."
        static let notConnected = "not connected"
        static let notConnectedBody = "connect your channel so viewers can spend channel points on the canvas."
        static let connect = "connect twitch"
        static let reconnect = "reconnect"
        static let disconnect = "disconnect"
        static let connecting = "waiting for twitch…"
        static let disconnectTitle = "disconnect twitch?"
        static let disconnectMessage = "the five rewards leave your channel, and viewers can't redeem until you connect again."
        static let keep = "keep"
        static let needsReconnect = "twitch needs you to sign in again"
        static let notAffiliate = "channel points need an affiliate channel"
        static let settingUp = "setting up your rewards…"
        static let connectedToast = "twitch connected"
        static let disconnectedToast = "twitch disconnected"
        static func connectFailed(reason: String?) -> String {
            switch reason {
            case "denied", "access_denied": return "twitch wasn't allowed · try again"
            case "twitch_off": return "twitch isn't set up on this server"
            default: return "couldn't connect twitch · try again"
            }
        }
        static func lastRedemption(_ when: String) -> String { "last redemption \(when)" }

        // MARK: rewards

        static let rewards = "rewards"
        static let rewardsNote = "these are real twitch rewards; changing a cost here changes it on twitch."
        static let rewardsEmpty = "connect twitch to make the five rewards"
        static func rewardName(_ kind: StageRewardKind) -> String { kind == .song ? "song request" : kind.rawValue }
        static func rewardInfo(_ kind: StageRewardKind) -> String {
            switch kind {
            case .summon: return "search the pool, best match takes the spotlight"
            case .chaos: return "100 on screen for 30 seconds"
            case .shuffle: return "wipe the canvas and refill it"
            case .pin: return "keep the spotlight up 2 more minutes"
            case .skip: return "clear the spotlight"
            case .song: return "a spotify or youtube link, or the song and artist"
            }
        }
        static func rewardLine(cost: Int, cooldownSeconds: Int) -> String {
            "\(points(cost)) pts · \(cooldown(cooldownSeconds))"
        }
        static let unsynced = "twitch hasn't got the latest yet · it tries again"
        static func rewardToggleA11y(_ kind: StageRewardKind, on: Bool) -> String {
            "\(on ? "turn off" : "turn on") \(rewardName(kind))"
        }
        static let editHint = "edit cost and cooldown"
        static let editCost = "cost"
        static let editCooldown = "cooldown"
        static let editPoints = "channel points"
        static let editSeconds = "seconds"
        static let editSave = "save"
        static let editCancel = "cancel"
        static func editTitle(_ kind: StageRewardKind) -> String { "edit \(rewardName(kind))" }
        static func costRange() -> String {
            "\(points(StageRule.costRange.lowerBound)) to \(points(StageRule.costRange.upperBound))"
        }
        static func cooldownRange() -> String {
            "\(StageRule.cooldownRange.lowerBound) to \(points(StageRule.cooldownRange.upperBound)) seconds"
        }

        /// "2,000": grouped in threes, whatever the locale.
        static func points(_ value: Int) -> String {
            let digits = String(abs(value))
            var out = ""
            for (i, ch) in digits.reversed().enumerated() {
                if i > 0, i % 3 == 0 { out.append(",") }
                out.append(ch)
            }
            return (value < 0 ? "-" : "") + String(out.reversed())
        }

        /// "30 s", "5 min", "2 h", "no cooldown".
        static func cooldown(_ seconds: Int) -> String {
            if seconds <= 0 { return "no cooldown" }
            if seconds < 120 { return "\(seconds) s" }
            if seconds < 3_600 { return "\(Int((Double(seconds) / 60).rounded())) min" }
            if seconds % 3_600 == 0 { return "\(seconds / 3_600) h" }
            if seconds < 86_400 { return "\(Int((Double(seconds) / 60).rounded())) min" }
            return "\(Int((Double(seconds) / 86_400).rounded())) d"
        }

        // MARK: the feed

        static let feed = "redemptions"
        static let feedTab = "feed"
        static let feedEmpty = "nothing yet · what viewers redeem shows up here"
        static let feedProblem = "can't reach the server · showing the last list"
        static let you = "you"
        static func by(_ name: String, owner: Bool) -> String { owner ? you : "@\(name)" }
        static func ago(_ date: Date, now: Date) -> String {
            let s = max(0, Int(now.timeIntervalSince(date)))
            if s < 10 { return "now" }
            if s < 60 { return "\(s) s" }
            if s < 3_600 { return "\(s / 60) min" }
            if s < 86_400 { return "\(s / 3_600) h" }
            return "\(s / 86_400) d"
        }
        static func reason(_ reason: StageRedemption.Reason?) -> String {
            switch reason {
            case .offAir: return "it was off air"
            case .noMatch: return "no match"
            case .disabled: return "that reward was off"
            case .error: return "something went wrong"
            case .noEffect: return "nothing to do"
            case nil: return "didn't work"
            }
        }

        /// One line under a redemption: what it did, or why it was refunded.
        static func detail(_ r: StageRedemption) -> String {
            switch r.status {
            case .refunded: return "\(what(r)) · \(reason(r.reason)) · refunded"
            case .failed: return "\(what(r)) · \(reason(r.reason))"
            case .done: return what(r)
            }
        }

        private static func what(_ r: StageRedemption) -> String {
            switch r.action {
            case "summon":
                let typed = r.input.map { "“\($0)”" }
                switch (typed, r.item) {
                case (let t?, let item?): return "\(t) → \(item.title)"
                case (let t?, nil): return t
                case (nil, let item?): return item.title
                case (nil, nil): return "summon"
                }
            case "chaos": return "100 on screen for 30 s"
            case "shuffle": return "refilled the canvas"
            case "pin": return "kept the spotlight up"
            case "skip": return "skipped the spotlight"
            case "unpin": return "let the spotlight go"
            case "spotlight": return r.item.map { "put \($0.title) up" } ?? "picked a file"
            default: return r.action
            }
        }
        static func rowA11y(_ r: StageRedemption, when: String) -> String {
            "\(by(r.userName, owner: r.isOwner)), \(r.action), \(detail(r)), \(when)"
        }

        // MARK: links

        static let links = "links"
        static let linksTab = "links"
        static let obsLink = "obs browser source · 1920 × 1080"
        static let copy = "copy"
        static let rotate = "rotate"
        static let rotateTitle = "rotate the obs link?"
        static let rotateMessage = "the old one stops working right away."
        static let rotated = "new link copied. the old one stopped working; paste this into obs."
        static let linkCopied = "link copied"
        static let obsCopied = "obs link copied"
        static let storeForViewers = "store for viewers"
        static let storePublic = "public"
        static let storeLocked = "locked"
        static let storeOpen = "store open"
        static let storeLockedNote = "locked: the store and its sign-in are gone until you open it"
        static let storeOpenNote = "open: viewers can sign in with twitch and browse the store"
        static let copyStoreLink = "copy store link"

        // MARK: the wallpaper (macOS)

        static let wallpaper = "wallpaper on this mac"
        static let wallpaperNote = "the canvas behind your desktop icons on every display, silent. it keeps going while the stream is off."
        static let wallpaperMenu = "studio wallpaper"

        // MARK: music (APP-API-CONTRACT 56.7)

        static let music = "music"
        static let musicNote = "your spotify is the player. the canvas shows what plays, viewers can ask for songs, and it turns down for summons."
        static let spotifyNotConnectedBody = "connect spotify to show what's playing and take song requests."
        static let connectSpotify = "connect spotify"
        static let connectAgain = "connect again"
        static let disconnectSpotifyTitle = "disconnect spotify?"
        static let disconnectSpotifyMessage = "the canvas stops showing the music and song requests stop. songs already in spotify's queue stay."
        static let spotifyConnectedToast = "spotify connected"
        static let spotifyDisconnectedToast = "spotify disconnected"
        static let premiumNote = "spotify needs premium for requests"
        static let spotifyNeedsReconnect = "spotify needs you to sign in again"
        static func connectedAsSpotify(_ name: String) -> String { name.isEmpty ? "spotify connected" : "connected as \(name)" }
        static func spotifyConnectFailed(reason: String?) -> String {
            switch reason {
            case "denied": return "spotify wasn't allowed · try again"
            case "scope": return "spotify needs every permission it asks for · try again"
            case "off": return "spotify isn't set up on this server"
            default: return "couldn't connect spotify · try again"
            }
        }

        static let nowPlaying = "now playing"
        static let paused = "paused"
        static let nothingPlaying = "nothing is playing"
        static func nowPlayingLine(artist: String, by: String?) -> String {
            var parts: [String] = []
            if !artist.isEmpty { parts.append(artist) }
            if let by { parts.append("requested by @\(by)") }
            return parts.joined(separator: " · ")
        }
        static func nowPlayingA11y(title: String, line: String, playing: Bool) -> String {
            "\(playing ? nowPlaying : paused), \(title), \(line)"
        }

        static let musicCard = "card on the canvas"
        static func cardName(_ card: StageMusic.Card) -> String { card.rawValue }
        static let upNextToggle = "show up next"
        static let upNextToggleNote = "the card lists the songs waiting"
        static let songRequests = "song requests"
        static let songRequestsNote = "a channel point reward: a link, or the song and artist"
        static let songNeedsTwitch = "connect twitch so viewers can redeem it"
        static let youtubeLinks = "youtube links"
        static let youtubeLinksNote = "a youtube link is matched to the song on spotify"
        static let longestSong = "longest song"
        static func songLength(_ seconds: Int) -> String { seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s" }
        static func waitingAtMost(_ count: Int) -> String { "waiting at most \(count)" }
        static let waitingAtMostA11y = "requests that may wait"
        static let explicitSongs = "explicit songs"
        static let explicitSongsNote = "off: an explicit request is refunded"
        static let duckToggle = "turn music down on summons"
        static let duckToggleNote = "while a summoned video plays with sound. needs premium; phones can't be turned down."
        static let duckTo = "down to"
        static func percent(_ value: Int) -> String { "\(value)%" }

        static let upNext = "up next"
        static let upNextEmpty = "nothing waiting"
        static func upNextCount(_ count: Int, max: Int) -> String { "\(count) of \(max)" }
        static let fromYouTube = "from youtube"
        static func requestedBy(_ name: String) -> String { name.isEmpty ? "" : "@\(name)" }
        static let skipCurrent = "skip current"
        static let skipHint = "plays the next song on spotify"

        // MARK: refusals

        /// The status line for a refused or failed studio call.
        static func message(for error: Error) -> String {
            switch StageError.from(error) {
            case .badRequest: return "that didn't work · check what you typed"
            case .off: return "the studio is off on this server"
            case .notFound: return "that file isn't in the pool any more"
            case .twitchOff: return "twitch isn't set up on this server"
            case .offAir: return "go live first"
            case .videosOnly: return "the spotlight is videos only"
            case .searchUnavailable: return searchUnavailable
            case .spotifyOff: return "spotify isn't set up on this server"
            case .spotifyNotConnected: return "connect spotify first"
            case .spotifyNoDevice: return "spotify isn't on · start playing something"
            case .spotifyPremium: return premiumNote
            case .spotifyReconnect: return "spotify needs you to sign in again"
            case .spotify: return "spotify said no · try again"
            case .unavailable: return "the server can't do that right now"
            case .offline: return "can't reach the server"
            case .other: return Copy.actionFailed
            }
        }
    }
}
