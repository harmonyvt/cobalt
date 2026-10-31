import Foundation

/// Copy for timed subtitles (APP-API-CONTRACT 47): the CC button, where the subtitles go, the timed "heard" list and the
/// search's "said in it" strip. All lowercase. Its own file so `Copy.swift` stays untouched; shared with the extensions,
/// so plain strings only.
extension Copy {
    enum Subtitles {
        static let turnOn = "subtitles on"
        static let turnOff = "subtitles off"
        static let place = "where subtitles go"
        static let underVideo = "under the video"
        static let onPicture = "on the picture"
        /// The timed "heard" list's hint.
        static let tapToJump = "tap a line to jump"
        static let copyText = "copy text"
        static let copySrt = "copy .srt"
        static let copied = "copied"
        /// The search's strip of results said in their video.
        static let saidInIt = "said in it"
        static let byMeaning = "by meaning"
        /// "0:12 · bring the tail", read out.
        static func jumpTo(_ time: String, _ text: String) -> String { "play from \(time): \(text)" }
        static func lineA11y(_ time: String, _ text: String) -> String { "\(time), \(text)" }
        /// The strip under the video while nothing is being said.
        static let quiet = "…"
    }
}
