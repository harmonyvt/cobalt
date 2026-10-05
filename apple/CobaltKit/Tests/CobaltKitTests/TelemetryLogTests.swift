import Foundation
import Testing
@testable import CobaltKit

/// The shared JSONL buffer: appends, caps, rotation, and two writers on one directory (the app and an
/// extension are two processes; two `TelemetryLog` instances are the same thing as far as the file goes).
@Suite("telemetry log")
struct TelemetryLogTests {
    private func makeLog(_ dir: URL, _ process: TelemetryProcess = .app, lines: Int = 2000, bytes: Int = 1_000_000) -> TelemetryLog {
        TelemetryLog(directory: dir, process: process, limits: .init(maxLines: lines, maxBytes: bytes), mirrorToOSLog: false)
    }

    /// Every non-empty line of both segments, raw (to prove none is torn).
    private func rawLines(_ dir: URL) -> [String] {
        ["events.1.jsonl", "events.jsonl"].flatMap { name -> [String] in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    @Test func appendsOneJSONLinePerEvent() throws {
        let dir = try makeTempDirectory()
        let log = makeLog(dir)
        log.log(.info, .pipeline, "state ready", data: ["bytes": .int(42), "ok": true, "ratio": 0.5, "kind": "link"])
        log.log(.error, .upload, "upload failed")
        let events = log.readAll()
        #expect(events.count == 2)
        #expect(events[0].e.msg == "state ready")
        #expect(events[0].e.level == .info)
        #expect(events[0].e.cat == .pipeline)
        #expect(events[0].e.data == ["bytes": .int(42), "ok": .bool(true), "ratio": .double(0.5), "kind": .string("link")])
        #expect(events[0].p == .app)
        #expect(events[1].e.cat == .upload)
        #expect(events[0].e.ts <= events[1].e.ts)
        #expect(rawLines(dir).count == 2)
    }

    @Test func keepsEventsInsideTheWireLimits() throws {
        let dir = try makeTempDirectory()
        let log = makeLog(dir)
        var data: [String: TelemetryValue] = [:]
        for n in 0..<40 { data["k\(String(format: "%02d", n))"] = .int(n) }
        data["apiKey"] = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
        data["clipboardText"] = "something pasted"
        data["long"] = .string(String(repeating: "x", count: 900))
        data["nan"] = .double(.nan)
        log.log(.warn, .net, String(repeating: "m", count: 1_000), data: data)
        let e = try #require(log.readAll().first).e
        #expect(e.msg.count <= TelemetryLimits.messageLength)
        #expect(e.data.count <= TelemetryLimits.dataKeys)
        // the names that sort first are the ones kept; secrets are replaced, never dropped silently
        #expect(e.data["apiKey"] == .string("[redacted]"))
        #expect(e.data["clipboardText"] == .string("[redacted]"))
        if case .string(let s)? = e.data["long"] { #expect(s.count <= TelemetrySanitize.maxStringValue) }
        #expect(!rawLines(dir).joined().contains("7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"))
    }

    @Test func nonFiniteNumbersDoNotLoseTheLine() throws {
        let dir = try makeTempDirectory()
        let log = makeLog(dir)
        log.log(.info, .app, "n", data: ["x": .double(.infinity)])
        #expect(log.readAll().count == 1)
    }

    @Test func rotatesByLinesAndKeepsTheNewest() throws {
        let dir = try makeTempDirectory()
        let log = makeLog(dir, lines: 20)                      // segments of 10
        for n in 0..<95 { log.log(.info, .app, "line \(n)") }
        let events = log.readAll()
        #expect(events.count <= 20)
        #expect(events.count >= 10)
        #expect(events.last?.e.msg == "line 94")
        let numbers = events.compactMap { Int($0.e.msg.dropFirst(5)) }
        #expect(numbers == numbers.sorted())
        #expect(numbers.last.map { $0 - (numbers.first ?? 0) + 1 } == numbers.count)   // a contiguous run, nothing in the middle lost
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("events.1.jsonl").path))
    }

    @Test func rotatesByBytes() throws {
        let dir = try makeTempDirectory()
        let log = makeLog(dir, lines: 100_000, bytes: 4_000)   // segments of 2 KB
        for n in 0..<200 { log.log(.info, .app, "line \(n) " + String(repeating: "p", count: 60)) }
        log.flush()
        for name in ["events.jsonl", "events.1.jsonl"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            #expect(size < 2_000 + 400)                        // one line past the segment size at most
        }
        #expect(log.readAll().last?.e.msg.hasPrefix("line 199") == true)
    }

    @Test func recentReturnsTheTailBeforeATimeOfOneRun() throws {
        let dir = try makeTempDirectory()
        let a = makeLog(dir)
        let b = makeLog(dir, .share)
        for n in 0..<150 { a.log(.info, .app, "a\(n)") }
        for n in 0..<10 { b.log(.info, .share, "b\(n)") }
        let tail = a.recent(limit: 100, run: a.runTag)
        #expect(tail.count == 100)
        #expect(tail.first?.e.msg == "a50")
        #expect(tail.last?.e.msg == "a149")
        #expect(tail.allSatisfy { $0.p == .app })
        #expect(b.recent(limit: 100, run: b.runTag).count == 10)
        let all = a.recent(limit: 1000)
        #expect(all.count == 160)
    }

    @Test func twoWritersOnOneDirectoryNeverInterleave() async throws {
        let dir = try makeTempDirectory()
        let app = makeLog(dir, .app)
        let share = makeLog(dir, .share)
        // two processes, each logging from several threads at once
        await withTaskGroup(of: Void.self) { group in
            for (log, tag) in [(app, "app"), (share, "share")] {
                for thread in 0..<4 {
                    group.addTask {
                        for n in 0..<150 { log.log(.info, tag == "app" ? .app : .share, "\(tag)-\(thread)-\(n)", data: ["n": .int(n)]) }
                    }
                }
            }
        }
        share.flush()
        let events = app.readAll()                              // flushes the app's queue; the share's was flushed above
        let raw = rawLines(dir)
        #expect(raw.count == 1_200)
        #expect(events.count == 1_200)                          // every raw line decodes: none torn
        #expect(Set(events.map(\.i)).count == 1_200)            // ids are unique across both writers
        #expect(Set(events.map(\.p)) == [.app, .share])
        // order inside one writer thread is preserved
        for tag in ["app-0", "app-3", "share-2"] {
            let n = events.filter { $0.e.msg.hasPrefix(tag + "-") }.compactMap { Int($0.e.msg.split(separator: "-").last ?? "") }
            #expect(n == n.sorted())
            #expect(n.count == 150)
        }
    }

    @Test func twoWritersRotatingTogetherStayWithinTheCapAndWhole() async throws {
        let dir = try makeTempDirectory()
        let a = makeLog(dir, .app, lines: 400)
        let b = makeLog(dir, .share, lines: 400)
        await withTaskGroup(of: Void.self) { group in
            for log in [a, b] {
                for thread in 0..<3 {
                    group.addTask { for n in 0..<300 { log.log(.info, .app, "t\(thread)-\(n)") } }
                }
            }
        }
        b.flush()
        let events = a.readAll()
        let raw = rawLines(dir)
        #expect(raw.count == events.count)                      // nothing torn by a rotation
        // the cap is approximate (each process counts its own lines between rotations) but never runs away
        #expect(events.count <= 400 * 2)
        #expect(events.count >= 100)
    }

    @Test func valuesRoundTripAsFlatJSON() throws {
        let values: [String: TelemetryValue] = ["s": "a", "i": 3, "d": 1.5, "b": false]
        let data = try JSONEncoder().encode(values)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["s"] as? String == "a")
        #expect(object["i"] as? Int == 3)
        #expect(object["d"] as? Double == 1.5)
        #expect(object["b"] as? Bool == false)
        #expect(try JSONDecoder().decode([String: TelemetryValue].self, from: data) == values)
    }
}
