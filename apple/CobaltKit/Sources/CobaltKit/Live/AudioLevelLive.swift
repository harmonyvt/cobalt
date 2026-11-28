import Foundation

// Live Activity for audio loudness leveling (`features.audio_leveling`): shows one clean Dynamic Island / Lock Screen
// card while one or more clips are leveling on the server (using the shared `CobaltJobActivityAttributes` / `JobLiveState`
// widget with kind `"audio"`). Bulk selections stay grouped in one activity with a live `done/total` progress bar rather
// than flooding ActivityKit with N separate activities.

/// The part of ActivityKit `AudioLevelLiveManager` uses (`ActivityKitJobAdapter.audio()` on iOS; fakes in macOS tests).
@MainActor
protocol AudioLevelLiveAdapter: AnyObject {
    var isAvailable: Bool { get }
    var activities: [any JobActivityHandle] { get }
    func request(_ job: JobLiveJob, staleDate: Date, push: Bool) throws -> any JobActivityHandle
}

@MainActor
final class AudioLevelLiveManager {
    nonisolated static let activityID = "audio-level"
    nonisolated static let kind = "audio"
    nonisolated static let staleAfter: TimeInterval = JobLiveTimes.staleSeconds

    private let adapter: any AudioLevelLiveAdapter
    private let now: () -> Date
    private var handle: (any JobActivityHandle)?
    private var lastState: JobLiveState?
    private var batchStart: Date?
    private var batchItemIDs: Set<String> = []
    private var lastKnown: [String: QueueSnapshot.AudioLevelJob] = [:]

    init(adapter: any AudioLevelLiveAdapter, now: @escaping () -> Date) {
        self.adapter = adapter
        self.now = now
    }

    /// Reconciles the Live Activity with the latest merged set of audio leveling jobs (local optimistic + server `/queue`).
    func observe(_ jobs: [QueueSnapshot.AudioLevelJob]) async {
        for job in jobs {
            if let existing = lastKnown[job.itemID] {
                if job.isFresher(than: existing) {
                    lastKnown[job.itemID] = job
                }
            } else {
                lastKnown[job.itemID] = job
            }
        }

        let active = jobs.filter(\.isActive)
        if !active.isEmpty {
            if batchStart == nil {
                batchStart = active.map(\.updatedAt).min() ?? now()
            }
            for job in active {
                batchItemIDs.insert(job.itemID)
            }
            let state = buildActiveState(active: active)
            if let h = currentHandle() {
                if state != lastState {
                    lastState = state
                    await h.update(state, staleDate: now().addingTimeInterval(Self.staleAfter))
                }
            } else if adapter.isAvailable {
                let attrs = JobLiveAttributes(
                    id: Self.activityID,
                    kind: Self.kind,
                    title: "audio leveling",
                    agent: false,
                    open: JobLiveLinks.jobs
                )
                if let h = try? adapter.request(
                    JobLiveJob(attributes: attrs, state: state),
                    staleDate: now().addingTimeInterval(Self.staleAfter),
                    push: false
                ) {
                    handle = h
                    lastState = state
                }
            }
            return
        }

        // Nothing is actively rendering anymore: finish any open audio leveling Live Activity cleanly.
        guard let h = currentHandle() else {
            resetBatch()
            return
        }
        let final = buildFinalState()
        let dismissAfter = final.phase == .done && final.detail == nil
            ? JobLiveTimes.doneSeconds
            : JobLiveTimes.failedSeconds
        await h.end(final, dismissAt: now().addingTimeInterval(dismissAfter))
        resetBatch()
    }

    /// Ends any lingering activity (e.g. server changed or audio leveling disabled).
    func stopAll() async {
        for h in adapter.activities where !h.isEnded {
            await h.end(nil, dismissAt: nil)
        }
        if let h = handle, !h.isEnded {
            await h.end(nil, dismissAt: nil)
        }
        resetBatch()
    }

