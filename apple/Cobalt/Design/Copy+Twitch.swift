import Foundation

/// Copy for the twitch tab (APP-API-CONTRACT 70; all new, lowercase): the channel list, the player, the chat and the composer.
/// Plain values only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum Twitch {
        static let title = "twitch"

        // MARK: the list

        static let searchPrompt = "channel name or twitch link"
        static let open = "watch"
        static let yourChannel = "your channel"
        static let liveNow = "live now"
        static let following = "following"
        static let recent = "recent"
        static let noneLive = "nobody you follow is live"
        static let loading = "loading twitch…"
        static let readOnlyTitle = "watching without signing in"
        static let readOnlyBody = "connect twitch in studio to chat as yourself and see who you follow."
        static let scopesTitle = "connect twitch again to chat"
        static let scopesBody = "studio's twitch connection was made before chat. connect it once more in studio and chat turns on."
        static let reconnectTitle = "twitch signed you out"
        static let reconnectBody = "connect twitch again in studio."
        static let openStudio = "open studio"
        static let playerSignIn = "sign in to twitch"
        static func viewers(_ n: Int) -> String {
            n >= 1000 ? String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(n)"
        }
        static let live = "live"
        static let offline = "offline"

        // MARK: watching

        static let back = "channels"
        static let clip = "clip last 30 s"
        static let clipping = "making the clip…"
        static let clipSaved = "clip saving to your library"
        static let clipFailed = "twitch didn't make the clip"
        static let openOnTwitch = "open on twitch"
        static let playingElsewhere = "playing on the other screen"

        // MARK: delay (70.4)

        static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }
        static func delay(_ s: Double) -> String { seconds(s) }
        static func behind(_ s: Double) -> String { "\(seconds(s)) behind" }
        static let jumpToLive = "jump to live"
        static let catchingUp = "catching up…"

        // MARK: on a tv (70.5)

        static let watchOnTV = "watch on the tv"
        static let tvTitle = "watch on the tv"
        static let close = "close"
        static let tvModeTitle = "tv mode"
        static let tvModeBadge = "best for chat"
        static let tvModeBody = "the stream fills the tv, chat stays here. about as far behind live as on the phone, so chat lines up. keep capystore open: locking the phone ends screen mirroring."
        static let tvModeSteps = ["swipe down from the top right", "tap screen mirroring", "pick your tv"]
        static let tvModeWaiting = "waiting for a tv… capystore switches by itself"
        static let tvModeUse = "put the stream on the tv"
        static let videoOnlyTitle = "video only"
        static let videoOnlyBody = "the tv plays the stream by itself, so you can lock the phone or use other apps. it runs several seconds behind, so chat waits to match."
        static let chatDelayTitle = "chat waits"
        static func chatDelay(_ s: Int) -> String { s == 0 ? "chat on time" : "chat waits \(s) s" }
        static func chatDelayChoice(_ s: Int) -> String { s == 0 ? "don't wait" : "\(s) s" }
        static let pickTV = "pick a tv"
        static let onTV = "on the tv"
        static let dim = "dim"
        static let undim = "undim"
        static let chatOnTV = "chat on tv"
        static let mirrorInstead = "mirror"
        static let tvBrand = "capystore"
        static let tvIdle = "pick a channel on the phone"
        static let toLive = "to live"

        // MARK: chat

        static let chat = "chat"
        static let connecting = "joining chat…"
        static func reconnecting(_ s: Int) -> String { "chat dropped, trying again in \(s) s" }
        static let failed = "chat can't connect"
        static let readOnlyChat = "read only"
        static let composerPrompt = "send a message"
        static let composerReadOnly = "connect twitch in studio to chat"
        static let send = "send"
        static let paused = "paused"
        static func newLines(_ n: Int) -> String { n == 1 ? "1 new message" : "\(n) new messages" }
        static let jumpDown = "back to live chat"
        static let reply = "reply"
        static let copyText = "copy message"
        static func replyingTo(_ name: String) -> String { "replying to @\(name)" }
        static let cancelReply = "cancel reply"
        static let deleted = "message deleted"
        static func slow(_ s: Int) -> String { "slow \(s) s" }
        static let emoteOnly = "emote only"
        static let subsOnly = "subs only"
        static let followersOnly = "followers only"
        static let addToSet = "add to a 7tv set…"
        static let emotes = "emotes"

        // MARK: emote picker (70.6)

        static let emoteSearch = "search emotes"
        static let emotesLoading = "loading emotes…"
        static let emotesNone = "no emotes here yet"
        static func emotesMiss(_ q: String) -> String { "no emote called \u{201C}\(q)\u{201D}" }
        static let recentEmotes = "recent"
        static let copyName = "copy name"
        static let locked = "subscribe to use"
        static let done = "done"
        static func channelSevenTv(_ channel: String) -> String { "\(channel) · 7tv" }
        static func channelTwitch(_ channel: String) -> String { "\(channel) · twitch" }
        static let yourTwitch = "your twitch emotes"
        static let twitchGlobal = "twitch global"
        static let sevenTvGlobal = "7tv global"
    }
}
