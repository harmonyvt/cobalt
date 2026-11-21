import Foundation
import Testing
@testable import CobaltKit

/// SwiftUI owns windows, scenes and the app's active/background state; AppLifecycle (CobaltKit/Lifecycle) is the one
/// place that listens to the OS about it (the lifecycle audit, learn.html "refined order"). Three crashes (8.27 scene
/// delegate recursion, two Mac loops in #113) and 37 private "is the app active" decisions came from code that decided
/// for itself. This test reads every app, extension and CobaltKit source file and refuses the patterns that bring that
/// back: returning the connecting session's configuration, reading scenePhase, observing app lifecycle notifications,
/// reading live model state inside an App/Scene body or `.commands`, and an `onChange(..., initial: true)` that clears
/// state. The owners (`CobaltKit/Lifecycle/` and `Cobalt/App/LifecycleEnvironment.swift`) are skipped.
///
/// What is already there is listed in apple/lifecycle-allowlist.txt, one `<finding> # reason` per line. A finding is
/// `[rule] path/from/apple.swift: <trimmed line>` without a line number, so an edit elsewhere in the file does not break
/// it. The test fails on a finding the list does not have, and on a list entry nothing matches any more, so the list
/// only shrinks. `UPDATE_LIFECYCLE_ALLOWLIST=1 swift test --filter LifecycleLint` rewrites it from the current tree,
/// keeping the reasons it already has. `scene-config` is never listable: it always fails.
@Suite struct LifecycleLintTests {
    static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let allowlistURL = appleRoot.appendingPathComponent("lifecycle-allowlist.txt")
    static let newReason = "lifecycle baseline 2026-11-21, move to AppLifecycle / \\.lifecycle"

