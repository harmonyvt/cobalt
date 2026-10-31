import Foundation

// Timed transcripts (APP-API-CONTRACT 47; `features.transcripts`): `GET /library/transcript?key=<post key>` answers what was
// said in a post's video as subtitle lines, each word with its own time, for the detail's subtitles (under the video or on
// the picture) and its timed "heard" list. Search hits carry `said`: where the query was said, or the moment that matched by
// meaning (`LibrarySearchResult.Said`). Every field but the key is optional on the wire.

/// One answer of `GET /library/transcript`.
public struct LibraryTranscript: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Equatable {
        /// Heard: `lines` holds what was said.
        case done
        /// Heard, and nothing was said (music, noise).
        case noSpeech = "no_speech"
        /// Not heard yet (usually within 15 minutes of a save).
        case pending
        /// Nothing to hear: a picture, or a video without sound.
        case noSound = "no_sound"
        /// Hearing it failed three times.
        case failed
        /// The server does not hear sound (no Whisper).
        case off
        /// A state this app does not know yet.
        case unknown
    }

    public struct Word: Sendable, Equatable, Decodable {
        public var text: String
        /// Seconds from the start of the clip.
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One subtitle line (at most about 84 characters and 6 s).
    public struct Line: Sendable, Equatable, Decodable {
        public var start: Double
        public var end: Double
        public var text: String
        /// Each word with its time; empty when the server sent none (the line then lights up as a whole).
        public var words: [Word]

        public init(start: Double, end: Double, text: String, words: [Word] = []) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
        }

        enum CodingKeys: String, CodingKey { case start, end, text, words }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            end = max(start, (try? c.decodeIfPresent(Double.self, forKey: .end)) ?? start)
            text = try c.decode(String.self, forKey: .text)
            words = ((try? c.decodeIfPresent([Lossy<Word>].self, forKey: .words)) ?? nil)?.compactMap(\.value) ?? []
        }
    }

    public var postKey: String
    public var state: State
    public var language: String?
    /// In time order.
    public var lines: [Line]

    public init(postKey: String, state: State, language: String? = nil, lines: [Line] = []) {
        self.postKey = postKey
        self.state = state
        self.language = language
        self.lines = lines
    }

    enum CodingKeys: String, CodingKey { case postKey, state, language, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postKey = try c.decode(String.self, forKey: .postKey)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil
        state = raw.flatMap(State.init(rawValue:)) ?? .unknown
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil
        let decoded = ((try? c.decodeIfPresent([Lossy<Line>].self, forKey: .lines)) ?? nil)?.compactMap(\.value) ?? []
        lines = decoded.sorted { $0.start < $1.start }
    }

    /// There is something to show as subtitles.
    public var hasLines: Bool { state == .done && !lines.isEmpty }

    /// How long a line stays up after it ends, so a short pause does not flash the subtitles away.
    public static let linger: Double = 0.6

    /// The line on screen at `time`: the last one started by then, while it lasts (plus `linger`, never past the next
    /// line's start). Nil between lines and before the first.
    public func lineIndex(at time: Double) -> Int? {
        guard time.isFinite, !lines.isEmpty else { return nil }
        // the last line whose start is at or before `time`
        var lo = 0
        var hi = lines.count - 1
        var found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard found >= 0 else { return nil }
        let line = lines[found]
        var until = line.end + Self.linger
        if found + 1 < lines.count { until = min(until, lines[found + 1].start) }
        return time <= max(line.end, until) ? found : nil
    }

    /// The line `time` falls in or most recently passed (for the "heard" list's highlight, which never goes blank).
    public func lastLineIndex(at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        return lines.lastIndex { $0.start <= time }
    }

    /// The whole transcript as a SubRip (.srt) file, one cue per line.
    public func srt() -> String {
        lines.enumerated().map { i, l in
            "\(i + 1)\n\(Self.srtTime(l.start)) --> \(Self.srtTime(max(l.end, l.start + 0.5)))\n\(l.text)\n"
        }.joined(separator: "\n")
    }

    /// "00:01:02,345".
    static func srtTime(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Decodes an answer body (snake case) the way the HTTP client does.
    static func decode(_ data: Data) throws -> LibraryTranscript {
        try CobaltJSON.decoder().decode(LibraryTranscript.self, from: data)
    }
}

extension LibraryTranscript.Line {
    /// Where a word stands at `time`: said already, being said, or still to come.
    public enum WordPhase: Sendable, Equatable { case said, now, coming }

    public func phase(of word: LibraryTranscript.Word, at time: Double) -> WordPhase {
        if time >= word.end { return .said }
        if time >= word.start { return .now }
        return .coming
    }
}

/// A search hit's `said` (APP-API-CONTRACT 47.5): where in the video the query was said, or the moment closest to it.
public struct LibrarySaid: Sendable, Equatable, Decodable {
    public enum Match: String, Sendable, Equatable {
        /// The line holds the query's words.
        case words
        /// The moment reads closest to the query (no exact words).
        case meaning
        case unknown
    }

    public var start: Double
    public var end: Double
    public var text: String
    public var match: Match

    public init(start: Double, end: Double, text: String, match: Match) {
        self.start = start
        self.end = end
        self.text = text
        self.match = match
    }

    enum CodingKeys: String, CodingKey { case start, end, text, match }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = (try? c.decodeIfPresent(Double.self, forKey: .end)) ?? start
        text = try c.decode(String.self, forKey: .text)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .match)) ?? nil
        match = raw.flatMap(Match.init(rawValue:)) ?? .unknown
    }
}

/// A moment to open a video at: the detail of `postKey` starts playing at `seconds`, subtitles on (a search's "said at").
public struct PendingMoment: Sendable, Equatable {
    public var postKey: String
    public var seconds: Double
    public let token = UUID()

    public init(postKey: String, seconds: Double) {
        self.postKey = postKey
        self.seconds = seconds
    }
}
