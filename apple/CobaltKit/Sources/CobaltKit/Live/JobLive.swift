import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// One Live Activity for every job (apple/CONTRACT-JOBLIVE.md). The server writes every word the island shows
// (deploy/cloudflare/api/src/job-live.ts: `jobOfSave`, `jobOfEdit`, `jobOfChat`); the widget only draws it. This file has the
// two wire types, `JobLiveAttributes` and `JobLiveState`, and the local builders for jobs the app shows without a push (the
// app's save, edit and chat states turned into the same words, line for line with the server). The fixture
// `deploy/cloudflare/api/test/fixtures/job-live-states.json` pins both: `JobLiveTests` decodes it, re-encodes it byte for
// byte, and runs each builder against it.
//
// All of it compiles on every platform, so the macOS `swift test` run covers it; only `CobaltJobActivityAttributes` (the
// ActivityKit type) is iOS only.

// MARK: - the wire types

/// The activity's fixed attributes (CONTRACT-JOBLIVE.md 2). JSON keys are the Swift names.
public struct JobLiveAttributes: Codable, Hashable, Sendable {
    /// The run id (save/webp run uuid, editor render id, chat thread id).
    public var id: String
    /// "save" | "upload" | "make" | "edit" | "chat" (and "many" for the phone's busy period, 2.1).
    public var kind: String
    /// The source line: "twitch · KindStupidClip", "IMG_0412.mov", "edit · birthday cut".
    public var title: String
    /// Started by the chat agent or an MCP client: draws the "agent" chip.
    public var agent: Bool
    /// A deep link a tap opens (`cobalt-apple://...`).
    public var open: String?

    public init(id: String, kind: String, title: String, agent: Bool = false, open: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.agent = agent
        self.open = open
    }

    /// The attributes as compact JSON in the server's key order (id, kind, title, agent, open), `open` left out when nil.
    /// This is what the server writes into a push-to-start's `attributes`; see `JobLiveState.canonicalJSON()`.
    public func canonicalJSON() -> String {
        var parts = [
            "\"id\":" + JobJSON.string(id),
            "\"kind\":" + JobJSON.string(kind),
            "\"title\":" + JobJSON.string(title),
            "\"agent\":" + (agent ? "true" : "false"),
        ]
        if let open { parts.append("\"open\":" + JobJSON.string(open)) }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

/// What the island shows right now (CONTRACT-JOBLIVE.md 2). JSON keys are the Swift names, absent optionals are omitted
/// (never `null`), unknown keys are ignored, and times are unix seconds (a `Date` would decode wrongly on the push path).
public struct JobLiveState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case waiting, working, quiet, done, failed, lost

        /// An unknown phase (a newer server) reads as `working`: the island keeps its clock and does not end.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Phase(rawValue: raw) ?? .working
        }

        public var isTerminal: Bool { self == .done || self == .failed || self == .lost }
    }

    /// One line of the "several jobs at once" activity (2.1). The server never sends these.
    public struct Row: Codable, Hashable, Sendable {
        public var title: String
        public var status: String
        public var phase: Phase

        public init(title: String, status: String, phase: Phase) {
            self.title = title
            self.status = status
            self.phase = phase
        }
    }

    public var phase: Phase
    /// 1...5 short lowercase names, in order ("download", "store").
    public var steps: [String]
    /// The index of the current step; `steps.count` when done.
    public var step: Int
    /// At most 60 characters: "downloading from twitch".
    public var headline: String
    /// At most 90 characters: "4.2 MB of 9.1 MB", "frame 42 of 150", the failure reason.
    public var detail: String?
    /// 0...1 for the bar and the compact ring; nil is indeterminate (working) or no bar.
    public var fraction: Double?
    /// At most 7 characters, the compact island's trailing text: "46%", "42/150", "3".
    public var compact: String?
    /// Unix seconds the clock counts from.
    public var since: Double
    /// Done: "1280×720 · 30 s · 8.9 MB".
    public var result: String?
    /// Done: a URL to copy (webp, share link); draws "copy link".
    public var link: String?
    /// Several jobs at once (2.1).
    public var rows: [Row]?

    public init(
        phase: Phase, steps: [String], step: Int, headline: String, detail: String? = nil, fraction: Double? = nil,
        compact: String? = nil, since: Double, result: String? = nil, link: String? = nil, rows: [Row]? = nil
    ) {
        self.phase = phase
        self.steps = steps
        self.step = step
        self.headline = headline
        self.detail = detail
        self.fraction = fraction
        self.compact = compact
        self.since = since
        self.result = result
        self.link = link
        self.rows = rows
    }

    public var isTerminal: Bool { phase.isTerminal }
}

