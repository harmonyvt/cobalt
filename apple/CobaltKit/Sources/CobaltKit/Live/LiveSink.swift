import Foundation

/// What `Pipeline` tells whoever mirrors a run to the outside world (CONTRACT-LIVE.md 2.5): the
/// app's `LiveActivityManager`, or the share sheet's `ShareLiveRelay`. Nil on a context in previews
/// and tests unless a fake is injected.
@MainActor
protocol LiveSink: AnyObject {
    /// `Pipeline.begin(input:)`: the previous run is over.
    func runBegan(_ pipeline: Pipeline)
    /// After every `setState` that changed something (including `.idle`).
    func stateChanged(_ pipeline: Pipeline)
    /// `sessionID` was set.
    func sessionChanged(_ pipeline: Pipeline)
    /// `Pipeline.detach()`: the run `old` was showing carries on in the hidden pipeline `background`
    /// (same run id). The activity stays alive and follows `background` from now on.
    func runDetached(from old: Pipeline, to background: Pipeline)
    /// A detached run has nothing left in flight: its activity ends (done / failed ones keep their
    /// dismissal time, an unfinished one goes at once) and the server forgets the run.
    func detachedSettled(_ background: Pipeline)
}

extension LiveSink {
    func runDetached(from old: Pipeline, to background: Pipeline) {}
    func detachedSettled(_ background: Pipeline) {}
}

/// What the server's answers to `PUT /live/runs/<run>` say (APP-API-CONTRACT.md 8.2).
enum LiveReason {
    static let noStartToken = "no_start_token"
    static let notConfigured = "not_configured"
    static let startUnconfirmed = "start_unconfirmed"
    static let startRateLimited = "start_rate_limited"
    static let tooManyRuns = "error.live.too_many_runs"
}

extension Error {
    /// `429 error.live.too_many_runs`: the run gets no activity, and nothing retries it hot.
    var isTooManyLiveRuns: Bool {
        guard let e = self as? CobaltError, case .api(let code, let status) = e else { return false }
        return code == LiveReason.tooManyRuns || status == 429
    }
}

/// Runs async work one after another on the main actor (ActivityKit writes, registrations, relays
/// keep their order), without blocking the caller.
@MainActor
final class SerialQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    /// Everything queued so far has run (tests).
    func drain() async {
        var seen = tail
        while let current = seen {
            await current.value
            if tail == current { return }
            seen = tail
        }
    }
}

extension Pipeline {
    /// The attributes a Live Activity for this run starts with (CONTRACT-LIVE.md 2.2).
    func liveAttributes(origin: String) -> LiveRunAttributes {
        switch input {
        case .link(let info):
            return LiveRunAttributes(run: liveRunID, input: "link", service: info.service, ref: info.ref, origin: origin)
        case .file(let name, _, _):
            return LiveRunAttributes(run: liveRunID, input: "file", service: "file", ref: name, origin: origin)
        case nil:
            // library "trim a new webp", a handoff without a link: no service to name
            return LiveRunAttributes(
                run: liveRunID, input: "link", service: "cobalt", ref: media?.name ?? "video", origin: origin)
        }
    }

    /// The facts the builder needs.
    func liveSnapshot(previous: LiveContentState?, now: Date) -> LiveSnapshot {
        // The owner's title, else the clip's name without its media extension (decision 9).
        var title = runTitle ?? media.map { MediaTitle.stripExtension($0.name) }
        if title == nil, case .file(let name, _, _) = input { title = MediaTitle.stripExtension(name) }
        return LiveSnapshot(
            title: title, duration: media?.duration, now: now.timeIntervalSince1970, previous: previous)
    }
}
