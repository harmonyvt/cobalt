import Foundation
import Testing
@testable import CobaltKit

/// The main thread is display-only (8.17, apple/ARCHITECTURE.md). 8.16 measured what happens otherwise on Harmony's
/// iPhone: the offline index reconciled on main for 330 to 432 ms, and the library's first appearance took a 914 ms
/// frame. This test reads every app and CobaltKit source file and refuses disk, JSON and image-decoding calls in
/// main-thread code: a file that declares a View or a `@MainActor` type or extension (a type nested in a `@MainActor`
/// class lives in that same file, so it counts too). Lines inside a `nonisolated` or `@concurrent` function, an
/// `actor`, or a `Task.detached { }` block are off main and pass; the brace counting that finds them is a cheap
/// heuristic, not a parser.
///
/// What is already there is listed in apple/main-thread-allowlist.txt, one `<finding> # reason` per line. A finding is
/// `path/from/apple.swift: <trimmed line>` without a line number, so an edit elsewhere in the file does not break it.
/// The test fails on a finding the list does not have, and on a list entry nothing matches any more, so the list only
/// shrinks. `UPDATE_MAIN_THREAD_ALLOWLIST=1 swift test --filter MainThreadLint` rewrites it from the current tree,
/// keeping the reasons it already has.
@Suite struct MainThreadLintTests {
    static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let allowlistURL = appleRoot.appendingPathComponent("main-thread-allowlist.txt")
    static let newReason = "8.17 baseline, move off main"

