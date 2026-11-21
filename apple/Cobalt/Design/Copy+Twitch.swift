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
    }
}
