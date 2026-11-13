import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-JOBLIVE.md 2 and 3: the job island's wire types and the local builders, pinned to the server's fixture
// (deploy/cloudflare/api/test/fixtures/job-live-states.json, made by the server's builders in test/job-live-cases.ts).

// MARK: - the fixture, kept in its own key order

/// The repo's fixture file. This file is at apple/CobaltKit/Tests/CobaltKitTests, so the repo root is four folders up.
private func fixtureText() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()                       // CobaltKitTests
        .appendingPathComponent("../../../../deploy/cloudflare/api/test/fixtures/job-live-states.json")
        .standardizedFileURL
    return try String(contentsOf: url, encoding: .utf8)
}

/// JSON text with the whitespace outside strings removed: the same text `JSON.stringify` writes without an indent. The
/// fixture is stored indented, so this is how its "canonical bytes" are made. Nothing else about the text changes: key
/// order, number spelling and string escapes stay as the server wrote them.
private func compact(_ json: String) -> String {
    var out = String.UnicodeScalarView()
    var inString = false
    var escaped = false
    for u in json.unicodeScalars {
        if inString {
            out.append(u)
            if escaped { escaped = false } else if u == "\\" { escaped = true } else if u == "\"" { inString = false }
        } else if u == "\"" {
            inString = true
            out.append(u)
        } else if u != " " && u != "\n" && u != "\r" && u != "\t" {
            out.append(u)
        }
    }
    return String(out)
}

/// The members of a compact JSON object as (key, raw value text), in file order. A tiny scanner: it only needs to find where
/// each value ends (depth of {} and [] outside strings), which is all that is needed to slice the fixture without
/// `JSONSerialization` (which would lose the key order).
private func members(of object: String) -> [(key: String, raw: String)] {
    let chars = Array(object.unicodeScalars)
    precondition(chars.first == "{" && chars.last == "}")
    var result: [(String, String)] = []
    var i = 1
    func readString() -> String {
        var s = String.UnicodeScalarView()
        i += 1                                             // opening quote
        while chars[i] != "\"" {
            if chars[i] == "\\" { s.append(chars[i]); i += 1 }
            s.append(chars[i])
            i += 1
        }
        i += 1                                             // closing quote
        return String(s)
    }
    while i < chars.count - 1 {
        let key = readString()
        precondition(chars[i] == ":")
        i += 1
        let start = i
        var depth = 0
        var inString = false
        while true {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 1 } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                if depth == 0 { break }                     // the object's own closing brace
                depth -= 1
            } else if c == "," && depth == 0 {
                break
            }
            i += 1
        }
        var raw = String.UnicodeScalarView()
        raw.append(contentsOf: chars[start..<i])
        result.append((key, String(raw)))
        if chars[i] == "," { i += 1 }
    }
    return result
}

private struct FixtureCase {
    let name: String
    let attributes: String     // compact JSON, in the server's key order
    let state: String
}

