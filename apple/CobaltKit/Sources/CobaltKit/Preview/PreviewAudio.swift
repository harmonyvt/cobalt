import Foundation
import Synchronization

/// In-memory audio loudness state for `PreviewClient`.
final class PreviewAudioState: Sendable {
    private struct State {
        var settings = AudioLevelSettings(
            mode: .auto,
            target: .lufs14,
            defaultLink: .orig,
            updatedAt: Date(),
            counts: AudioLoudnessCounts(
                totalVideos: 12,
                measured: 10,
                leveled: 4,
                needsLevel: 2,
                rendering: 0,
                failed: 0
            )
        )
        var items: [String: AudioLoudnessInfo] = [:]
    }

    private let state = Mutex(State())

    func settings() -> AudioLevelSettings {
        state.withLock { $0.settings }
    }

    func audio(for id: String) -> AudioLoudnessInfo? {
        state.withLock { $0.items[id] }
    }

    func update(_ patch: AudioLevelSettingsPatch, now: Date) -> AudioLevelSettings {
        state.withLock { s in
            if let mode = patch.mode { s.settings.mode = mode }
            if let target = patch.target { s.settings.target = target }
            if let link = patch.defaultLink { s.settings.defaultLink = link }
            s.settings.updatedAt = now
            return s.settings
        }
    }

    func level(id: String, target: AudioTargetLufs?, now: Date) -> AudioLevelQueued {
        state.withLock { s in
            let t = target ?? s.settings.target
            var info = s.items[id] ?? AudioLoudnessInfo(
                integratedLufs: -6.2,
                truePeakDbtp: -0.1,
                lraLu: 4.8,
                zone: .loud,
                state: .measured,
                measuredAt: now
            )
            info.state = .ready
            info.targetLufs = t.rawValue
            info.outputLufs = Double(t.rawValue)
            info.outputTruePeak = -1.5
            info.altID = "PrEvIeWalt\(id.suffix(6))"
            info.altURL = PreviewData.mediaBase.appendingPathComponent("PrEvIeWalt\(id.suffix(4)).mp4")
            info.leveledAt = now
            info.error = nil
            s.items[id] = info
            s.settings.counts.leveled += 1
            s.settings.counts.needsLevel = max(0, s.settings.counts.needsLevel - 1)
            return AudioLevelQueued(state: .rendering, target: t, queued: true)
        }
    }

    func remove(id: String) -> AudioLevelRemoval {
        state.withLock { s in
            guard var info = s.items[id], let altID = info.altID else {
                return AudioLevelRemoval(removed: false, altID: nil, bytes: 0)
            }
            info.state = .measured
            info.altID = nil
            info.altURL = nil
            info.outputLufs = nil
            info.outputTruePeak = nil
            info.targetLufs = nil
            info.leveledAt = nil
            s.items[id] = info
            s.settings.counts.leveled = max(0, s.settings.counts.leveled - 1)
            return AudioLevelRemoval(removed: true, altID: altID, bytes: 2_450_000)
        }
    }

    func backfill(limit: Int?) -> AudioBackfillResult {
        state.withLock { s in
            let cap = max(1, min(25, limit ?? 10))
            let unmeasured = s.settings.counts.unmeasured
            let qm = min(cap, unmeasured)
            let ql = s.settings.mode == .auto ? min(cap - qm, s.settings.counts.needsLevel) : 0
            s.settings.counts.measured += qm
            return AudioBackfillResult(
                queuedMeasure: qm,
                queuedLevel: ql,
                eligible: unmeasured + s.settings.counts.needsLevel,
                mode: s.settings.mode,
                target: s.settings.target
            )
        }
    }
}

extension PreviewClient {
    public func audioSettings() async throws -> AudioLevelSettings {
        if let refusal = accountRefusal() { throw refusal }
        return audioState.settings()
    }

    public func updateAudioSettings(_ patch: AudioLevelSettingsPatch) async throws -> AudioLevelSettings {
        if let refusal = accountRefusal() { throw refusal }
        return audioState.update(patch, now: clock.now())
    }

    public func levelItemAudio(id: String, target: AudioTargetLufs?) async throws -> AudioLevelQueued {
        if let refusal = accountRefusal() { throw refusal }
        return audioState.level(id: id, target: target, now: clock.now())
    }

    public func removeItemAudioLevel(id: String) async throws -> AudioLevelRemoval {
        if let refusal = accountRefusal() { throw refusal }
        return audioState.remove(id: id)
    }

    public func backfillAudioLoudness(limit: Int?) async throws -> AudioBackfillResult {
        if let refusal = accountRefusal() { throw refusal }
        return audioState.backfill(limit: limit)
    }
}