    private func currentHandle() -> (any JobActivityHandle)? {
        if let h = handle, !h.isEnded { return h }
        if let h = adapter.activities.first(where: { $0.attributes.id == Self.activityID && !$0.isEnded }) {
            handle = h
            return h
        }
        handle = nil
        return nil
    }

    private func resetBatch() {
        handle = nil
        lastState = nil
        batchStart = nil
        batchItemIDs.removeAll()
        lastKnown.removeAll()
    }

    private func buildActiveState(active: [QueueSnapshot.AudioLevelJob]) -> JobLiveState {
        let total = max(batchItemIDs.count, active.count)
        let settledDone = batchItemIDs.filter { lastKnown[$0]?.state == .ready }.count
        let settledFailed = batchItemIDs.filter { lastKnown[$0]?.state == .failed }.count
        let settled = min(total, settledDone + settledFailed)
        let since = floor((batchStart ?? now()).timeIntervalSince1970)

        let headline: String
        let detail: String?
        let fraction: Double?
        let compact: String

        if total <= 1, let single = active.first {
            headline = "leveling \(single.title)"
            detail = Self.targetLabel(single.targetLufs)
            fraction = nil
            compact = "…"
        } else {
            headline = "leveling audio · \(settled) of \(total)"
            if let current = active.first {
                detail = current.title
            } else {
                detail = Self.targetLabel(active.first?.targetLufs)
            }
            fraction = total > 0 ? Double(settled) / Double(total) : nil
            compact = "\(settled)/\(total)"
        }

        return JobLiveState(
            phase: .working,
            steps: ["measure", "level"],
            step: 1,
            headline: headline,
            detail: detail,
            fraction: fraction,
            compact: compact,
            since: since
        ).canonical()
    }

    private func buildFinalState() -> JobLiveState {
        let since = floor((batchStart ?? now()).timeIntervalSince1970)
        let items = batchItemIDs.compactMap { lastKnown[$0] }
        let ready = items.filter { $0.state == .ready }
        let failed = items.filter { $0.state == .failed }
        let doneCount = ready.isEmpty && failed.isEmpty ? max(1, batchItemIDs.count) : ready.count
        let failedCount = failed.count

        if doneCount > 0 && failedCount == 0 {
            let headline = doneCount == 1 ? "audio leveled" : "\(doneCount) clips leveled"
            let result: String?
            if doneCount == 1, let first = ready.first {
                result = Self.outputLabel(output: first.outputLufs, target: first.targetLufs)
            } else {
                result = Self.targetLabel(ready.first?.targetLufs)
            }
            return JobLiveState(
                phase: .done,
                steps: ["measure", "level"],
                step: 2,
                headline: headline,
                fraction: 1,
                compact: "✓",
                since: since,
                result: result
            ).canonical()
        }

        if doneCount > 0 && failedCount > 0 {
            return JobLiveState(
                phase: .done,
                steps: ["measure", "level"],
                step: 2,
                headline: "\(doneCount) leveled · \(failedCount) failed",
                detail: "open queue to retry",
                fraction: 1,
                compact: "\(doneCount)/\(doneCount + failedCount)",
                since: since,
                result: "\(doneCount) ready · \(failedCount) failed"
            ).canonical()
        }

        return JobLiveState(
            phase: .failed,
            steps: ["measure", "level"],
            step: 1,
            headline: failedCount <= 1 ? "audio leveling failed" : "\(failedCount) clips failed",
            detail: failed.first?.error ?? "try again from the queue",
            compact: "!",
            since: since
        ).canonical()
    }

    private static func targetLabel(_ lufs: Double?) -> String? {
        guard let lufs else { return nil }
        return "\(Int(lufs.rounded())) LUFS"
    }

    private static func outputLabel(output: Double?, target: Double?) -> String? {
        if let output {
            return String(format: "%.1f LUFS", output)
        }
        return targetLabel(target)
    }
}
