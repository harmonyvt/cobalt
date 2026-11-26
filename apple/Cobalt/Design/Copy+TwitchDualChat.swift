import Foundation

/// Copy for combined dual-stream Twitch chat (filter bar, foolproof target selector, off-focus banner, and row badges).
/// Plain values only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum TwitchDualChat {
        static let filterAll = "all"
        static func channelHandle(_ name: String) -> String { "@\(name)" }
        static let sendTargetMenu = "choose chat channel"
        static func sendingTo(_ name: String) -> String { "send to @\(name)" }
        static let bothChannels = "both chats"
        static let bothShort = "both"
        static let sendToBoth = "send to 2"
        static func composerPrompt(_ name: String) -> String { "message @\(name)" }
        static let composerPromptBoth = "message both chats"
        static func notInFocus(_ name: String) -> String { "→ \(name) · not in focus" }
        static func fromChannel(_ name: String) -> String { "from \(name)" }
        static let tapToReplyHint = "tap to reply"
    }
}
