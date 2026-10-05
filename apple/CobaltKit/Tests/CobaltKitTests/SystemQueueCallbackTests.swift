import Foundation
import Testing

/// Blocks the system calls on a queue of its own must never be inferred `@MainActor`.
///
/// Build 1.2 crashed on every upload: inside a `@MainActor` class, the closure handed to
/// `BGTaskScheduler.register(forTaskWithIdentifier:using: nil)` (a plain, non-`@Sendable` Objective-C block)
/// was inferred `@MainActor`, Swift 6 put an executor check at its entry, and the system's background
/// queue tripped it (`swift_task_reportUnexpectedExecutor`). A closure passed as an argument gets that check
/// (it traps); one assigned to a block property such as `BGTask.expirationHandler` gets none (it runs off
/// the main actor unchecked, a race if it touches main-actor state). `@Sendable` keeps both nonisolated.
///
/// Neither block can be run here: `BGTask` is iOS-only and has no public initialiser, so `swift test` (macOS)
/// cannot hand one to the closures. Pin them at the source, across every target that could hold one.
@Suite struct SystemQueueCallbackTests {
    private static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// (file, line number, trimmed line) for every non-comment Swift line under the app's source folders.
    private static func sourceLines() throws -> [(file: String, number: Int, text: String)] {
        let folders = ["CobaltKit/Sources", "Cobalt", "CobaltShare", "CobaltWidgets"]
        var out: [(String, Int, String)] = []
        for folder in folders {
            let root = appleRoot.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") { continue }
                    out.append((url.lastPathComponent, i + 1, line))
                }
            }
        }
        return out
    }

    @Test func backgroundTaskLaunchHandlersAreSendable() throws {
        let sites = try Self.sourceLines().filter { $0.text.contains("BGTaskScheduler.shared.register(") }
        #expect(!sites.isEmpty, "the scan found no launch handler: the guard would be vacuous")
        for site in sites {
            #expect(site.text.contains("{ @Sendable"), "\(site.file):\(site.number) launch handler must be `{ @Sendable task in`")
        }
    }

    @Test func backgroundTaskExpirationHandlersAreSendable() throws {
        let sites = try Self.sourceLines().filter { $0.text.contains(".expirationHandler = ") }
        #expect(!sites.isEmpty, "the scan found no expiration handler: the guard would be vacuous")
        for site in sites {
            #expect(
                site.text.contains(".expirationHandler = { @Sendable") || site.text.contains(".expirationHandler = nil"),
                "\(site.file):\(site.number) expiration handler must be `{ @Sendable in`")
        }
    }
}
