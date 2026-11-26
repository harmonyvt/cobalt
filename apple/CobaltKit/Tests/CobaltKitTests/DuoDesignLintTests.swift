import Foundation
import Testing
@testable import CobaltKit

/// Enforces the iPhone Duo & Liquid Glass architecture rules (apple/ARCHITECTURE.md rules 14–18) across every
/// Swift file in `apple/Cobalt/`.
///
/// Rules:
/// - `[idiom-lock]` (listable for non-layout copy/hardware metadata only): no `userInterfaceIdiom` checks in UI code;
///   branch on `@Environment(\.horizontalSizeClass)` and measured geometry instead.
/// - `[tab-bar-lock]` (hard): never lock `.tabBarMinimizeBehavior(.never)` on a `TabView`.
/// - `[text-only-toolbar]` (hard): every button inside `ToolbarItem` / `ToolbarItemGroup` must carry an SF Symbol
///   (`Label(title, systemImage:)`, `Button(..., systemImage:)`, or `DuoToolbarButton`), never a text-only `Button("...")`.
/// - `[odd-grid-columns]` (hard): never hardcode odd column counts (`count: 3`, `5`, `7`, `9`) in `LazyVGrid`;
///   use `DuoAdaptiveGrid` or `DuoGrid.fixedGridItems`.
/// - `[orientation-lock]` (hard): never override `supportedInterfaceOrientations` or query `DeviceHinge` / `hingeAngle`.
/// - `[arrangement-nesting]` (hard): never nest `TabView` or `NavigationSplitView` inside `ArrangementView`, `DuoSplit`,
///   or `DuoMediaOverlay`.
/// - `[opaque-glass-backing]` (hard): never place an opaque `.background(..., in: ...)` immediately adjacent to
///   `.glassEffect(...)`.
///
/// `UPDATE_DUO_DESIGN_ALLOWLIST=1 swift test --filter DuoDesignLint` rewrites `apple/duo-design-allowlist.txt`
/// from the current tree while preserving existing reasons.
@Suite struct DuoDesignLintTests {
    static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let allowlistURL = appleRoot.appendingPathComponent("duo-design-allowlist.txt")
    static let newReason = "non-layout idiom metadata (never use for layout)"