// MARK: - byte-exact JSON

/// Why `canonicalJSON()` is hand written: `JSONEncoder` gives no key order (the best it offers is `.sortedKeys`, which is
/// alphabetical, and the server's order is phase, steps, step, headline, ...), and it prints numbers its own way. The server
/// builds its bytes with `JSON.stringify` over keys it inserts in a fixed order, so the way to get identical bytes is to
/// write the same text by hand: keys in that order, strings escaped like `JSON.stringify`, whole numbers without ".0".
/// (The ActivityKit path does not need this; ActivityKit encodes `JobLiveState` through its normal `Codable`.)
extension JobLiveState {
    /// The state as compact JSON, key for key and byte for byte what the server writes for the same state.
    /// Order: phase, steps, step, headline, detail, fraction, compact, since, result, link, then rows.
    public func canonicalJSON() -> String {
        var parts = [
            "\"phase\":" + JobJSON.string(phase.rawValue),
            "\"steps\":[" + steps.map(JobJSON.string).joined(separator: ",") + "]",
            "\"step\":" + JobJSON.number(Double(step)),
            "\"headline\":" + JobJSON.string(headline),
        ]
        if let detail { parts.append("\"detail\":" + JobJSON.string(detail)) }
        if let fraction { parts.append("\"fraction\":" + JobJSON.number(fraction)) }
        if let compact { parts.append("\"compact\":" + JobJSON.string(compact)) }
        parts.append("\"since\":" + JobJSON.number(since))
        if let result { parts.append("\"result\":" + JobJSON.string(result)) }
        if let link { parts.append("\"link\":" + JobJSON.string(link)) }
        if let rows {
            // Row key order (title, status, phase) is ours: the server never sends rows.
            let items = rows.map {
                "{\"title\":" + JobJSON.string($0.title) + ",\"status\":" + JobJSON.string($0.status)
                    + ",\"phase\":" + JobJSON.string($0.phase.rawValue) + "}"
            }
            parts.append("\"rows\":[" + items.joined(separator: ",") + "]")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// The server's `canonicalJob`: the length caps (a cut string ends in "…") and the fraction clamped to 0...1 and rounded
    /// to three decimals. The builders below return their state through this, as the server does.
    public func canonical() -> JobLiveState {
        var s = self
        s.headline = JobText.cap(s.headline, 60)
        s.detail = s.detail.map { JobText.cap($0, 90) }
        s.compact = s.compact.map { JobText.cap($0, 7) }
        s.result = s.result.map { JobText.cap($0, 60) }
        s.link = s.link.map { JobText.cap($0, 300) }
        s.fraction = s.fraction.map { (min(1, max(0, $0)) * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }
        return s
    }
}

/// Small JSON text helpers that match `JSON.stringify`.
enum JobJSON {
    /// A quoted string. Like `JSON.stringify`: escapes `"` and `\`, the short forms \b \f \n \r \t, other control characters as
    /// lowercase \u00xx, and leaves everything else (including "/" and non-ASCII) as it is.
    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// A number the way JavaScript prints it: 1790000000 not 1790000000.0, 0.462 as is.
    static func number(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }
}

// MARK: - the words (job-live.ts `bytesText`, `resultText`, `reasonText`, ...)

/// The server's text helpers, line for line. Internal, but the tests reach them.
enum JobText {
    /// JS `s.slice(0, n)` over UTF-16 units. A character cut in half (an emoji at the edge) is dropped whole, since a Swift
    /// string cannot hold half of one.
    static func prefix(_ s: String, _ n: Int) -> String {
        var out = String.UnicodeScalarView()
        var used = 0
        for u in s.unicodeScalars {
            let width = u.value > 0xFFFF ? 2 : 1
            if used + width > n { break }
            out.append(u)
            used += width
        }
        return String(out)
    }

    /// `canonicalJob`'s cap: longer than `max` UTF-16 units becomes the first `max - 1` plus "…".
    static func cap(_ s: String, _ max: Int) -> String {
        s.utf16.count > max ? prefix(s, max - 1) + "…" : s
    }

    /// "8.9 MB", "918 KB", "1.2 GB". JS `toFixed(1)` rounds an exact tie up (1.25 -> "1.3") where `%.1f` rounds to even
    /// ("1.2"); only x.25 and x.75 are exact ties in binary, so those two are nudged up by hand.
    static func bytes(_ n: Int64) -> String {
        func fixed1(_ v: Double) -> String {
            let frac = v - v.rounded(.down)
            if frac == 0.25 || frac == 0.75 { return String(format: "%.1f", (v * 10).rounded(.up) / 10) }
            return String(format: "%.1f", v)
        }
        let d = Double(n)
        if n >= 1_000_000_000 { return fixed1(d / 1e9) + " GB" }
        if n >= 1_000_000 { return fixed1(d / 1e6) + " MB" }
        return "\(Swift.max(1, Int((d / 1e3).rounded(.toNearestOrAwayFromZero)))) KB"
    }

    /// "10.1 s", "30 s" (a whole number has no ".0", like JS).
    static func seconds(_ s: Double) -> String {
        JobJSON.number(((s * 10).rounded(.toNearestOrAwayFromZero)) / 10) + " s"
    }

    /// "46%".
    static func percent(_ f: Double) -> String {
        "\(Int((min(1, max(0, f)) * 100).rounded(.toNearestOrAwayFromZero)))%"
    }

    /// done / total clamped to 1; nil unless both are known and total > 0.
    static func ratio(_ done: Int64?, _ total: Int64?) -> Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// "1280×720 · 30 s · 8.9 MB"; nil when nothing is known.
    static func result(width: Int?, height: Int?, seconds s: Double?, bytes b: Int64?) -> String? {
        var parts: [String] = []
        if let width, let height { parts.append("\(width)×\(height)") }
        if let s { parts.append(seconds(s)) }
        if let b { parts.append(bytes(b)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let lostCode = "error.live.lost"

    /// A failure code in plain words (the server's `reasonText`; the order of the checks matters).
    static func reason(_ code: String?) -> String {
        let c = code ?? ""
        if c == lostCode { return "it may still finish: look in your library." }
        if c.hasPrefix("error.api.fetch.") || c.hasPrefix("error.api.content.") || c.hasPrefix("error.api.link.")
            || c == "error.studio.fetch_failed" { return "the link could not be fetched." }
        if c.contains("busy") { return "the server was busy. try again in a bit." }
        if c.contains("too_large") || c.contains("too_big") { return "that file is over the size limit." }
        if c.contains("unsupported") || c.contains("not_video") { return "that link isn't supported." }
        if c.contains("expired") || c.contains("lost") { return "the server lost this job. try again." }
        if c == "error.chat.interrupted" { return "the reply was cut off." }
        if c.hasPrefix("error.edit.") { return "a clip in this edit couldn't be used." }
        return "something went wrong. open capystore to see what happened."
    }

    /// The source line of a save: "twitch · KindStupidClip", the file name for a file, "a file" with nothing known.
    static func title(service: String, ref: String, input: String) -> String {
        if input == "file" || service == "file" || service.isEmpty { return ref.isEmpty ? "a file" : ref }
        return ref.isEmpty ? service : "\(service) · \(ref)"
    }
}

// MARK: - the local builders

/// A job as the island needs it: the fixed attributes and the changing state (the server's `Job`).
public struct JobLiveJob: Hashable, Sendable {
    public var attributes: JobLiveAttributes
    public var state: JobLiveState

    public init(attributes: JobLiveAttributes, state: JobLiveState) {
        self.attributes = attributes
        self.state = state
    }
}

/// A run the chat agent or an MCP client started (the run's `agent` field). A "make" has only the make step.
public enum JobLiveAgent: String, Sendable { case save, make }

/// The app's own states turned into job words, for activities the app shows without a push. Each builder is the matching
/// server function (`jobOfSave`, `jobOfEdit`, `jobOfChat`) read line for line, so a local activity and a pushed one say the
/// same thing; the fixture test runs them against the server's output.
public enum JobLive {
    // MARK: saves, uploads and webps

    /// The server's `jobOfSave`. `agent` is the run's agent mode (nil for a run the user started). `open` is the deep link,
    /// which the server's builders never set (they leave it to the caller).
    ///
    /// The app's `LiveContentState` has every field the server's `LiveState` has, so nothing here is approximated.
    public static func job(save s: LiveContentState, attributes a: LiveRunAttributes, agent: JobLiveAgent? = nil, open: String? = nil) -> JobLiveJob {
        let upload = a.input == "file"
        let making = agent == .make
        let kind = making ? "make" : upload ? "upload" : "save"
        let attributes = JobLiveAttributes(id: a.run, kind: kind, title: JobText.title(service: a.service, ref: a.ref, input: a.input), agent: agent != nil, open: open)

        // The steps are the real ones: download|upload then store, "read" only from the trim on, "make" only once a webp is
        // being made (or was).
        let reads = s.stage == .reading || s.stage == .ready
        let makes = s.stage == .rendering || (s.stage == .done && s.resultURL != nil) || (s.stage == .failed && s.rail == 3)
        var steps: [String]
        if making {
            steps = ["make"]
        } else {
            steps = [upload ? "upload" : "download", "store"]
            if reads { steps.append("read") }
            if makes { steps.append("make") }
        }
        func at(_ name: String) -> Int { Swift.max(0, steps.firstIndex(of: name) ?? -1) }
        let service = !a.service.isEmpty && a.service != "file" ? a.service : nil

        func byteDetail() -> String? {
            guard let bytes = s.bytes else { return nil }
            if let total = s.total, total > 0 { return "\(JobText.bytes(bytes)) of \(JobText.bytes(total))" }
            return JobText.bytes(bytes)
        }
        func frameDetail() -> String? {
            guard let done = s.framesDone, let total = s.framesTotal else { return nil }
            return "frame \(done) of \(total)"
        }
        func percentText(_ f: Double?) -> String? { f.map(JobText.percent) }

        var state = JobLiveState(phase: .working, steps: steps, step: 0, headline: "", since: s.since)
        switch s.stage {
        case .fetching:
            let f = JobText.ratio(s.bytes, s.total)
            state.step = at("download")
            state.headline = s.waking ? "waking the server" : service.map { "downloading from \($0)" } ?? "downloading"
            state.detail = byteDetail()
            state.fraction = f
            state.compact = percentText(f)
        case .uploading:
            let f = JobText.ratio(s.bytes, s.total)
            state.step = at("upload")
            state.headline = "uploading"
            state.detail = byteDetail()
            state.fraction = f
            state.compact = percentText(f)
        case .saving:
            let f = JobText.ratio(s.bytes, s.total)
            state.step = at("store")
            state.headline = "storing in your library"
            state.detail = byteDetail()
            state.fraction = f
            state.compact = percentText(f)
        case .reading:
            let f = JobText.ratio(s.framesDone.map(Int64.init), s.framesTotal.map(Int64.init))
            state.step = at("read")
            state.headline = "reading the video"
            state.detail = frameDetail()
            state.fraction = f
            state.compact = percentText(f)
        case .ready:
            // Waiting on the owner to trim; the detail is the clip's name.
            state.phase = .waiting
            state.step = at("read")
            state.headline = "ready to trim"
            state.detail = s.title
        case .rendering:
            let f = JobText.ratio(s.framesDone.map(Int64.init), s.framesTotal.map(Int64.init))
            state.step = at("make")
            state.headline = s.packing ? "packing the webp" : "making the webp"
            state.detail = frameDetail()
            state.fraction = f
            if let done = s.framesDone, let total = s.framesTotal { state.compact = "\(done)/\(total)" }
        case .done:
            state.phase = .done
            state.step = steps.count
            state.headline = s.resultURL != nil ? "webp ready" : "saved"
            state.result = JobText.result(width: s.resultWidth, height: s.resultHeight, seconds: s.resultSeconds, bytes: s.resultBytes)
            state.link = s.resultURL
        case .failed:
            let lost = s.code == JobText.lostCode
            // The step that failed stays current: by the rail cell it stopped on.
            let stopped = making ? 0 : s.rail >= 3 ? at("make") : (s.rail == 2 && reads) ? at("read") : Swift.min(s.rail, 1)
            state.phase = lost ? .lost : .failed
            state.step = Swift.max(0, Swift.min(steps.count - 1, stopped))
            state.headline = lost
                ? "lost track of this \(kind == "make" ? "webp" : kind == "upload" ? "upload" : "save")"
                : (making || s.rail >= 3 ? "couldn't make the webp" : "couldn't save")
            state.detail = JobText.reason(s.code)
        }
        return JobLiveJob(attributes: attributes, state: state.canonical())
    }

    // MARK: editor renders

    private static let editSteps = ["prepare", "render", "save"]

    /// The server's `jobOfEdit`. The activity's id is the render id (`attributes.render`); the project is not shown.
    public static func job(edit s: EditLiveContentState, attributes a: EditLiveAttributes, open: String? = nil) -> JobLiveJob {
        let attributes = JobLiveAttributes(id: a.render, kind: "edit", title: "edit · \(s.title)", agent: false, open: open)
        var state = JobLiveState(phase: .working, steps: editSteps, step: 0, headline: "", since: s.since)
        switch s.status {
        case .queued:
            // queueAhead 0 and nil both read "next" (the server tests the number for truthiness).
            let ahead = s.queueAhead ?? 0
            state.phase = .waiting
            state.headline = "waiting for its turn"
            state.detail = ahead != 0 ? "\(ahead) ahead" : "next"
            state.compact = ahead != 0 ? "+\(ahead)" : "next"
        case .preparing:
            state.headline = "sending the clips"
            state.fraction = s.progress
        case .rendering:
            state.step = 1
            state.headline = "rendering"
            state.detail = s.progress.map(JobText.percent)
            state.fraction = s.progress
            state.compact = s.progress.map(JobText.percent)
        case .finishing:
            state.step = 2
            state.headline = "saving the video"
            state.fraction = s.progress
        case .done:
            state.phase = .done
            state.step = 3
            state.headline = "video ready"
            state.result = JobText.result(width: s.resultWidth, height: s.resultHeight, seconds: s.resultSeconds, bytes: s.resultBytes)
        case .cancelled:
            state.phase = .failed
            state.step = 1
            state.headline = "render cancelled"
        case .failed:
            state.phase = .failed
            state.step = 1
            state.headline = "couldn't render"
            state.detail = JobText.reason(s.code)
        }
        return JobLiveJob(attributes: attributes, state: state.canonical())
    }

    // MARK: chat replies

    private static let chatSteps = ["think", "tools", "write"]

    /// The server's `jobOfChat`. The id is the thread; the title is "chat · <prompt>" cut to 80 characters.
    /// The app's `ChatLiveContentState.tool` holds the tool in words ("searching your library"), as the server's does.
    public static func job(chat s: ChatLiveContentState, attributes a: ChatLiveAttributes, open: String? = nil) -> JobLiveJob {
        let attributes = JobLiveAttributes(id: a.thread, kind: "chat", title: JobText.prefix("chat · \(a.prompt)", 80), agent: false, open: open)
        var state = JobLiveState(phase: .working, steps: chatSteps, step: 0, headline: "", since: s.since)
        switch s.status {
        case .thinking:
            state.headline = "thinking"
        case .working:
            // "3 so far · search, save", or just the tool before any step has started
            let tool = s.tool.flatMap { $0.isEmpty ? nil : $0 }
            state.step = 1
            state.headline = "using tools"
            state.detail = s.steps > 0 ? "\(s.steps) so far" + (tool.map { " · \($0)" } ?? "") : s.tool
            state.compact = s.steps > 0 ? "\(s.steps)" : nil
        case .writing:
            state.step = 2
            state.headline = "writing"
            state.detail = s.reply
        case .done:
            state.phase = .done
            state.step = 3
            state.headline = "reply ready"
            state.detail = s.reply
        case .failed:
            state.phase = .failed
            state.step = s.steps > 0 ? 1 : 0
            state.headline = "couldn't reply"
            state.detail = JobText.reason(s.code)
        }
        return JobLiveJob(attributes: attributes, state: state.canonical())
    }

    // MARK: several at once (CONTRACT-JOBLIVE.md 2.1)

    /// One activity for 2+ app-started jobs at once: kind "many", title "3 jobs", headline "1 done, 2 going", `rows` (at most
    /// 3, newest first, by `since`; jobs with the same `since` keep the order given) and `fraction` = done / total.
    ///
    /// Choices the contract leaves open:
    /// - `steps` is `["jobs"]` (a state needs 1...5 steps), `step` is 0 while any job runs and 1 when all have finished.
    /// - the headline drops a zero part ("3 done", "2 going") and a failed or lost job is not "going" and not "done":
    ///   it adds "1 failed" instead (one phrase, so "1 done, 1 going, 1 failed").
    /// - `compact` is "done/total" ("1/3"); `since` is the oldest job's, so the clock counts from the first start.
    /// - the phase is `working` while any job runs, then `done` (some saved) or `failed` (none did).
    /// - a row's status is that job's headline (its words), capped like a headline.
    public static func many(id: String, jobs: [JobLiveJob], open: String? = nil) -> JobLiveJob {
        let total = jobs.count
        let done = jobs.filter { $0.state.phase == .done }.count
        let failed = jobs.filter { $0.state.phase == .failed || $0.state.phase == .lost }.count
        let going = total - done - failed

        var words: [String] = []
        if done > 0 { words.append("\(done) done") }
        if going > 0 { words.append("\(going) going") }
        if failed > 0 { words.append("\(failed) failed") }
        let finished = going == 0

        let newestFirst = jobs.enumerated()
            .sorted { $0.element.state.since != $1.element.state.since ? $0.element.state.since > $1.element.state.since : $0.offset < $1.offset }
            .map(\.element)
        let rows = newestFirst.prefix(3).map {
            JobLiveState.Row(title: JobText.cap($0.attributes.title, 60), status: JobText.cap($0.state.headline, 60), phase: $0.state.phase)
        }

        let state = JobLiveState(
            phase: !finished ? .working : done > 0 ? .done : .failed,
            steps: ["jobs"],
            step: finished ? 1 : 0,
            headline: words.joined(separator: ", "),
            fraction: total > 0 ? Double(done) / Double(total) : 0,
            compact: "\(done)/\(total)",
            since: jobs.map(\.state.since).min() ?? 0,
            rows: rows)
        let attributes = JobLiveAttributes(id: id, kind: "many", title: "\(total) jobs", agent: false, open: open)
        return JobLiveJob(attributes: attributes, state: state.canonical())
    }
}

// MARK: - ActivityKit

#if os(iOS) && canImport(ActivityKit)
/// The one ActivityKit type for every job. The push-to-start `attributes-type` is this type's name, exactly
/// "CobaltJobActivityAttributes". Same stored properties as `JobLiveAttributes`.
public struct CobaltJobActivityAttributes: ActivityAttributes, Hashable, Sendable {
    public typealias ContentState = JobLiveState
    public var id: String
    public var kind: String
    public var title: String
    public var agent: Bool
    public var open: String?

    public init(_ a: JobLiveAttributes) {
        id = a.id
        kind = a.kind
        title = a.title
        agent = a.agent
        open = a.open
    }

    /// The same fields as the plain attributes type (the one that compiles on every platform).
    public var job: JobLiveAttributes {
        JobLiveAttributes(id: id, kind: kind, title: title, agent: agent, open: open)
    }
}
#endif
