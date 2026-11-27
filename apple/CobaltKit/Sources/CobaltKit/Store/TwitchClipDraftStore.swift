import CoreGraphics
import Foundation
import ImageIO
import Observation

// Off-main storage actor + `@MainActor @Observable` store for Twitch stream clip drafts.
//
// Strictly follows `apple/ARCHITECTURE.md` Rule 1: zero `FileManager`, `Data(contentsOf:)`,
// `.write(to:)`, `JSONDecoder`/`JSONEncoder`, or `CGImageSource*` calls on `@MainActor`.

public enum TwitchClipExportError: Error, Sendable, Equatable, LocalizedError {
    case studioUnavailable
    case missingSourceVideo
    case uploadFailed(String)
    case renderFailed(String)
    case studioCreateFailed(EditError)

    public var errorDescription: String? {
        switch self {
        case .studioUnavailable:
            return "studio editor is not available on this server"
        case .missingSourceVideo:
            return "the clip video file is no longer on this device"
        case .uploadFailed(let msg):
            return msg.isEmpty ? "upload failed" : msg
        case .renderFailed(let msg):
            return msg.isEmpty ? "render failed" : msg
        case .studioCreateFailed(let err):
            return err.localizedDescription
        }
    }
}

public struct TwitchClipToast: Sendable, Equatable, Identifiable {
    public let id: String
    public let draftID: String
    public let title: String
    public let duration: Double
    public let chatLineCount: Int
    public let wasPartialBuffer: Bool
    public let requestedSeconds: Double?

    public init(result: TwitchClipSaveResult) {
        self.id = result.draft.id
        self.draftID = result.draft.id
        self.title = result.draft.title
        self.duration = result.draft.duration
        self.chatLineCount = result.draft.chatLineCount
        self.wasPartialBuffer = result.wasPartialBuffer
        self.requestedSeconds = result.requestedSeconds
    }
}

