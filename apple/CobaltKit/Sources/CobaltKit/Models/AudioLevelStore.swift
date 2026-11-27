import Foundation
import Observation

/// Server-wide audio loudness leveling settings, per-item actions, and backfill state (`features.audio_leveling`).
@MainActor @Observable
public final class AudioLevelStore {
    public private(set) var settings: AudioLevelSettings = .init()
    public private(set) var loaded = false
    public private(set) var loading = false
    public private(set) var saving = false
    public private(set) var backfilling = false
    public private(set) var lastBackfill: AudioBackfillResult?
    public private(set) var lastError: String?
    /// Library file IDs currently submitting a level or remove request.
    public private(set) var inFlightItems: Set<String> = []

    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]

    init(context: PipelineContext, library: LibraryModel) {
        self.ctx = context
        self.library = library
    }

    public var isAvailable: Bool {
        ctx.capabilities.audioLeveling
    }

    public func reset() {
        for task in pollTasks.values { task.cancel() }
        pollTasks.removeAll()
        settings = .init()
        loaded = false
        loading = false
        saving = false
        backfilling = false
        lastBackfill = nil
        lastError = nil
        inFlightItems.removeAll()
    }

    /// Loads `GET /audio/settings` if the server supports `features.audio_leveling`.
    public func load(force: Bool = false) async {
        guard isAvailable else { return }
        if loading { return }
        if loaded && !force { return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await ctx.client.audioSettings()
            settings = fetched
            loaded = true
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Updates `PUT /audio/settings` optimistically and reconciles with the server response.
    public func update(_ patch: AudioLevelSettingsPatch) async {
        guard isAvailable else { return }
        let previous = settings
        if let mode = patch.mode { settings.mode = mode }
        if let target = patch.target { settings.target = target }
        if let link = patch.defaultLink { settings.defaultLink = link }
        saving = true
        defer { saving = false }
        do {
            let updated = try await ctx.client.updateAudioSettings(patch)
            settings = updated
            loaded = true
            lastError = nil
        } catch {
            settings = previous
            lastError = Self.describe(error)
        }
    }

    /// Queues 2-pass EBU R128 loudness leveling for `fileID` (`POST /library/items/:id/audio/level`),
    /// optimistically flips the library file to `.rendering`, and polls library refresh until it settles.
    @discardableResult
    public func levelItem(id fileID: String, target: AudioTargetLufs? = nil) async throws -> AudioLevelQueued {
        guard isAvailable else { throw PipelineFailure.unsupported }
        let chosenTarget = target ?? settings.target
        inFlightItems.insert(fileID)
        defer { inFlightItems.remove(fileID) }

        let previousFile = library.file(id: fileID)
        if var optimistic = previousFile {
            var info = optimistic.audio ?? AudioLoudnessInfo()
            info.state = .rendering
            info.targetLufs = chosenTarget.rawValue
            info.error = nil
            optimistic.audio = info
            library.replace(file: optimistic)
        }

        do {
            let queued = try await ctx.client.levelItemAudio(id: fileID, target: chosenTarget)
            lastError = nil
            startPolling(fileID: fileID)
            return queued
        } catch {
            if let previousFile { library.replace(file: previousFile) }
            lastError = Self.describe(error)
            throw error
        }
    }

    /// Removes the leveled alternate for `fileID` (`DELETE /library/items/:id/audio/level`) and updates the library file.
    @discardableResult
    public func removeLevel(id fileID: String) async throws -> AudioLevelRemoval {
        guard isAvailable else { throw PipelineFailure.unsupported }
        inFlightItems.insert(fileID)
        defer { inFlightItems.remove(fileID) }
        pollTasks[fileID]?.cancel()
        pollTasks[fileID] = nil

        let previousFile = library.file(id: fileID)
        if var optimistic = previousFile, var info = optimistic.audio {
            info.state = info.integratedLufs != nil ? .measured : .pending
            info.altID = nil
            info.altURL = nil
            info.outputLufs = nil
            info.outputTruePeak = nil
            info.targetLufs = nil
            info.leveledAt = nil
            info.error = nil
            optimistic.audio = info
            library.replace(file: optimistic)
        }

        do {
            let result = try await ctx.client.removeItemAudioLevel(id: fileID)
            lastError = nil
            Task { [weak self] in
                await self?.load(force: true)
            }
            return result
        } catch {
            if let previousFile { library.replace(file: previousFile) }
            lastError = Self.describe(error)
            throw error
        }
    }

    /// Triggers a background backfill sweep (`POST /audio/backfill`).
    @discardableResult
    public func backfill(limit: Int = 10) async throws -> AudioBackfillResult {
        guard isAvailable else { throw PipelineFailure.unsupported }
        backfilling = true
        defer { backfilling = false }
        do {
            let result = try await ctx.client.backfillAudioLoudness(limit: limit)
            lastBackfill = result
            lastError = nil
            await load(force: true)
            return result
        } catch {
            lastError = Self.describe(error)
            throw error
        }
    }

    /// Whether links for `audio` should default to `?audio=normal` based on current server settings.
    public func prefersLeveledLink(for audio: AudioLoudnessInfo?) -> Bool {
        settings.defaultLink == .normal && audio?.isLeveled == true
    }

    /// Resolves a share URL (`/<slug>`, `/p/<key>`, `/g/<id>`) with or without `?audio=normal`.
    public func shareURL(base: URL, audio: AudioLoudnessInfo?, useLeveled: Bool? = nil) -> URL {
        let leveled = useLeveled ?? prefersLeveledLink(for: audio)
        return AudioShareURL.resolve(base: base, audio: audio, useLeveled: leveled)
    }

    /// Polls library refresh briefly while a clip is rendering in the helper container.
    private func startPolling(fileID: String) {
        pollTasks[fileID]?.cancel()
        pollTasks[fileID] = Task { [weak self] in
            // Poll gently for up to ~90s while ffmpeg 2-pass loudnorm finishes
            for delay in [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0, 15.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.library.refresh()
                if let state = self.library.file(id: fileID)?.audio?.state, state != .rendering {
                    await self.load(force: true)
                    self.pollTasks[fileID] = nil
                    return
                }
            }
            self?.pollTasks[fileID] = nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let cobalt = error as? CobaltError {
            switch cobalt {
            case .api(let code, _): return code
            case .network: return "Network unavailable"
            case .invalidResponse(let status): return "Server error (\(status))"
            case .noAPIKey: return "Sign in required"
            case .tooLarge: return "File too large"
            case .cancelled: return "Cancelled"
            }
        }
        return error.localizedDescription
    }
}