    @Test func mainThreadCodeDoesNoDiskJSONOrDecodeWork() throws {
        let findings = try MainThreadLint.scan(appleRoot: Self.appleRoot)
        let existing = MainThreadLint.parseAllowlist((try? String(contentsOf: Self.allowlistURL, encoding: .utf8)) ?? "")

        if ProcessInfo.processInfo.environment["UPDATE_MAIN_THREAD_ALLOWLIST"] == "1" {
            let text = MainThreadLint.renderAllowlist(findings: findings, reasons: existing, newReason: Self.newReason)
            try text.write(to: Self.allowlistURL, atomically: true, encoding: .utf8)
            return
        }

        let unlisted = findings.subtracting(existing.keys).sorted()
        let stale = Set(existing.keys).subtracting(findings).sorted()
        #expect(unlisted.isEmpty, """
            Main-thread code does disk, JSON or image work (apple/ARCHITECTURE.md rule 1). Move it into an engine \
            (an actor, or a nonisolated @concurrent function), or add the line to apple/main-thread-allowlist.txt \
            with a reason:
            \(unlisted.joined(separator: "\n"))
            """)
        #expect(stale.isEmpty, """
            These apple/main-thread-allowlist.txt entries match nothing any more; delete them so the list only shrinks:
            \(stale.joined(separator: "\n"))
            """)
    }

    // MARK: the scanner on small inputs

    @Test func aViewFileIsMainThreadCode() {
        let source = """
            struct Row: View {
                var body: some View {
                    let names = try? FileManager.default.contentsOfDirectory(atPath: "/")
                    Text("\\(names?.count ?? 0)")
                }
            }
            """
        #expect(MainThreadLint.findings(path: "Cobalt/Row.swift", text: source) == [
            "Cobalt/Row.swift: let names = try? FileManager.default.contentsOfDirectory(atPath: \"/\")",
        ])
    }

    @Test func aPlainEngineFileIsNotMainThreadCode() {
        let source = """
            struct Engine {
                func load(_ url: URL) throws -> Data { try Data(contentsOf: url) }
            }
            """
        #expect(MainThreadLint.findings(path: "CobaltKit/Sources/Engine.swift", text: source).isEmpty)
    }

    @Test func offMainRegionsAndCommentsPass() {
        let source = """
            @MainActor
            @Observable final class Model {
                // FileManager is fine to mention in a comment
                func reload() async {
                    let data = await Task.detached {
                        try? Data(contentsOf: URL(fileURLWithPath: "/a"))
                    }.value
                    _ = data
                    let decoder = JSONDecoder()
                    _ = decoder
                }

                @concurrent
                nonisolated static func read(_ url: URL) async -> Data? {
                    if FileManager.default.fileExists(atPath: url.path) {
                        return try? Data(contentsOf: url)
                    }
                    return nil
                }

                func after() { _ = FileManager.default }
            }

            actor Disk {
                func size(_ path: String) throws -> Any { try FileManager.default.attributesOfItem(atPath: path) }
            }
            """
        #expect(MainThreadLint.findings(path: "M.swift", text: source) == [
            "M.swift: let decoder = JSONDecoder()",
            "M.swift: func after() { _ = FileManager.default }",
        ])
    }

    @Test func allowlistRoundTripsAndKeepsReasons() {
        let reasons = MainThreadLint.parseAllowlist("""
            # header
            A.swift: let a = JSONDecoder() # tiny, decoded once at launch

            B.swift: try data.write(to: url) # gone now
            """)
        #expect(reasons == ["A.swift: let a = JSONDecoder()": "tiny, decoded once at launch",
                            "B.swift: try data.write(to: url)": "gone now"])
        let text = MainThreadLint.renderAllowlist(
            findings: ["A.swift: let a = JSONDecoder()", "C.swift: FileManager.default"], reasons: reasons, newReason: "new")
        let again = MainThreadLint.parseAllowlist(text)
        #expect(again == ["A.swift: let a = JSONDecoder()": "tiny, decoded once at launch", "C.swift: FileManager.default": "new"])
    }
}

/// The scanner itself, kept apart from the tests so each rule reads in one place.
enum MainThreadLint {
    static let banned = [
        "FileManager", "fileExists(", "contentsOfDirectory(", "Data(contentsOf:", "JSONDecoder(", "JSONEncoder(",
        "NSFileCoordinator", "CGImageSourceCreate", "UIImage(data:", "NSImage(data:", ".write(to:", "attributesOfItem(",
    ]

    /// Folders scanned, relative to apple/. Tests, build output and preview-only data are not app code.
    static let roots = ["Cobalt", "CobaltKit/Sources"]
    static let skippedFolders: Set<String> = ["Tests", "Preview"]
    static let skippedSuffixes = ["Previews.swift", "PreviewData.swift", "PreviewSupport.swift"]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // the patterns are literals in this file; a typo should fail loudly
        try! NSRegularExpression(pattern: pattern)
    }

    /// `struct Row: View`, `, View {`, `some View`.
    nonisolated(unsafe) static let viewPattern = regex(#"[:,]\s*View\b|\bsome\s+View\b"#)
    /// `@MainActor` followed by attributes and modifiers, then a type or extension (possibly on the next lines).
    nonisolated(unsafe) static let mainActorTypePattern = regex(
        #"@MainActor\b(\s+(@\w+(\([^)]*\))?|public|private|fileprivate|internal|package|final|open))*\s+(class|struct|enum|extension|protocol)\b"#)
    /// The start of an off-main region: a nonisolated or @concurrent function, an actor, a detached task.
    nonisolated(unsafe) static let offMainPattern = regex(
        #"(\bnonisolated\b(?!\()|@concurrent).*\b(func|init|var)\b|Task\.detached|(^|\s)actor\s+[A-Za-z_]\w*|^(nonisolated|@concurrent)$"#)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isComment(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    /// Every finding in one file, `path: <trimmed line>`.
    static func findings(path: String, text: String) -> Set<String> {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let code = lines.map { isComment($0) ? "" : $0 }
        let joined = code.joined(separator: "\n")
        guard matches(viewPattern, joined) || matches(mainActorTypePattern, joined) else { return [] }

        var out: Set<String> = []
        var depth = 0
        var regions: [Int] = []   // the brace depth each open off-main region started at
        var pending = false       // an off-main declaration whose `{` has not come yet
        for line in code where !line.isEmpty {
            let marker = matches(offMainPattern, line)
            if marker { pending = true }
            let insideBefore = !regions.isEmpty
            for ch in line {
                if ch == "{" {
                    depth += 1
                    if pending { regions.append(depth); pending = false }
                } else if ch == "}" {
                    if regions.last == depth { regions.removeLast() }
                    depth -= 1
                }
            }
            if insideBefore || marker || !regions.isEmpty { continue }
            if banned.contains(where: { line.contains($0) }) { out.insert("\(path): \(line)") }
        }
        return out
    }

    /// Every finding under apple/'s app and CobaltKit sources.
    static func scan(appleRoot: URL) throws -> Set<String> {
        var out: Set<String> = []
        let rootPath = appleRoot.standardizedFileURL.path
        for folder in roots {
            let root = appleRoot.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                var relative = url.standardizedFileURL.path
                if relative.hasPrefix(rootPath + "/") { relative.removeFirst(rootPath.count + 1) }
                let parts = relative.split(separator: "/").map(String.init)
                if parts.dropLast().contains(where: { skippedFolders.contains($0) || $0.hasPrefix(".") }) { continue }
                if skippedSuffixes.contains(where: { relative.hasSuffix($0) }) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                out.formUnion(findings(path: relative, text: text))
            }
        }
        return out
    }

    /// `finding # reason` lines; blank lines and lines starting with `#` are ignored. The reason starts after the last
    /// " # ", so a `#` inside the code line itself survives.
    static func parseAllowlist(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let cut = line.range(of: " # ", options: .backwards) {
                out[String(line[..<cut.lowerBound]).trimmingCharacters(in: .whitespaces)] =
                    String(line[cut.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                out[line] = ""
            }
        }
        return out
    }

    static func renderAllowlist(findings: Set<String>, reasons: [String: String], newReason: String) -> String {
        var text = """
            # Main-thread code that still does disk, JSON or image work (apple/ARCHITECTURE.md rule 1).
            # One `<finding> # reason` per line; MainThreadLintTests fails on anything new and on entries that no longer
            # match, so this list only shrinks. Regenerate with UPDATE_MAIN_THREAD_ALLOWLIST=1 (reasons are kept).

            """
        for finding in findings.sorted() {
            let reason = reasons[finding].flatMap { $0.isEmpty ? nil : $0 } ?? newReason
            text += "\(finding) # \(reason)\n"
        }
        return text
    }
}

/// The guards only trap on the wrong thread, so these call each one on its right thread (where nothing may happen) and
/// check the decision itself apart from the trap.
@Suite struct MainThreadGuardTests {
    @Test func theDecisionFlagsOnlyTheWrongThread() {
        #expect(MainThreadGuard.isViolation(expectMain: false, onMain: true))
        #expect(!MainThreadGuard.isViolation(expectMain: false, onMain: false))
        #expect(MainThreadGuard.isViolation(expectMain: true, onMain: false))
        #expect(!MainThreadGuard.isViolation(expectMain: true, onMain: true))
    }

    @Test func offMainPassesOnABackgroundThread() async {
        let ran = await Task.detached {
            MainThreadGuard.assertOffMain("background work")
            return true
        }.value
        #expect(ran)
    }

    @MainActor
    @Test func onMainPassesOnTheMainActor() {
        MainThreadGuard.assertOnMain()
        #expect(Thread.isMainThread)
    }

    @Test func enforcedOnlyInDebugBuilds() {
        #if DEBUG
        #expect(MainThreadGuard.isEnforced)
        #else
        #expect(!MainThreadGuard.isEnforced)
        #endif
    }
}