    @Test func appViewsComplyWithIPhoneDuoAndLiquidGlassRules() throws {
        let findings = try DuoDesignLint.scan(appleRoot: Self.appleRoot)
        let existing = DuoDesignLint.parseAllowlist((try? String(contentsOf: Self.allowlistURL, encoding: .utf8)) ?? "")

        let hard = findings.filter { DuoDesignLint.isHard($0) }.sorted()
        let listable = findings.subtracting(hard)

        if ProcessInfo.processInfo.environment["UPDATE_DUO_DESIGN_ALLOWLIST"] == "1" {
            let text = DuoDesignLint.renderAllowlist(findings: listable, reasons: existing, newReason: Self.newReason)
            try text.write(to: Self.allowlistURL, atomically: true, encoding: .utf8)
            return
        }

        let unlisted = listable.subtracting(existing.keys).sorted()
        let stale = Set(existing.keys).subtracting(listable).sorted()

        #expect(hard.isEmpty, """
            Hard iPhone Duo / Liquid Glass rule violation (apple/ARCHITECTURE.md rules 14–18). These rules have no allowlist:
            \(hard.joined(separator: "\n"))
            """)
        #expect(unlisted.isEmpty, """
            Unexpected `userInterfaceIdiom` usage in UI code (apple/ARCHITECTURE.md rule 14). Branch on \
            `@Environment(\\.horizontalSizeClass)` instead, or if genuinely non-layout hardware/copy metadata, add it to \
            apple/duo-design-allowlist.txt with a reason:
            \(unlisted.joined(separator: "\n"))
            """)
        #expect(stale.isEmpty, """
            These apple/duo-design-allowlist.txt entries match nothing any more; delete them so the list only shrinks:
            \(stale.joined(separator: "\n"))
            """)
    }

    // MARK: unit tests on synthetic snippets

    @Test func detectsIdiomLocksAndTabBarLocks() {
        let source = """
            struct BadShell: View {
                var body: some View {
                    let isPhone = UIDevice.current.userInterfaceIdiom == .phone
                    TabView { Text(isPhone ? "a" : "b") }
                        .tabBarMinimizeBehavior(.never)
                }
            }
            """
        let found = DuoDesignLint.findings(path: "Cobalt/BadShell.swift", text: source)
        #expect(found.contains("[idiom-lock] Cobalt/BadShell.swift: let isPhone = UIDevice.current.userInterfaceIdiom == .phone"))
        #expect(found.contains("[tab-bar-lock] Cobalt/BadShell.swift: .tabBarMinimizeBehavior(.never)"))
    }

    @Test func detectsTextOnlyToolbarButtonsButAllowsIconsAndDuoToolbarButton() {
        let source = """
            struct Sheet: View {
                var body: some View {
                    Text("hi").toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { } }
                        ToolbarItem(placement: .cancellationAction) {
                            DuoToolbarButton(title: "Cancel", systemImage: "xmark") { }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Edit", systemImage: "pencil") { }
                        }
                        ToolbarItem(placement: .automatic) {
                            Button { } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            """
        let found = DuoDesignLint.findings(path: "Cobalt/Sheet.swift", text: source)
        #expect(found == ["[text-only-toolbar] Cobalt/Sheet.swift: ToolbarItem(placement: .confirmationAction) { Button(\"Done\") { } }"])
    }

    @Test func detectsOddGridColumns() {
        let source = """
            struct PickerGrid: View {
                var body: some View {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        Text("a")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        Text("b")
                    }
                }
            }
            """
        let found = DuoDesignLint.findings(path: "Cobalt/PickerGrid.swift", text: source)
        #expect(found == [
            "[odd-grid-columns] Cobalt/PickerGrid.swift: LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {",
        ])
    }

    @Test func detectsOrientationLocksAndHingeQueries() {
        let source = """
            final class Controller {
                var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
                let angle = DeviceHinge.angle
            }
            """
        let found = DuoDesignLint.findings(path: "Cobalt/Controller.swift", text: source)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.hasPrefix("[orientation-lock]") })
    }

    @Test func detectsTabViewOrNavigationSplitViewInsideArrangement() {
        let source = """
            struct BadWorkspace: View {
                var body: some View {
                    DuoSplit(ratio: 0.5) {
                        TabView { Text("a") }
                    } secondary: {
                        NavigationSplitView { Text("b") } detail: { Text("c") }
                    }
                }
            }
            """
        let found = DuoDesignLint.findings(path: "Cobalt/BadWorkspace.swift", text: source)
        #expect(found == [
            "[arrangement-nesting] Cobalt/BadWorkspace.swift: TabView { Text(\"a\") }",
            "[arrangement-nesting] Cobalt/BadWorkspace.swift: NavigationSplitView { Text(\"b\") } detail: { Text(\"c\") }",
        ])
    }

    @Test func detectsOpaqueBackgroundAdjacentToGlassEffect() {
        let source = """
            struct BadPill: View {
                var body: some View {
                    Text("Render")
                        .background(CobaltColor.text, in: Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            """
        let found = DuoDesignLint.findings(path: "Cobalt/BadPill.swift", text: source)
        #expect(found == [
            "[opaque-glass-backing] Cobalt/BadPill.swift: .glassEffect(.regular.interactive(), in: .capsule)",
        ])
    }

    @Test func commentsAreIgnored() {
        let source = """
            // Never use UIDevice.current.userInterfaceIdiom or .tabBarMinimizeBehavior(.never)
            /* Array(repeating: GridItem(.flexible()), count: 3) */
            struct Clean: View { var body: some View { Text("ok") } }
            """
        #expect(DuoDesignLint.findings(path: "Cobalt/Clean.swift", text: source).isEmpty)
    }
}

// MARK: - Scanner

private enum DuoDesignLint {
    static let hardPrefixes = [
        "[tab-bar-lock] ",
        "[text-only-toolbar] ",
        "[odd-grid-columns] ",
        "[orientation-lock] ",
        "[arrangement-nesting] ",
        "[opaque-glass-backing] ",
    ]

    static func isHard(_ finding: String) -> Bool {
        hardPrefixes.contains { finding.hasPrefix($0) }
    }

    static func scan(appleRoot: URL) throws -> Set<String> {
        let cobaltRoot = appleRoot.appendingPathComponent("Cobalt")
        guard let enumerator = FileManager.default.enumerator(
            at: cobaltRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var all: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: appleRoot.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)
            all.formUnion(findings(path: relative, text: text))
        }
        return all
    }

    static func findings(path: String, text: String) -> [String] {
        var out: [String] = []
        let rawLines = text.components(separatedBy: .newlines)
        var inBlockComment = false

        // Track brace depths for ToolbarItem blocks and ArrangementView / DuoSplit / DuoMediaOverlay blocks.
        var braceDepth = 0
        var toolbarItemEndDepths: [Int] = []
        var arrangementEndDepths: [Int] = []
        var previousCodeLine = ""

        for raw in rawLines {
            let code = stripComments(raw, inBlockComment: &inBlockComment)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let delta = braceDelta(code)

            if trimmed.isEmpty {
                braceDepth += delta
                continue
            }

            // Enter ToolbarItem / ToolbarItemGroup scope
            let startsToolbar = trimmed.contains("ToolbarItem(") || trimmed.contains("ToolbarItemGroup(")
            if startsToolbar {
                if delta > 0 {
                    toolbarItemEndDepths.append(braceDepth)
                }
            }

            // Enter ArrangementView / DuoSplit / DuoMediaOverlay scope
            let startsArrangement = trimmed.contains("ArrangementView") || trimmed.contains("DuoSplit(") || trimmed.contains("DuoMediaOverlay(")
            if startsArrangement && delta > 0 {
                arrangementEndDepths.append(braceDepth)
            }

            let inToolbar = startsToolbar || !toolbarItemEndDepths.isEmpty
            let inArrangement = !arrangementEndDepths.isEmpty

            // 1. [idiom-lock]
            if trimmed.contains("userInterfaceIdiom") {
                out.append("[idiom-lock] \(path): \(trimmed)")
            }

            // 2. [tab-bar-lock]
            if trimmed.contains(".tabBarMinimizeBehavior(.never)") {
                out.append("[tab-bar-lock] \(path): \(trimmed)")
            }

            // 3. [text-only-toolbar]
            if inToolbar, containsTextOnlyButton(trimmed) {
                out.append("[text-only-toolbar] \(path): \(trimmed)")
            }

            // 4. [odd-grid-columns]
            if containsHardcodedOddGridCount(trimmed) {
                out.append("[odd-grid-columns] \(path): \(trimmed)")
            }

            // 5. [orientation-lock]
            if trimmed.contains("supportedInterfaceOrientations")
                || trimmed.contains("DeviceHinge")
                || trimmed.contains("hingeAngle")
            {
                out.append("[orientation-lock] \(path): \(trimmed)")
            }

            // 6. [arrangement-nesting]
            if inArrangement, (trimmed.contains("TabView") || trimmed.contains("NavigationSplitView")) {
                out.append("[arrangement-nesting] \(path): \(trimmed)")
            }

            // 7. [opaque-glass-backing]
            if trimmed.contains(".glassEffect("), isOpaqueShapeBackground(previousCodeLine) {
                out.append("[opaque-glass-backing] \(path): \(trimmed)")
            }

            braceDepth += delta
            while let top = toolbarItemEndDepths.last, braceDepth <= top {
                toolbarItemEndDepths.removeLast()
            }
            while let top = arrangementEndDepths.last, braceDepth <= top {
                arrangementEndDepths.removeLast()
            }

            previousCodeLine = trimmed
        }

        return out
    }

    private static func containsTextOnlyButton(_ line: String) -> Bool {
        guard line.contains("Button(") else { return false }
        // Allowed: DuoToolbarButton, systemImage:, Label(, role: with label closure, or action: with label closure
        if line.contains("DuoToolbarButton(") { return false }
        if line.contains("systemImage:") { return false }
        if line.contains("Label(") { return false }
        if line.contains("action:") { return false }
        if line.contains("label:") { return false }
        // Match `Button(<title>...) {` without `systemImage:` (e.g., `Button("Done") {` or `Button(Copy.x) {`)
        let pattern = #"\bButton\s*\([^)]*\)\s*\{"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsHardcodedOddGridCount(_ line: String) -> Bool {
        guard line.contains("GridItem("), line.contains("repeating:") else { return false }
        let pattern = #"count:\s*(3|5|7|9)\b"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isOpaqueShapeBackground(_ line: String) -> Bool {
        guard line.hasPrefix(".background("), line.contains(", in:") else { return false }
        // Ignore clear / material backgrounds
        if line.contains(".clear") || line.contains("Material") || line.contains(".bar") { return false }
        return true
    }

    private static func braceDelta(_ line: String) -> Int {
        var delta = 0
        var inString = false
        var escape = false
        for ch in line {
            if escape { escape = false; continue }
            if ch == "\\" && inString { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if !inString {
                if ch == "{" { delta += 1 }
                else if ch == "}" { delta -= 1 }
            }
        }
        return delta
    }

    private static func stripComments(_ line: String, inBlockComment: inout Bool) -> String {
        var result = ""
        let chars = Array(line)
        var i = 0
        var inString = false
        var escape = false

        while i < chars.count {
            if inBlockComment {
                if i + 1 < chars.count && chars[i] == "*" && chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            let c = chars[i]
            if escape {
                result.append(c)
                escape = false
                i += 1
                continue
            }
            if c == "\\" && inString {
                result.append(c)
                escape = true
                i += 1
                continue
            }
            if c == "\"" {
                inString.toggle()
                result.append(c)
                i += 1
                continue
            }
            if !inString && i + 1 < chars.count {
                if chars[i] == "/" && chars[i + 1] == "/" {
                    break
                }
                if chars[i] == "/" && chars[i + 1] == "*" {
                    inBlockComment = true
                    i += 2
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    static func parseAllowlist(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let hash = trimmed.range(of: " # ") {
                let key = String(trimmed[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
                let reason = String(trimmed[hash.upperBound...]).trimmingCharacters(in: .whitespaces)
                map[key] = reason
            } else {
                map[trimmed] = ""
            }
        }
        return map
    }

    static func renderAllowlist(findings: Set<String>, reasons: [String: String], newReason: String) -> String {
        var lines = [
            "# Non-layout exceptions to the iPhone Duo & Liquid Glass architectural lints (apple/ARCHITECTURE.md rules 14-18).",
            "# One `<finding> # reason` per line; DuoDesignLintTests fails on anything new and on entries that no longer match,",
            "# so this list may only shrink. Hard rules (`[tab-bar-lock]`, `[text-only-toolbar]`, `[odd-grid-columns]`,",
            "# `[orientation-lock]`, `[arrangement-nesting]`, `[opaque-glass-backing]`) are never listable.",
            "# Regenerate with UPDATE_DUO_DESIGN_ALLOWLIST=1 swift test --filter DuoDesignLint (reasons are kept).",
        ]
        for finding in findings.sorted() {
            let reason = reasons[finding] ?? newReason
            lines.append("\(finding) # \(reason)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
