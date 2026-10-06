import AppIntents
import CobaltKit
import Foundation
import UniformTypeIdentifiers

/// "Upload files" (CONTRACT-PARALLEL.md 15.4): iOS and macOS 27. The bytes go up inside `performBackgroundTask`, so the
/// system keeps the process, shows its own progress (bytes sent) and a stop button. Each file is copied into the app's
/// inbox first (the system's temporary file may go as soon as the action returns), then sent like any upload job, into
/// the server's line.
@available(iOS 27, macOS 27, *)
struct UploadFilesIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Upload files"
    static let description = IntentDescription(
        "Uploads videos and images to cobalt, which saves them to your library.", categoryName: "cobalt")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    /// What the server's upload route takes (APP-API-CONTRACT 3, `UPLOAD_TYPES`).
    @Parameter(
        title: "Files", supportedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .gif, .png, .jpeg, .heic, .webP])
    var files: [IntentFile]

    @Parameter(title: "Title", description: "Names the save. Used when there is exactly one file.")
    var saveTitle: String?

    @Parameter(title: "Visibility", default: .appDefault)
    var visibility: CobaltVisibility

    @Parameter(title: "Wait until saved", description: "Returns when cobalt has saved them, with their public links.", default: false)
    var waitUntilSaved: Bool

    @Dependency var actions: ShortcutActions

    static var parameterSummary: some ParameterSummary {
        Summary("Upload \(\.$files)") {
            \.$saveTitle
            \.$visibility
            \.$waitUntilSaved
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CobaltSave]> & ProvidesDialog {
        do {
            let ready = try await actions.prepare()
            var allowDeviceLine = false
            if !ready.hasLine {
                guard await continueInForegroundIfNeeded(Copy.Shortcuts.continueForOldServer) else { throw ShortcutError.oldServer }
                allowDeviceLine = true
            }
            let sources = files.map(Self.shortcutFile)
            let cancel = ShortcutCancel()
            let report: ShortcutProgress = { done, total in
                progress.totalUnitCount = total
                progress.completedUnitCount = done
            }
            let waits = waitUntilSaved
            let deviceLine = allowDeviceLine
            let title = saveTitle
            let visibility = visibility.shortcut
            let actions = actions
            let outcome = try await performBackgroundTask(
                operation: { @Sendable in
                    var outcome = try await actions.uploadFiles(
                        sources, title: title, visibility: visibility, then: waits ? .wait : .leave,
                        allowDeviceLine: deviceLine, cancel: cancel, progress: report)
                    if waits { outcome = try await actions.waitUntilSaved(outcome, cancel: cancel, progress: report) }
                    return outcome
                },
                onCancel: { _ in cancel.cancel() })
            return IntentResults.saves(outcome.saves, dialog: outcome.isPartial ? Copy.Shortcuts.partial(outcome, noun: "file") : nil)
        } catch {
            throw IntentErrors.map(error)
        }
    }

    /// The system's file URL when it gives one (copied before the action returns), else a reader for its bytes that runs
    /// later, inside the background task, one file at a time (`IntentFile.data` loads the whole file into memory: a big
    /// Photos video read up front, with its neighbours and before the size limit, is a memory kill). A name with no
    /// extension takes its type's, so the server's own type check has something to go on.
    private static func shortcutFile(_ file: IntentFile) -> ShortcutFile {
        var name = file.filename
        if (name as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension { name += ".\(ext)" }
        if let url = file.fileURL { return ShortcutFile(name: name, source: .url(url)) }
        return ShortcutFile(name: name, source: .deferred { file.data })
    }

    @MainActor
    private func continueInForegroundIfNeeded(_ words: String) async -> Bool {
        if systemContext.currentMode == .foreground { return true }
        guard systemContext.currentMode.canContinueInForeground else { return false }
        do {
            try await continueInForeground(IntentErrors.dialog(words), alwaysConfirm: false)
            return true
        } catch {
            return false
        }
    }
}