public actor TwitchClipStorage {
    public let directory: URL
    private let indexURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("drafts.json")
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func loadDrafts() -> [TwitchClipDraft] {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([TwitchClipDraft].self, from: data) else {
            return []
        }
        // Keep only drafts whose video file is still present on disk.
        return decoded
            .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.videoFileName).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func saveDrafts(_ drafts: [TwitchClipDraft]) {
        try? ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(drafts) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    public func hasAsset(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func removeFiles(for draft: TwitchClipDraft) {
        let fm = FileManager.default
        let names = [draft.videoFileName, draft.chatFileName, draft.thumbnailFileName].compactMap { $0 }
        for name in names {
            let url = directory.appendingPathComponent(name)
            try? fm.removeItem(at: url)
        }
    }

    public func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func loadChatLog(fileName: String, channel: String, duration: Double = 0) -> RecordedChatLog {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            return RecordedChatLog(channel: channel, duration: duration, entries: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RecordedChatLog.self, from: data))
            ?? RecordedChatLog(channel: channel, duration: duration, entries: [])
    }

    public func loadThumbnail(fileName: String, maxPixelSize: Int = 480) -> CGImage? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

@MainActor @Observable
public final class TwitchClipDraftStore {
    public enum ExportState: Sendable, Equatable {
        case idle
        case sendingToStudio(draftID: String, stage: String)
        case rendering(draftID: String, progress: Double, stage: String)
        case done(draftID: String, message: String)
        case failed(draftID: String, message: String)
    }

    public private(set) var drafts: [TwitchClipDraft] = []
    public var capture: TwitchClipCaptureState = .idle
    /// Selected instant-clip rolling window (`30` or `60` seconds).
    public var selectedClipDuration: Int = 30
    /// Non-blocking save confirmation toast on the Twitch watch view.
    public var toast: TwitchClipToast?
    /// Active export / Studio handoff state.
    public private(set) var exportState: ExportState = .idle
    /// Set by UI to present a specific draft in the split-frame editor.
    public var presentedDraftID: String?
    /// Render stats from the most recent `renderAndUpload` run (for PostHog telemetry).
    public private(set) var lastRenderStats: TwitchClipRenderStats?

    public nonisolated let directory: URL
    @ObservationIgnored private let storage: TwitchClipStorage
    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var booted = false

    public var unreadCount: Int { drafts.count(where: { $0.isFresh }) }

    public var isExporting: Bool {
        switch exportState {
        case .sendingToStudio, .rendering: return true
        case .idle, .done, .failed: return false
        }
    }

    init(context: PipelineContext, directory: URL? = nil) {
        self.ctx = context
        let dir = directory
            ?? context.store.root.deletingLastPathComponent().appendingPathComponent("TwitchClips", isDirectory: true)
        self.directory = dir
        self.storage = TwitchClipStorage(directory: dir)
    }

    /// Loads persisted drafts off the main thread. Safe to call repeatedly.
    public func boot() async {
        guard !booted else { return }
        booted = true
        let loaded = await storage.loadDrafts()
        if !loaded.isEmpty {
            // Merge any drafts created during this session before boot finished.
            let existingIDs = Set(drafts.map(\.id))
            let combined = (drafts + loaded.filter { !existingIDs.contains($0.id) })
                .sorted { $0.createdAt > $1.createdAt }
            drafts = combined
        }
    }

    public func draft(id: String) -> TwitchClipDraft? {
        drafts.first { $0.id == id }
    }

    public func videoURL(for draft: TwitchClipDraft) -> URL {
        directory.appendingPathComponent(draft.videoFileName)
    }

    public func chatURL(for draft: TwitchClipDraft) -> URL {
        directory.appendingPathComponent(draft.chatFileName)
    }

    public func thumbnailURL(for draft: TwitchClipDraft) -> URL? {
        draft.thumbnailFileName.map { directory.appendingPathComponent($0) }
    }

    public func loadChatLog(for draft: TwitchClipDraft) async -> RecordedChatLog {
        await storage.loadChatLog(fileName: draft.chatFileName, channel: draft.channel, duration: draft.duration)
    }

    public func loadThumbnail(for draft: TwitchClipDraft, maxPixelSize: Int = 480) async -> CGImage? {
        guard let name = draft.thumbnailFileName else { return nil }
        return await storage.loadThumbnail(fileName: name, maxPixelSize: maxPixelSize)
    }

    /// Inserts a newly recorded clip/recording draft, persists the index off-main, and shows a non-blocking toast.
    public func recordSaved(_ result: TwitchClipSaveResult) {
        drafts.removeAll { $0.id == result.draft.id }
        drafts.insert(result.draft, at: 0)
        persistSoon(immediate: true)
        showToast(TwitchClipToast(result: result))
    }

    public func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    private func showToast(_ item: TwitchClipToast) {
        toastTask?.cancel()
        toast = item
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.toast?.id == item.id else { return }
            self?.toast = nil
        }
    }

    /// Updates a draft's split-frame / chat editing configuration and persists with a short debounce.
    public func updateEdit(draftID: String, _ mutate: (inout TwitchClipEditConfig) -> Void) {
        guard let idx = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var copy = drafts[idx]
        mutate(&copy.edit)
        copy.updatedAt = Date()
        drafts[idx] = copy
        persistSoon(immediate: false)
    }

    public func rename(draftID: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[idx].title = String(clean.prefix(60))
        drafts[idx].updatedAt = Date()
        persistSoon(immediate: true)
    }

    public func markSeen(draftID: String) {
        guard let idx = drafts.firstIndex(where: { $0.id == draftID }), drafts[idx].isFresh else { return }
        drafts[idx].isFresh = false
        persistSoon(immediate: true)
    }

    public func markAllSeen() {
        var changed = false
        for i in drafts.indices where drafts[i].isFresh {
            drafts[i].isFresh = false
            changed = true
        }
        if changed { persistSoon(immediate: true) }
    }

    public func delete(draftID: String) {
        guard let idx = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        let removed = drafts.remove(at: idx)
        if presentedDraftID == draftID { presentedDraftID = nil }
        persistSoon(immediate: true)
        Task { [storage] in
            await storage.removeFiles(for: removed)
        }
    }

    public func clearExportState() {
        if !isExporting { exportState = .idle }
    }

    // MARK: - Send to Studio (Without Rendering Video!)

    /// Uploads the unrendered 16:9 passthrough MP4 (+ optional event-driven transparent chat GIF for Lane 2),
    /// builds a native Cobalt Editor v2 `EditTimeline` (Lane 0 = B, Lane 1 = A, Lane 2 = Chat),
    /// creates the Studio project, and opens it directly in `EditorStore`.
    public func sendToStudio(
        draft: TwitchClipDraft,
        editor: EditorStore,
        openImmediately: Bool = true
    ) async throws -> EditProject {
        guard editor.isAvailable else {
            let err = TwitchClipExportError.studioUnavailable
            exportState = .failed(draftID: draft.id, message: err.localizedDescription)
            throw err
        }

        let currentDraft = self.draft(id: draft.id) ?? draft
        let localVideoURL = videoURL(for: currentDraft)
        guard await storage.hasAsset(at: localVideoURL) else {
            let err = TwitchClipExportError.missingSourceVideo
            exportState = .failed(draftID: currentDraft.id, message: err.localizedDescription)
            throw err
        }

        let client = ctx.client
        var locals: [(String, URL)] = []

        // Step 1: Upload raw 16:9 MP4 once (no re-encoding) or reuse its library item id.
        let videoItemID: String
        if let existing = currentDraft.uploadedVideoItemID {
            videoItemID = existing
            locals.append((existing, localVideoURL))
        } else {
            exportState = .sendingToStudio(draftID: currentDraft.id, stage: "uploading clip…")
            do {
                let uploaded = try await client.upload(
                    file: localVideoURL,
                    name: Self.safeFilename(currentDraft.title, ext: "mp4"),
                    contentType: "video/mp4",
                    public: false,
                    queue: false,
                    title: currentDraft.title,
                    progress: { _ in }
                )
                videoItemID = uploaded.item.id
                locals.append((videoItemID, localVideoURL))
                setUploadMetadata(draftID: currentDraft.id, videoItemID: videoItemID, studioProjectID: nil)
            } catch {
                let err = TwitchClipExportError.uploadFailed(error.localizedDescription)
                exportState = .failed(draftID: currentDraft.id, message: err.localizedDescription)
                throw err
            }
        }

        // Step 2: If chat is enabled and present, synthesize a compact transparent animated GIF for Lane 2.
        var chatItemID: String?
        if currentDraft.edit.chat.enabled, currentDraft.chatLineCount > 0 {
            exportState = .sendingToStudio(draftID: currentDraft.id, stage: "packing synced chat…")
            let log = await loadChatLog(for: currentDraft)
            if !log.entries.isEmpty {
                let gifURL = directory.appendingPathComponent("\(currentDraft.id)-studio-chat.gif")
                do {
                    _ = try await TwitchClipRenderer.renderChatGIF(
                        log: log,
                        config: currentDraft.edit,
                        duration: currentDraft.duration,
                        to: gifURL
                    )
                    let uploadedChat = try await client.upload(
                        file: gifURL,
                        name: Self.safeFilename("\(currentDraft.title)-chat", ext: "gif"),
                        contentType: "image/gif",
                        public: false,
                        queue: false,
                        title: "\(currentDraft.title) · chat",
                        progress: { _ in }
                    )
                    chatItemID = uploadedChat.item.id
                    locals.append((uploadedChat.item.id, gifURL))
                } catch {
                    // Best-effort: if chat GIF synthesis/upload fails, still hand off the split-frame video to Studio.
                    await storage.removeFile(at: gifURL)
                }
            }
        }

        // Step 3: Build v2 EditTimeline and open in Studio without rendering!
        exportState = .sendingToStudio(draftID: currentDraft.id, stage: "opening in studio…")
        let timeline = TwitchClipTimelineBridge.buildStudioTimeline(
            draft: currentDraft,
            videoItemID: videoItemID,
            chatItemID: chatItemID,
            fps: 30
        )

        do {
            let project = try await editor.create(
                title: currentDraft.title,
                timeline: timeline,
                locals: locals,
                openImmediately: openImmediately
            )
            setUploadMetadata(draftID: currentDraft.id, videoItemID: videoItemID, studioProjectID: project.id)
            exportState = .done(draftID: currentDraft.id, message: "sent to studio")
            return project
        } catch {
            let err = TwitchClipExportError.studioCreateFailed(error)
            exportState = .failed(draftID: currentDraft.id, message: err.localizedDescription)
            throw err
        }
    }

    // MARK: - Direct Render to Private Library

    /// Renders the 9:16 1080×1920 composite MP4 (Region A/B split-frame + burned-in chat overlay)
    /// and uploads it to the Library as private.
    public func renderAndUpload(draft: TwitchClipDraft) async throws -> UploadResult {
        let currentDraft = self.draft(id: draft.id) ?? draft
        let localVideoURL = videoURL(for: currentDraft)
        guard await storage.hasAsset(at: localVideoURL) else {
            let err = TwitchClipExportError.missingSourceVideo
            exportState = .failed(draftID: currentDraft.id, message: err.localizedDescription)
            throw err
        }

        exportState = .rendering(draftID: currentDraft.id, progress: 0.02, stage: "rendering 9:16…")
        let log = await loadChatLog(for: currentDraft)
        let outURL = directory.appendingPathComponent("\(currentDraft.id)-render.mp4")

        lastRenderStats = nil
        do {
            lastRenderStats = try await TwitchClipRenderer.renderCompositeMP4(
                videoURL: localVideoURL,
                log: log,
                config: currentDraft.edit,
                duration: currentDraft.duration,
                outputURL: outURL,
                progress: { [weak self] frac in
                    Task { @MainActor [weak self] in
                        self?.exportState = .rendering(
                            draftID: currentDraft.id,
                            progress: min(0.85, max(0.02, frac * 0.85)),
                            stage: "rendering 9:16…"
                        )
                    }
                }
            )
        } catch {
            await storage.removeFile(at: outURL)
            let err = TwitchClipExportError.renderFailed(error.localizedDescription)
            exportState = .failed(draftID: currentDraft.id, message: err.localizedDescription)
            throw err
        }

        exportState = .rendering(draftID: currentDraft.id, progress: 0.88, stage: "saving to library…")
        do {
            let result = try await ctx.client.upload(
                file: outURL,
                name: Self.safeFilename(currentDraft.title, ext: "mp4"),
                contentType: "video/mp4",
                public: false,
                queue: false,
                title: currentDraft.title,
                progress: { [weak self] transfer in
                    guard let total = transfer.total, total > 0 else { return }
                    let frac = 0.88 + 0.12 * min(1, Double(transfer.bytes) / Double(total))
                    Task { @MainActor [weak self] in
                        self?.exportState = .rendering(
                            draftID: currentDraft.id,
                            progress: frac,
                            stage: "saving to library…"
                        )
                    }
                }
            )
            await storage.removeFile(at: outURL)
            exportState = .done(draftID: currentDraft.id, message: "saved to library (private)")
            return result
        } catch {
            await storage.removeFile(at: outURL)
            let err = TwitchClipExportError.uploadFailed(error.localizedDescription)
            exportState = .failed(draftID: currentDraft.id, message: err.localizedDescription)
            throw err
        }
    }

    // MARK: - Helpers

    private func setUploadMetadata(draftID: String, videoItemID: String?, studioProjectID: String?) {
        guard let idx = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        if let videoItemID { drafts[idx].uploadedVideoItemID = videoItemID }
        if let studioProjectID { drafts[idx].studioProjectID = studioProjectID }
        drafts[idx].updatedAt = Date()
        persistSoon(immediate: true)
    }

    private func persistSoon(immediate: Bool) {
        saveTask?.cancel()
        let snapshot = drafts
        let storage = self.storage
        saveTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await storage.saveDrafts(snapshot)
        }
    }

    private static func safeFilename(_ title: String, ext: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = title.unicodeScalars.filter { allowed.contains($0) }
        let base = String(filtered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let stem = base.isEmpty ? "twitch-clip" : String(base.prefix(48))
        return "\(stem).\(ext)"
    }
}