    @Test func appCodeLeavesTheLifecycleToAppLifecycle() throws {
        let findings = try LifecycleLint.scan(appleRoot: Self.appleRoot)
        let existing = LifecycleLint.parseAllowlist((try? String(contentsOf: Self.allowlistURL, encoding: .utf8)) ?? "")

        if ProcessInfo.processInfo.environment["UPDATE_LIFECYCLE_ALLOWLIST"] == "1" {
            let text = LifecycleLint.renderAllowlist(findings: findings, reasons: existing, newReason: Self.newReason)
            try text.write(to: Self.allowlistURL, atomically: true, encoding: .utf8)
            return
        }

        let hard = findings.filter { $0.hasPrefix(LifecycleLint.hardPrefix) }.sorted()
        let listable = findings.subtracting(hard)
        let unlisted = listable.subtracting(existing.keys).sorted()
        let stale = Set(existing.keys).subtracting(listable).sorted()
        #expect(hard.isEmpty, """
            Never return `connectingSceneSession.configuration` from the app delegate: UIKit calls the delegate again for \
            the configuration it was handed and recursed until the app crashed (8.27). SwiftUI owns scenes; the delegate \
            only claims the external display role. This rule has no allowlist:
            \(hard.joined(separator: "\n"))
            """)
        #expect(unlisted.isEmpty, """
            Lifecycle code outside AppLifecycle (apple/ARCHITECTURE.md, lifecycle rules). Read `@Environment(\\.lifecycle)`, or \
            make the object `LifecycleAware`/`Purgeable` and register it with AppLifecycle.shared; keep App/Scene bodies and \
            `.commands` free of live state; never clear state in `onChange(..., initial: true)`. Or add the line to \
            apple/lifecycle-allowlist.txt with a reason:
            \(unlisted.joined(separator: "\n"))
            """)
        #expect(stale.isEmpty, """
            These apple/lifecycle-allowlist.txt entries match nothing any more; delete them so the list only shrinks:
            \(stale.joined(separator: "\n"))
            """)
    }

    // MARK: the scanner on small inputs

    @Test func sceneConfigurationIsAlwaysAFinding() {
        let source = """
            func application(_ app: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                             options: UIScene.ConnectionOptions) -> UISceneConfiguration {
                return connectingSceneSession.configuration
            }
            """
        let found = LifecycleLint.findings(path: "Cobalt/App/Delegate.swift", text: source)
        #expect(found == ["[scene-config] Cobalt/App/Delegate.swift: return connectingSceneSession.configuration"])
        #expect(found.allSatisfy { $0.hasPrefix(LifecycleLint.hardPrefix) })
    }

    @Test func scenePhaseIsAFinding() {
        let source = """
            struct Row: View {
                @Environment(\\.scenePhase) private var scenePhase
                var body: some View {
                    Text("x").onChange(of: scenePhase) { _, _ in }
                }
            }
            """
        #expect(LifecycleLint.findings(path: "Cobalt/Row.swift", text: source) == [
            "[scenePhase] Cobalt/Row.swift: @Environment(\\.scenePhase) private var scenePhase",
            "[scenePhase] Cobalt/Row.swift: Text(\"x\").onChange(of: scenePhase) { _, _ in }",
        ])
    }

    @Test func appNotificationsAreFindings() {
        let source = """
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in }
            let n = NSApplication.willResignActiveNotification
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in }
            let name = Notification.Name("UIApplicationDidEnterBackgroundNotification")
            let mac = Notification.Name("NSApplicationDidHideNotification")
            let other = UIApplication.significantTimeChangeNotification
            """
        let found = LifecycleLint.findings(path: "A.swift", text: source)
        #expect(found.count == 5)
        #expect(found.allSatisfy { $0.hasPrefix("[app-notification] A.swift: ") })
        #expect(!found.contains { $0.contains("significantTimeChange") })
    }

    @Test func sceneBodyAndCommandsMustNotReadLiveState() {
        let source = """
            @main struct CobaltApp: App {
                @State private var model = AppModel()
                var body: some Scene {
                    WindowGroup { Root().environment(model) }
                        .commands {
                            Button("Go") { }.disabled(model.queue.isEmpty)
                            Toggle("T", isOn: model.settings.flag)
                        }
                    Settings { Text(Prefs.shared.title) }
                }
                func helper() { _ = model.queue.count }
            }
            """
        #expect(LifecycleLint.findings(path: "Cobalt/App/CobaltApp.swift", text: source) == [
            "[scene-body-read] Cobalt/App/CobaltApp.swift: Button(\"Go\") { }.disabled(model.queue.isEmpty)",
            "[scene-body-read] Cobalt/App/CobaltApp.swift: Toggle(\"T\", isOn: model.settings.flag)",
            "[scene-body-read] Cobalt/App/CobaltApp.swift: Settings { Text(Prefs.shared.title) }",
        ])
        // not an App or Scene file: the rule does not apply
        #expect(LifecycleLint.findings(path: "V.swift", text: "struct V: View { var body: some View { Text(model.a.b) } }").isEmpty)
    }

    @Test func passingTheModelItselfIsNotARead() {
        let source = """
            struct CobaltApp: App {
                var body: some Scene {
                    WindowGroup { Root().environment(model).environment(\\.model, model) }
                }
            }
            """
        #expect(LifecycleLint.findings(path: "Cobalt/App/CobaltApp.swift", text: source).isEmpty)
    }

    @Test func initialOnChangeMustNotClear() {
        let source = """
            struct Split: View {
                var body: some View {
                    List { }
                        .onChange(of: sizeClass, initial: true) { _, new in
                            if new == .compact { selection = nil }
                        }
                        .onChange(of: id, initial: true) { _, _ in
                            load(id)
                        }
                        .onChange(of: items, initial: true) { _, _ in items.removeAll() }
                        .onChange(of: tab) { _, _ in selection = nil }
                        .onChange(of: x, initial: true) { _, v in if v == nil { ready = true } }
                }
            }
            """
        #expect(LifecycleLint.findings(path: "Cobalt/Split.swift", text: source) == [
            "[initial-clear] Cobalt/Split.swift: .onChange(of: sizeClass, initial: true) { _, new in",
            "[initial-clear] Cobalt/Split.swift: .onChange(of: items, initial: true) { _, _ in items.removeAll() }",
        ])
    }

    @Test func commentsAreIgnored() {
        let source = """
            // connectingSceneSession.configuration, scenePhase, UIApplication.didBecomeActiveNotification
            /* scenePhase */
            * scenePhase
            let ok = 1
            """
        #expect(LifecycleLint.findings(path: "C.swift", text: source).isEmpty)
    }

    @Test func theOwnerFilesAreSkipped() {
        let source = "NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in }"
        #expect(LifecycleLint.findings(path: "CobaltKit/Sources/CobaltKit/Lifecycle/AppLifecycle.swift", text: source).isEmpty)
        #expect(LifecycleLint.findings(path: "Cobalt/App/LifecycleEnvironment.swift", text: "@Environment(\\.scenePhase) var p").isEmpty)
        #expect(!LifecycleLint.findings(path: "Cobalt/App/Other.swift", text: source).isEmpty)
    }

    @Test func allowlistRoundTripsAndKeepsReasons() {
        let reasons = LifecycleLint.parseAllowlist("""
            # header
            [scenePhase] A.swift: @Environment(\\.scenePhase) var p # moves to \\.lifecycle in the home lane

            [scenePhase] B.swift: gone # gone now
            """)
        #expect(reasons == ["[scenePhase] A.swift: @Environment(\\.scenePhase) var p": "moves to \\.lifecycle in the home lane",
                            "[scenePhase] B.swift: gone": "gone now"])
        let text = LifecycleLint.renderAllowlist(
            findings: ["[scenePhase] A.swift: @Environment(\\.scenePhase) var p",
                       "[app-notification] C.swift: x",
                       "[scene-config] D.swift: return connectingSceneSession.configuration"],
            reasons: reasons, newReason: "new")
        let again = LifecycleLint.parseAllowlist(text)
        #expect(again == ["[scenePhase] A.swift: @Environment(\\.scenePhase) var p": "moves to \\.lifecycle in the home lane",
                          "[app-notification] C.swift: x": "new"])
    }
}

/// The scanner itself, kept apart from the tests so each rule reads in one place.
enum LifecycleLint {
    /// Folders scanned, relative to apple/. Tests and build output are not app code.
    static let roots = ["Cobalt", "CobaltKit/Sources", "CobaltShare", "CobaltWidgets", "CobaltKeyboard"]
    static let skippedFolders: Set<String> = ["Tests"]
    /// The owners of the lifecycle: they may read the OS notifications and scenePhase.
    static let ownerPrefixes = ["CobaltKit/Sources/CobaltKit/Lifecycle/"]
    static let ownerFiles: Set<String> = ["Cobalt/App/LifecycleEnvironment.swift"]
    static let hardPrefix = "[scene-config] "

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // the patterns are literals in this file; a typo should fail loudly
        try! NSRegularExpression(pattern: pattern)
    }

    private static let uiNames = "didBecomeActive|willResignActive|didEnterBackground|willEnterForeground|willTerminate|didReceiveMemoryWarning"
    private static let macNames = "didBecomeActive|willResignActive|didResignActive|didHide|didUnhide|willTerminate"
    /// `UIApplication.didBecomeActiveNotification`, `.willTerminateNotification` and the like.
    nonisolated(unsafe) static let notificationPattern = regex(
        #"\.(\#(uiNames)|\#(macNames))Notification\b"#)
    /// The string forms: `"UIApplicationDidBecomeActiveNotification"`, `"NSApplicationDidHideNotification"`.
    nonisolated(unsafe) static let notificationStringPattern = regex(
        #"(UI|NS)Application(DidBecomeActive|WillResignActive|DidResignActive|DidEnterBackground|WillEnterForeground|WillTerminate|DidReceiveMemoryWarning|DidHide|DidUnhide)Notification"#)

    /// A file that declares an App or a Scene.
    nonisolated(unsafe) static let sceneFilePattern = regex(#":\s*(App|Scene)\s*\{"#)
    /// The start of a Scene-building region: a `some Scene` property or function, or a `.commands` builder.
    nonisolated(unsafe) static let sceneRegionPattern = regex(
        #"\b(var|func)\b.*\bsome\s+Scene\b|\.commands\s*\{"#)
    /// A read of model state (a property of `model`, not `model` passed on) or of a singleton's property. A heuristic:
    /// it also flags a singleton method call, which is just as live.
    nonisolated(unsafe) static let sceneReadPattern = regex(
        #"(?<![A-Za-z0-9_])model\.[A-Za-z]+(\.|[^A-Za-z(]|$)|\.shared\.[A-Za-z]+"#)

    nonisolated(unsafe) static let initialOnChangePattern = regex(#"\.onChange\(of:.*initial:\s*true"#)
    /// A write that empties something. `==`, `!=` and `<=` comparisons do not count.
    nonisolated(unsafe) static let clearPattern = regex(
        #"(?<![=!<>])=\s*(nil\b|\[\]|\[:\]|Set\(\)|\.init\(\))|\.removeAll\("#)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isComment(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    static func isOwner(_ path: String) -> Bool {
        ownerFiles.contains(path) || ownerPrefixes.contains { path.hasPrefix($0) }
    }

    /// Every finding in one file, `[rule] path: <trimmed line>`.
    static func findings(path: String, text: String) -> Set<String> {
        if isOwner(path) { return [] }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let code = lines.map { isComment($0) ? "" : $0 }
        var out: Set<String> = []
        func add(_ rule: String, _ line: String) { out.insert("[\(rule)] \(path): \(line)") }

        for line in code where !line.isEmpty {
            if line.contains("connectingSceneSession.configuration") { add("scene-config", line) }
            if line.contains("scenePhase") { add("scenePhase", line) }
            if matches(notificationPattern, line) || matches(notificationStringPattern, line) { add("app-notification", line) }
        }

        // scene-body-read: brace counting finds the Scene builders, a cheap heuristic like MainThreadLint's, not a parser.
        if matches(sceneFilePattern, code.joined(separator: "\n")) {
            var depth = 0
            var regions: [Int] = []   // the brace depth each open Scene region started at
            var pending = false       // a Scene declaration whose `{` has not come yet
            for line in code where !line.isEmpty {
                let marker = matches(sceneRegionPattern, line)
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
                if (insideBefore || marker || !regions.isEmpty), matches(sceneReadPattern, line) { add("scene-body-read", line) }
            }
        }

        // initial-clear: the closure runs from the onChange line to its closing brace, at most 12 lines.
        for (index, line) in code.enumerated() where matches(initialOnChangePattern, line) {
            var depth = 0
            var opened = false
            var clears = false
            for next in code[index..<min(index + 12, code.count)] {
                if matches(clearPattern, next) { clears = true }
                for ch in next {
                    if ch == "{" { depth += 1; opened = true } else if ch == "}" { depth -= 1 }
                }
                if opened && depth <= 0 { break }
            }
            if clears { add("initial-clear", line) }
        }
        return out
    }

    /// Every finding under the app, extension and CobaltKit sources.
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

    /// `scene-config` findings are never written: that rule has no allowlist.
    static func renderAllowlist(findings: Set<String>, reasons: [String: String], newReason: String) -> String {
        var text = """
            # Lifecycle code that still decides for itself what AppLifecycle should (the lifecycle audit): scenePhase reads,
            # app lifecycle notifications, live state in App/Scene bodies or `.commands`, `onChange(initial: true)` that
            # clears state. One `<finding> # reason` per line; LifecycleLintTests fails on anything new and on entries that
            # no longer match, so this list may only shrink. `[scene-config]` is never listed. Regenerate with
            # UPDATE_LIFECYCLE_ALLOWLIST=1 (reasons are kept).

            """
        for finding in findings.sorted() where !finding.hasPrefix(hardPrefix) {
            let reason = reasons[finding].flatMap { $0.isEmpty ? nil : $0 } ?? newReason
            text += "\(finding) # \(reason)\n"
        }
        return text
    }
}
