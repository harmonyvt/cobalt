import Foundation

/// Validation, character-limit, and token-completion rules for Twitch IRC chat messages (500-char `PRIVMSG` cap).
public enum TwitchChatComposerRules {
    /// Twitch IRC `PRIVMSG` payload character limit.
    public static let maxLength = 500
    /// Character threshold where the composer counter switches to an amber caution state.
    public static let cautionThreshold = 420

    public enum CounterTone: Equatable, Sendable {
        case normal
        case caution
        case overLimit
    }

    /// Flattens multi-line input into a single IRC-safe line while trimming outer whitespace.
    public static func preparedForSend(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return flattened.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live character count matching what Twitch IRC receives (`\r\n` counts as 1 separator space).
    public static func characterCount(_ raw: String) -> Int {
        raw.replacingOccurrences(of: "\r\n", with: " ").count
    }

    public static func remainingCharacters(_ raw: String, limit: Int = maxLength) -> Int {
        limit - characterCount(raw)
    }

    public static func tone(for raw: String, limit: Int = maxLength) -> CounterTone {
        let count = characterCount(raw)
        if count > limit { return .overLimit }
        if count >= cautionThreshold { return .caution }
        return .normal
    }

    public static func canSend(_ raw: String, limit: Int = maxLength) -> Bool {
        let prepared = preparedForSend(raw)
        return !prepared.isEmpty && prepared.count <= limit
    }

    /// Returns the token currently being typed after the last whitespace or newline, for emote autocomplete.
    public static func currentToken(in raw: String) -> Substring {
        guard let splitIdx = raw.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
            return raw[...]
        }
        return raw[raw.index(after: splitIdx)...]
    }

    /// Replaces the current trailing token with `replacement + " "`, preserving preceding lines and spaces.
    public static func replacingCurrentToken(in raw: String, with replacement: String) -> String {
        guard let splitIdx = raw.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
            return replacement + " "
        }
        let prefix = raw[...splitIdx]
        return "\(prefix)\(replacement) "
    }
}
