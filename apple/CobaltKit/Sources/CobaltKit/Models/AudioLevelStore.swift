import Foundation
import Observation

/// Outcome of a bulk loudness leveling request (`AudioLevelStore.levelItems`).
public struct AudioBulkLevelResult: Sendable, Equatable {
    public var queued: [String]
    public var skipped: [String]
    public var failed: [String]

    public init(queued: [String] = [], skipped: [String] = [], failed: [String] = []) {
        self.queued = queued
        self.skipped = skipped
        self.failed = failed
    }
}

/// Server-wide audio loudness leveling settings, per-item and bulk actions, and backfill state (`features.audio_leveling`).
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
    /// Library file IDs queued by bulk leveling that are still rendering on the server.
    public private(set) var activeBulkIDs: Set<String> = []

    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var batchPollTask: Task<Void, Never>?
    @ObservationIgnored private var batchRefreshHooks: [@MainActor () async -> Void] = []
    @ObservationIgnored private var batchAudioLookups: [@MainActor (String) -> AudioLoudnessInfo?] = []

    init(context: PipelineContext, library: LibraryModel) {
        self.ctx = context
        self.library = library
    }

    public var isAvailable: Bool {
        ctx.capabilities.audioLeveling
    }

    public var isBulkLeveling: Bool {
        !activeBulkIDs.isEmpty
    }

    public func reset() {
        for task in pollTasks.values { task.cancel() }
        pollTasks.removeAll()
        batchPollTask?.cancel()
        batchPollTask = nil
        batchRefreshHooks.removeAll()
        batchAudioLookups.removeAll()
        settings = .init()
        loaded = false
        loading = false
        saving = false
        backfilling = false
        lastBackfill = nil
        lastError = nil
        inFlightItems.removeAll()
        activeBulkIDs.removeAll()
    }

    /// Resolves the live loudness metadata for `fileID`, merging library state, fallback (e.g. `ShareSetItem.audio`),
    /// and optimistic `.rendering` overlays while an item is submitting or bulk-leveling.
    public func optimisticAudio(for fileID: String, fallback: AudioLoudnessInfo? = nil) -> AudioLoudnessInfo? {
        let lib = library.file(id: fileID)?.audio
        let base: AudioLoudnessInfo? = (fallback?.isLeveled == true && lib?.isLeveled != true)
            ? fallback
            : (lib ?? fallback)
        if base?.isLeveled == true { return base }
        if inFlightItems.contains(fileID) || activeBulkIDs.contains(fileID) {
            var info = base ?? AudioLoudnessInfo()
            info.state = .rendering
            info.targetLufs = info.targetLufs ?? settings.target.rawValue
            info.error = nil
            return info
        }
        return base
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
    public func levelItem(
        id fileID: String,
        target: AudioTargetLufs? = nil,
        onRefresh: (@MainActor () async -> Void)? = nil,
        audioLookup: (@MainActor (String) -> AudioLoudnessInfo?)? = nil
    ) async throws -> AudioLevelQueued {
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
            activeBulkIDs.insert(fileID)
            startPolling(fileID: fileID, onRefresh: onRefresh, audioLookup: audioLookup)
            return queued
        } catch {
            if let previousFile { library.replace(file: previousFile) }
            activeBulkIDs.remove(fileID)
            lastError = Self.describe(error)
            throw error
        }
    }

    /// Bulk-queues 2-pass EBU R128 loudness leveling for every eligible un-leveled file in `ids`.
    /// Deduplicates `ids`, skips items already leveled, silent, rendering, or in-flight, applies optimistic
    /// `.rendering` states immediately, submits with bounded concurrency, and polls once for the whole batch.
    @discardableResult
    public func levelItems(
        ids: [String],
        target: AudioTargetLufs? = nil,
        onRefresh: (@MainActor () async -> Void)? = nil,
        audioLookup: (@MainActor (String) -> AudioLoudnessInfo?)? = nil
    ) async -> AudioBulkLevelResult {
        guard isAvailable else {
            lastError = Self.describe(PipelineFailure.unsupported)
            return AudioBulkLevelResult(failed: ids)
        }

        let chosenTarget = target ?? settings.target
        var seen = Set<String>()
        var targets: [String] = []
        var skipped: [String] = []

        for id in ids {
            guard seen.insert(id).inserted else { continue }
            let existing = library.file(id: id)?.audio ?? audioLookup?(id)
            if existing?.isLeveled == true
                || existing?.isSilent == true
                || existing?.isRendering == true
                || inFlightItems.contains(id)
                || activeBulkIDs.contains(id)
            {
                skipped.append(id)
            } else {
                targets.append(id)
            }
        }

        guard !targets.isEmpty else {
            return AudioBulkLevelResult(queued: [], skipped: skipped, failed: [])
        }

        // Optimistically mark all target files as rendering so the UI updates cleanly in one frame.
        var previousFiles: [String: LibraryFile] = [:]
        for id in targets {
            inFlightItems.insert(id)
            activeBulkIDs.insert(id)
            if var file = library.file(id: id) {
                previousFiles[id] = file
                var info = file.audio ?? AudioLoudnessInfo()
                info.state = .rendering
                info.targetLufs = chosenTarget.rawValue
                info.error = nil
                file.audio = info
                library.replace(file: file)
            }
        }

        let client = ctx.client
        var outcomes: [String: Result<AudioLevelQueued, Error>] = [:]
        let maxConcurrency = 4

        await withTaskGroup(of: (String, Result<AudioLevelQueued, Error>).self) { group in
            var nextIndex = 0
            let initial = min(maxConcurrency, targets.count)
            for _ in 0..<initial {
                let id = targets[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        let queued = try await client.levelItemAudio(id: id, target: chosenTarget)
                        return (id, .success(queued))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            while let (id, result) = await group.next() {
                outcomes[id] = result
                if nextIndex < targets.count {
                    let nextID = targets[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let queued = try await client.levelItemAudio(id: nextID, target: chosenTarget)
                            return (nextID, .success(queued))
                        } catch {
                            return (nextID, .failure(error))
                        }
                    }
                }
            }
        }

        var queued: [String] = []
        var failed: [String] = []
        var firstError: Error?

        for id in targets {
            inFlightItems.remove(id)
            switch outcomes[id] {
            case .success:
                queued.append(id)
            case .failure(let error):
                failed.append(id)
                activeBulkIDs.remove(id)
                if let prev = previousFiles[id] { library.replace(file: prev) }
                if firstError == nil { firstError = error }
            case nil:
                failed.append(id)
                activeBulkIDs.remove(id)
                if let prev = previousFiles[id] { library.replace(file: prev) }
            }
        }

        if let firstError {
            lastError = Self.describe(firstError)
        } else {
            lastError = nil
        }

        if !queued.isEmpty {
            startBatchPolling(onRefresh: onRefresh, audioLookup: audioLookup)
        }

        return AudioBulkLevelResult(queued: queued, skipped: skipped, failed: failed)
    }

    /// Removes the leveled alternate for `fileID` (`DELETE /library/items/:id/audio/level`) and updates the library file.
    @discardableResult
    public func removeLevel(id fileID: String) async throws -> AudioLevelRemoval {
        guard isAvailable else { throw PipelineFailure.unsupported }
        inFlightItems.insert(fileID)
        defer { inFlightItems.remove(fileID) }
        pollTasks[fileID]?.cancel()
        pollTasks[fileID] = nil
        activeBulkIDs.remove(fileID)

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

    /// Polls library refresh briefly while a single clip is rendering in the helper container.
    private func startPolling(
        fileID: String,
        onRefresh: (@MainActor () async -> Void)? = nil,
        audioLookup: (@MainActor (String) -> AudioLoudnessInfo?)? = nil
    ) {
        pollTasks[fileID]?.cancel()
        pollTasks[fileID] = Task { [weak self] in
            // Poll gently for up to ~90s while ffmpeg 2-pass loudnorm finishes
            for delay in [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0, 15.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.library.refresh()
                if let onRefresh { await onRefresh() }
                let resolved = self.library.file(id: fileID)?.audio ?? audioLookup?(fileID)
                if let state = resolved?.state, state != .rendering {
                    self.activeBulkIDs.remove(fileID)
                    await self.load(force: true)
                    self.pollTasks[fileID] = nil
                    return
                }
            }
            self?.activeBulkIDs.remove(fileID)
            self?.pollTasks[fileID] = nil
        }
    }

    /// Single consolidated poller for all active bulk-leveling IDs so multiple selections never multiply timers.
    private func startBatchPolling(
        onRefresh: (@MainActor () async -> Void)?,
        audioLookup: (@MainActor (String) -> AudioLoudnessInfo?)?
    ) {
        if let onRefresh {
            batchRefreshHooks.append(onRefresh)
        }
        if let audioLookup {
            batchAudioLookups.append(audioLookup)
        }
        batchPollTask?.cancel()
        batchPollTask = Task { [weak self] in
            for delay in [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0, 15.0, 20.0, 20.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.library.refresh()
                let hooks = self.batchRefreshHooks
                for hook in hooks { await hook() }

                let lookups = self.batchAudioLookups
                let settled = self.activeBulkIDs.filter { id in
                    if let libState = self.library.file(id: id)?.audio?.state, libState != .rendering {
                        return true
                    }
                    for lookup in lookups {
                        if let state = lookup(id)?.state, state != .rendering {
                            return true
                        }
                    }
                    return false
                }
                if !settled.isEmpty {
                    self.activeBulkIDs.subtract(settled)
                }
                if self.activeBulkIDs.isEmpty {
                    await self.load(force: true)
                    self.batchRefreshHooks.removeAll()
                    self.batchAudioLookups.removeAll()
                    self.batchPollTask = nil
                    return
                }
            }
            self?.activeBulkIDs.removeAll()
            self?.batchRefreshHooks.removeAll()
            self?.batchAudioLookups.removeAll()
            self?.batchPollTask = nil
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