private func fixtureCases() throws -> [FixtureCase] {
    try members(of: compact(fixtureText())).map { name, raw in
        let parts = members(of: raw)
        return FixtureCase(
            name: name,
            attributes: try #require(parts.first { $0.key == "attributes" }?.raw),
            state: try #require(parts.first { $0.key == "state" }?.raw))
    }
}

private func fixtureCase(_ name: String) throws -> FixtureCase {
    try #require(try fixtureCases().first { $0.name == name }, "no fixture case named \(name)")
}

private func decodeState(_ json: String) throws -> JobLiveState { try JSONDecoder().decode(JobLiveState.self, from: Data(json.utf8)) }
private func decodeAttributes(_ json: String) throws -> JobLiveAttributes { try JSONDecoder().decode(JobLiveAttributes.self, from: Data(json.utf8)) }

// MARK: - the parity pin

struct JobLiveFixtureTests {
    @Test func theFixtureIsThere() throws {
        let cases = try fixtureCases()
        #expect(cases.count == 18)
        #expect(cases.map(\.name).contains("save_downloading") && cases.map(\.name).contains("chat_done"))
    }

    /// "Byte for byte": every case's attributes and state object, decoded and written again by `canonicalJSON()`, is the same
    /// UTF-8 text as the fixture's own object with its indentation removed. That fixes the key order (phase, steps, step,
    /// headline, detail, fraction, compact, since, result, link), whole numbers without ".0" (since 1790000000, fraction 1),
    /// no nulls, and the string escapes.
    @Test func everyCaseRoundTripsByteForByte() throws {
        for c in try fixtureCases() {
            let attributes = try decodeAttributes(c.attributes)
            let state = try decodeState(c.state)
            #expect(Array(attributes.canonicalJSON().utf8) == Array(c.attributes.utf8), "attributes of \(c.name)")
            #expect(Array(state.canonicalJSON().utf8) == Array(c.state.utf8), "state of \(c.name)")
        }
    }

    /// The plain `Codable` path (what ActivityKit uses) reads the same values back.
    @Test func codableRoundTripKeepsTheValues() throws {
        for c in try fixtureCases() {
            let state = try decodeState(c.state)
            let again = try JSONDecoder().decode(JobLiveState.self, from: JSONEncoder().encode(state))
            #expect(again == state, "state of \(c.name)")
        }
    }
}

// MARK: - decoding rules

struct JobLiveDecodingTests {
    @Test func anUnknownPhaseReadsAsWorking() throws {
        let s = try decodeState(#"{"phase":"paused-by-aliens","steps":["a"],"step":0,"headline":"h","since":1}"#)
        #expect(s.phase == .working)
        let row = try JSONDecoder().decode(JobLiveState.Row.self, from: Data(#"{"title":"t","status":"s","phase":"???"}"#.utf8))
        #expect(row.phase == .working)
        // every known one still decodes as itself
        for p in ["waiting", "working", "quiet", "done", "failed", "lost"] {
            let s = try decodeState(#"{"phase":"\#(p)","steps":["a"],"step":0,"headline":"h","since":1}"#)
            #expect(s.phase.rawValue == p)
        }
    }

    @Test func unknownKeysAreIgnored() throws {
        let s = try decodeState(#"{"phase":"done","steps":["a"],"step":1,"headline":"saved","since":5,"future":{"x":[1,2]},"badge":"new"}"#)
        #expect(s == JobLiveState(phase: .done, steps: ["a"], step: 1, headline: "saved", since: 5))
        let a = try decodeAttributes(#"{"id":"i","kind":"save","title":"t","agent":true,"color":"red"}"#)
        #expect(a == JobLiveAttributes(id: "i", kind: "save", title: "t", agent: true))
    }

    @Test func absentOptionalsAreOmittedNeverNull() throws {
        let s = JobLiveState(phase: .working, steps: ["a", "b"], step: 0, headline: "going", since: 1_790_000_000)
        #expect(s.canonicalJSON() == #"{"phase":"working","steps":["a","b"],"step":0,"headline":"going","since":1790000000}"#)
        // the plain encoder agrees: no null, none of the optional keys
        let plain = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!plain.contains("null"))
        for key in ["detail", "fraction", "compact", "result", "link", "rows"] { #expect(!plain.contains("\"\(key)\""), "\(key)") }
        let a = JobLiveAttributes(id: "i", kind: "save", title: "t")
        #expect(a.canonicalJSON() == #"{"id":"i","kind":"save","title":"t","agent":false}"#)
        #expect(!String(decoding: try JSONEncoder().encode(a), as: UTF8.self).contains("null"))
    }

    @Test func keyOrderAndEscapesFollowTheServer() {
        let s = JobLiveState(
            phase: .done, steps: ["x"], step: 1, headline: "a \"b\" \\ / \n\t\u{01}", detail: "d", fraction: 0.5, compact: "c",
            since: 12.5, result: "r", link: "l", rows: [.init(title: "t", status: "s", phase: .failed)])
        #expect(s.canonicalJSON() == #"{"phase":"done","steps":["x"],"step":1,"headline":"a \"b\" \\ / \n\t\u0001","detail":"d","fraction":0.5,"compact":"c","since":12.5,"result":"r","link":"l","rows":[{"title":"t","status":"s","phase":"failed"}]}"#)
    }

    @Test func isTerminalIsDoneFailedLost() {
        func s(_ p: JobLiveState.Phase) -> JobLiveState { JobLiveState(phase: p, steps: ["a"], step: 0, headline: "h", since: 1) }
        #expect(s(.done).isTerminal && s(.failed).isTerminal && s(.lost).isTerminal)
        #expect(!s(.waiting).isTerminal && !s(.working).isTerminal && !s(.quiet).isTerminal)
    }
}

// MARK: - the server's words

struct JobLiveWordsTests {
    @Test func canonicalCapsAndRoundsLikeTheServer() {
        let long = JobLiveState(phase: .working, steps: ["a"], step: 0, headline: String(repeating: "x", count: 99), detail: String(repeating: "y", count: 91), fraction: 1.7, compact: "12345678", since: 1)
        let c = long.canonical()
        #expect(c.headline.count == 60 && c.headline.hasSuffix("…") && c.headline.dropLast().allSatisfy { $0 == "x" })
        #expect(c.detail?.count == 90 && c.compact == "123456…" && c.fraction == 1)
        // within the limit nothing changes; the fraction goes to three decimals and is clamped at 0
        let ok = JobLiveState(phase: .working, steps: ["a"], step: 0, headline: String(repeating: "x", count: 60), fraction: 0.46153846, since: 1)
        #expect(ok.canonical().headline.count == 60 && ok.canonical().fraction == 0.462)
        #expect(JobLiveState(phase: .working, steps: ["a"], step: 0, headline: "h", fraction: -3, since: 1).canonical().fraction == 0)
    }

    @Test func bytesTextMatchesJavaScript() {
        #expect(JobText.bytes(918_000) == "918 KB")
        #expect(JobText.bytes(100) == "1 KB")
        #expect(JobText.bytes(1_500) == "2 KB")                  // Math.round(1.5) = 2
        #expect(JobText.bytes(8_900_000) == "8.9 MB")
        #expect(JobText.bytes(1_250_000) == "1.3 MB")            // toFixed(1) rounds the exact tie up; %.1f would say 1.2
        #expect(JobText.bytes(1_750_000) == "1.8 MB")
        #expect(JobText.bytes(96_000_000) == "96.0 MB")
        #expect(JobText.bytes(2_250_000_000) == "2.3 GB")
        #expect(JobText.seconds(30) == "30 s" && JobText.seconds(10.1) == "10.1 s" && JobText.seconds(10.14) == "10.1 s")
        #expect(JobText.result(width: nil, height: nil, seconds: nil, bytes: nil) == nil)
        #expect(JobText.result(width: 480, height: 854, seconds: nil, bytes: 918_000) == "480×854 · 918 KB")
    }

    @Test func reasonsFollowTheServersOrder() {
        #expect(JobText.reason("error.live.lost") == "it may still finish: look in your library.")
        #expect(JobText.reason("error.api.fetch.empty") == "the link could not be fetched.")
        #expect(JobText.reason("error.webp.busy") == "the server was busy. try again in a bit.")
        #expect(JobText.reason("error.upload.too_large") == "that file is over the size limit.")
        #expect(JobText.reason("error.api.link.unsupported") == "the link could not be fetched.")   // prefix wins over "unsupported"
        #expect(JobText.reason("error.webp.job_lost") == "the server lost this job. try again.")
        #expect(JobText.reason("error.chat.interrupted") == "the reply was cut off.")
        #expect(JobText.reason("error.edit.timeout") == "a clip in this edit couldn't be used.")
        #expect(JobText.reason(nil) == "something went wrong. open capystore to see what happened.")
    }

    @Test func prefixNeverSplitsACharacter() {
        #expect(JobText.prefix("abcdef", 3) == "abc")
        #expect(JobText.prefix("ab🙂cd", 3) == "ab")           // the emoji is two UTF-16 units: it does not fit in the third
        #expect(JobText.cap("ab🙂cd", 4) == "ab…")
    }
}

// MARK: - builder parity: the app's own states against the server's fixture

private let run = UUID(uuidString: "0B5F2C3E-6C1A-4F5E-9A57-1D0E6C9F2A11")!
private let t = 1_790_000_000.0
private let link = LiveRunAttributes(run: run, input: "link", service: "twitch", ref: "KindStupidClip", origin: "share")
private let file = LiveRunAttributes(run: run, input: "file", service: "file", ref: "IMG_0412.mov", origin: "app")

private func live(_ stage: LiveContentState.Stage, rail: Int = 0, waking: Bool = false, _ fill: (inout LiveContentState) -> Void = { _ in }) -> LiveContentState {
    var s = LiveContentState(stage: stage, rail: rail, since: t, waking: waking)
    fill(&s)
    return s
}

private func edit(_ status: EditLiveContentState.Status, _ fill: (inout EditLiveContentState) -> Void = { _ in }) -> EditLiveContentState {
    var s = EditLiveContentState(status: status, since: t, title: "birthday cut")
    fill(&s)
    return s
}

private func chat(_ status: ChatLiveContentState.Status, steps: Int = 0, tool: String? = nil, reply: String? = nil) -> ChatLiveContentState {
    ChatLiveContentState(status: status, since: t, steps: steps, tool: tool, reply: reply)
}

/// A builder's output must be exactly the fixture's, compared as bytes (the same canonical JSON) and as values.
private func expectParity(_ name: String, _ job: JobLiveJob, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let c = try fixtureCase(name)
    #expect(job.attributes.canonicalJSON() == c.attributes, "attributes of \(name)", sourceLocation: sourceLocation)
    #expect(job.state.canonicalJSON() == c.state, "state of \(name)", sourceLocation: sourceLocation)
    #expect(job.attributes == (try decodeAttributes(c.attributes)), "attributes of \(name)", sourceLocation: sourceLocation)
    #expect(job.state == (try decodeState(c.state)), "state of \(name)", sourceLocation: sourceLocation)
}

struct JobLiveBuilderParityTests {
    // the inputs are copied from deploy/cloudflare/api/test/job-live-cases.ts
    @Test func saves() throws {
        try expectParity("save_downloading", JobLive.job(save: live(.fetching) { $0.bytes = 4_200_000; $0.total = 9_100_000 }, attributes: link, agent: .save))
        try expectParity("save_waking", JobLive.job(save: live(.fetching, waking: true), attributes: link))
        try expectParity("save_storing", JobLive.job(save: live(.saving, rail: 1) { $0.bytes = 8_900_000; $0.total = 8_900_000 }, attributes: link, agent: .save))
        try expectParity("save_done", JobLive.job(save: live(.done, rail: 1) {
            $0.resultWidth = 1280; $0.resultHeight = 720; $0.resultSeconds = 30; $0.resultBytes = 8_900_000
        }, attributes: link, agent: .save))
        try expectParity("save_failed", JobLive.job(save: live(.failed) { $0.code = "error.studio.fetch_failed" }, attributes: link))
        try expectParity("save_lost", JobLive.job(save: live(.failed) { $0.code = "error.live.lost" }, attributes: link, agent: .save))
    }

    @Test func uploadsAndTheDeviceStages() throws {
        try expectParity("upload_uploading", JobLive.job(save: live(.uploading) { $0.bytes = 38_000_000; $0.total = 96_000_000 }, attributes: file))
        try expectParity("app_reading", JobLive.job(save: live(.reading, rail: 2) { $0.framesDone = 40; $0.framesTotal = 300 }, attributes: file))
        try expectParity("app_ready", JobLive.job(save: live(.ready, rail: 2) { $0.title = "IMG_0412.mov" }, attributes: file))
        try expectParity("app_webp", JobLive.job(save: live(.rendering, rail: 3) { $0.framesDone = 42; $0.framesTotal = 150 }, attributes: link))
    }

    @Test func makes() throws {
        try expectParity("make_working", JobLive.job(save: live(.rendering, rail: 3) { $0.framesDone = 42; $0.framesTotal = 150; $0.title = "a cat" }, attributes: link, agent: .make))
        try expectParity("make_done", JobLive.job(save: live(.done, rail: 3) {
            $0.resultURL = "https://media.capybaraharmony.com/PrEvIeW001.webp"
            $0.resultWidth = 480; $0.resultHeight = 854; $0.resultSeconds = 10.1; $0.resultBytes = 918_000
        }, attributes: link, agent: .make))
    }

    @Test func edits() throws {
        let a = EditLiveAttributes(render: "R3nd3rIdR3nd3rIdR3nd", project: "ProjectAAAAAAAAA")
        try expectParity("edit_queued", JobLive.job(edit: edit(.queued) { $0.queueAhead = 2 }, attributes: a))
        try expectParity("edit_rendering", JobLive.job(edit: edit(.rendering) { $0.progress = 0.63 }, attributes: a))
        try expectParity("edit_done", JobLive.job(edit: edit(.done) {
            $0.resultSeconds = 48; $0.resultWidth = 1920; $0.resultHeight = 1080; $0.resultBytes = 96_000_000
        }, attributes: a))
        try expectParity("edit_failed", JobLive.job(edit: edit(.failed) { $0.code = "error.edit.missing_clip" }, attributes: a))
    }

    @Test func chats() throws {
        let a = ChatLiveAttributes(thread: "thread01", prompt: "save that clip", source: .app)
        try expectParity("chat_tools", JobLive.job(chat: chat(.working, steps: 3, tool: "search, save, look"), attributes: a))
        try expectParity("chat_done", JobLive.job(chat: chat(.done, steps: 3, reply: "saved it (=^･ω･^=) it's in your library now"), attributes: a))
    }

    /// Every fixture case is covered by one of the tests above (so adding a case to the server fails here until it is pinned).
    @Test func noFixtureCaseIsLeftUnpinned() throws {
        let pinned: Set<String> = [
            "save_downloading", "save_waking", "save_storing", "save_done", "save_failed", "save_lost",
            "upload_uploading", "app_reading", "app_ready", "app_webp", "make_working", "make_done",
            "edit_queued", "edit_rendering", "edit_done", "edit_failed", "chat_tools", "chat_done",
        ]
        #expect(Set(try fixtureCases().map(\.name)) == pinned)
    }
}

// MARK: - builder behaviour beyond the fixture

struct JobLiveBuilderTests {
    @Test func editQueuedNextAndTheOtherEditStates() {
        let a = EditLiveAttributes(render: "r", project: "p")
        let next = JobLive.job(edit: edit(.queued), attributes: a).state
        #expect(next.detail == "next" && next.compact == "next" && next.phase == .waiting)
        let preparing = JobLive.job(edit: edit(.preparing) { $0.progress = 0.04 }, attributes: a).state
        #expect(preparing.step == 0 && preparing.headline == "sending the clips" && preparing.fraction == 0.04 && preparing.detail == nil)
        let finishing = JobLive.job(edit: edit(.finishing) { $0.progress = 0.95 }, attributes: a).state
        #expect(finishing.step == 2 && finishing.headline == "saving the video")
        let cancelled = JobLive.job(edit: edit(.cancelled), attributes: a).state
        #expect(cancelled.phase == .failed && cancelled.step == 1 && cancelled.headline == "render cancelled" && cancelled.detail == nil)
    }

    @Test func chatStatesBeforeAndAfterTools() {
        let a = ChatLiveAttributes(thread: "t", prompt: "hi", source: .shortcut)
        #expect(JobLive.job(chat: chat(.thinking), attributes: a).state.headline == "thinking")
        let firstTool = JobLive.job(chat: chat(.working, steps: 0, tool: "searching your library"), attributes: a).state
        #expect(firstTool.detail == "searching your library" && firstTool.compact == nil)
        #expect(JobLive.job(chat: chat(.writing, steps: 2, reply: "…found three"), attributes: a).state.detail == "…found three")
        let failed = JobLive.job(chat: chat(.failed, steps: 1), attributes: a).state
        #expect(failed.step == 1 && failed.headline == "couldn't reply")
        #expect(JobLive.job(chat: chat(.failed, steps: 0), attributes: a).state.step == 0)
        // the title is "chat · <prompt>" cut to 80 characters, and a long reply is cut to the detail limit
        let long = ChatLiveAttributes(thread: "t", prompt: String(repeating: "p", count: 200), source: .app)
        #expect(JobLive.job(chat: chat(.thinking), attributes: long).attributes.title.count == 80)
        let done = JobLive.job(chat: chat(.done, reply: String(repeating: "r", count: 160)), attributes: a).state
        #expect(done.detail?.count == 90 && done.detail?.hasSuffix("…") == true)
    }

    @Test func aFailedSaveKeepsTheStepItStoppedOn() {
        let failedStore = JobLive.job(save: live(.failed, rail: 1) { $0.code = "error.api.fetch.empty" }, attributes: link).state
        #expect(failedStore.step == 1 && failedStore.headline == "couldn't save")
        let failedWebp = JobLive.job(save: live(.failed, rail: 3) { $0.code = "error.webp.job_lost" }, attributes: link).state
        #expect(failedWebp.steps == ["download", "store", "make"] && failedWebp.step == 2 && failedWebp.headline == "couldn't make the webp")
        let lostUpload = JobLive.job(save: live(.failed) { $0.code = "error.live.lost" }, attributes: file)
        #expect(lostUpload.state.phase == .lost && lostUpload.state.headline == "lost track of this upload")
        let lostMake = JobLive.job(save: live(.failed, rail: 3) { $0.code = "error.live.lost" }, attributes: link, agent: .make).state
        #expect(lostMake.headline == "lost track of this webp" && lostMake.steps == ["make"] && lostMake.step == 0)
    }

    @Test func aSaveDoneIsPastTheLastStepAndAPackingMakeSaysSo() {
        let done = JobLive.job(save: live(.done, rail: 1), attributes: link).state
        #expect(done.step == 2 && done.headline == "saved" && done.result == nil && done.link == nil)
        let packing = JobLive.job(save: live(.rendering, rail: 3) { $0.packing = true; $0.framesDone = 150; $0.framesTotal = 150 }, attributes: link).state
        #expect(packing.headline == "packing the webp" && packing.fraction == 1 && packing.compact == "150/150")
    }

    @Test func aFileWithNoNameIsAFile() {
        let nameless = LiveRunAttributes(run: run, input: "file", service: "file", ref: "", origin: "app")
        #expect(JobLive.job(save: live(.uploading), attributes: nameless).attributes.title == "a file")
        let bare = LiveRunAttributes(run: run, input: "link", service: "x", ref: "", origin: "app")
        #expect(JobLive.job(save: live(.fetching), attributes: bare).attributes.title == "x")
        // the same, without a service: no "from"
        let unknown = LiveRunAttributes(run: run, input: "link", service: "", ref: "abc", origin: "app")
        #expect(JobLive.job(save: live(.fetching), attributes: unknown).state.headline == "downloading")
    }

    @Test func openIsOnlyWhatTheCallerGives() {
        #expect(JobLive.job(save: live(.fetching), attributes: link).attributes.open == nil)
        #expect(JobLive.job(save: live(.fetching), attributes: link, open: "cobalt-apple://library").attributes.open == "cobalt-apple://library")
    }
}

// MARK: - several at once

struct JobLiveManyTests {
    private func job(_ title: String, since: Double, phase: JobLiveState.Phase, headline: String) -> JobLiveJob {
        JobLiveJob(
            attributes: JobLiveAttributes(id: title, kind: "save", title: title),
            state: JobLiveState(phase: phase, steps: ["download", "store"], step: 0, headline: headline, since: since))
    }

    @Test func oneDoneTwoGoing() {
        let m = JobLive.many(id: "busy", jobs: [
            job("a", since: 100, phase: .working, headline: "downloading from twitch"),
            job("b", since: 300, phase: .working, headline: "uploading"),
            job("c", since: 200, phase: .done, headline: "saved"),
        ])
        #expect(m.attributes == JobLiveAttributes(id: "busy", kind: "many", title: "3 jobs", agent: false))
        #expect(m.state.headline == "1 done, 2 going")
        #expect(m.state.phase == .working && m.state.steps == ["jobs"] && m.state.step == 0)
        #expect(m.state.fraction == 0.333 && m.state.compact == "1/3" && m.state.since == 100)
        // newest first
        #expect(m.state.rows?.map(\.title) == ["b", "c", "a"])
        #expect(m.state.rows?.map(\.status) == ["uploading", "saved", "downloading from twitch"])
        #expect(m.state.rows?.map(\.phase) == [.working, .done, .working])
    }

    @Test func atMostThreeRowsAndTheEndStates() {
        let five = (0..<5).map { job("j\($0)", since: Double($0), phase: .working, headline: "going") }
        let m = JobLive.many(id: "x", jobs: five)
        #expect(m.attributes.title == "5 jobs" && m.state.headline == "5 going")
        #expect(m.state.rows?.map(\.title) == ["j4", "j3", "j2"])

        let allDone = JobLive.many(id: "x", jobs: [job("a", since: 1, phase: .done, headline: "saved"), job("b", since: 2, phase: .done, headline: "saved")]).state
        #expect(allDone.phase == .done && allDone.headline == "2 done" && allDone.step == 1 && allDone.fraction == 1 && allDone.isTerminal)

        let mixed = JobLive.many(id: "x", jobs: [job("a", since: 1, phase: .done, headline: "saved"), job("b", since: 2, phase: .failed, headline: "couldn't save")]).state
        #expect(mixed.phase == .done && mixed.headline == "1 done, 1 failed" && mixed.fraction == 0.5)

        let none = JobLive.many(id: "x", jobs: [job("a", since: 1, phase: .failed, headline: "couldn't save"), job("b", since: 2, phase: .lost, headline: "lost track of this save")]).state
        #expect(none.phase == .failed && none.headline == "2 failed")
    }

    @Test func itEncodesAndDecodesWithItsRows() throws {
        let m = JobLive.many(id: "x", jobs: [job("a", since: 1, phase: .working, headline: "going"), job("b", since: 2, phase: .done, headline: "saved")])
        let again = try decodeState(m.state.canonicalJSON())
        #expect(again == m.state)
        #expect(again.rows?.count == 2)
    }
}
