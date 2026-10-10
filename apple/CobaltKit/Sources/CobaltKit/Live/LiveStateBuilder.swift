import Foundation

/// What the builder needs besides the pipeline state itself (CONTRACT-LIVE.md 2.3).
struct LiveSnapshot: Sendable {
    /// The clip's name once known (the file's name while uploading).
    var title: String?
    var duration: Double?
    /// Unix seconds: when a stage change happens.
    var now: Double
    /// The content this builder produced last for the run (the merge base).
    var previous: LiveContentState?
    /// A gallery run whose save is over (`.gallery` says "saving" until then).
    var gallerySaved = false
}

extension LiveContentState {
    /// The pure function of 2.3: `(PipelineState, snapshot) → content`. Nil for `.idle` (the
    /// activity is ended `.immediate`). Both sides of the wire build the same content from the same
    /// facts: the fixture of 2.4 pins it.
    static func make(from state: PipelineState, _ snap: LiveSnapshot) -> LiveContentState? {
        let prev = snap.previous

        func finish(_ stage: Stage, rail: Int, since forced: Double? = nil,
                    _ fill: (inout LiveContentState) -> Void = { _ in }) -> LiveContentState {
            // A stage change resets the counters (they are simply not carried) and restarts the
            // clock, except `fetching`, which keeps the run's own start (`forced`).
            let since = forced ?? (prev?.stage == stage ? prev?.since : nil) ?? snap.now
            var s = LiveContentState(stage: stage, rail: rail, since: since)
            s.title = snap.title ?? prev?.title
            s.duration = snap.duration ?? prev?.duration
            fill(&s)
            return s
        }

        switch state {
        case .idle:
            return nil
        case .fetching(let since, let waking):
            return finish(.fetching, rail: 0, since: since.timeIntervalSince1970) { $0.waking = waking }
        case .uploading(let p):
            return finish(.uploading, rail: 0) { $0.bytes = p.bytes; $0.total = p.total }
        case .saving(let bytes, let total, _):
            return finish(.saving, rail: 1) { $0.bytes = bytes; $0.total = total }
        case .reading(let developed, let of):
            return finish(.reading, rail: 2) { $0.framesDone = developed; $0.framesTotal = of }
        case .picker:
            return finish(.ready, rail: 0) { $0.duration = nil }
        case .gallery:
            // no counts the widget could word as bytes: "saving" until the save is over, then "done"
            return snap.gallerySaved ? finish(.done, rail: 1) { $0.duration = nil } : finish(.saving, rail: 1) { $0.duration = nil }
        case .image:
            return finish(.ready, rail: 3) { $0.duration = nil }
        case .ready:
            return finish(.ready, rail: 2)
        case .rendering(let progress):
            switch progress {
            case .decoding(let done, let total):
                return finish(.rendering, rail: 3) { $0.framesDone = done; $0.framesTotal = total }
            case .packing:
                // img2webp has no count; "frames = total" like the server's `pack` phase.
                let total = prev?.stage == .rendering ? prev?.framesTotal : nil
                return finish(.rendering, rail: 3) {
                    $0.packing = true
                    if let total { $0.framesDone = total; $0.framesTotal = total }
                }
            case .working:
                return finish(.rendering, rail: 3)
            }
        case .done(let r):
            return finish(.done, rail: 3) {
                $0.resultURL = r.url.absoluteString
                $0.resultBytes = r.bytes
                $0.resultWidth = r.width
                $0.resultHeight = r.height
                $0.resultSeconds = r.seconds
            }
        case .savedLocally(let v):
            return finish(.done, rail: 2) { $0.resultBytes = v.bytes }
        case .failed(let f):
            return finish(.failed, rail: prev?.rail ?? 0) {
                $0.failure = f.liveName
                $0.code = f.liveCode
            }
        }
    }
}

extension PipelineFailure {
    /// The case name the content state carries (`LiveContentState.failure`).
    var liveName: String {
        switch self {
        case .noLink: return "noLink"
        case .tooLarge: return "tooLarge"
        case .fetchFailed: return "fetchFailed"
        case .linkUnreadable: return "linkUnreadable"
        case .unsupported: return "unsupported"
        case .serverBusy: return "serverBusy"
        case .renderBusy: return "renderBusy"
        case .renderLost: return "renderLost"
        case .expired: return "expired"
        case .keyMissing: return "keyMissing"
        case .keyInvalid: return "keyInvalid"
        case .unreachable: return "unreachable"
        case .server: return "server"
        }
    }

    /// The server's own error code, when the case pins one down (the failure carries it or it is
    /// the only code that maps to this case). Cases several codes map to carry none.
    var liveCode: String? {
        switch self {
        case .fetchFailed(let code), .linkUnreadable(let code): return code
        case .server(let code):
            return code.hasPrefix(PipelineFailure.renderPhasePrefix)
                ? String(code.dropFirst(PipelineFailure.renderPhasePrefix.count)) : code
        case .renderLost: return "error.webp.job_lost"
        case .renderBusy: return "error.webp.busy"
        case .serverBusy: return "error.studio.busy"
        case .expired: return "error.studio.expired"
        case .keyMissing: return "error.api.auth.key.missing"
        case .keyInvalid: return "error.api.auth.key.invalid"
        case .noLink, .tooLarge, .unsupported, .unreachable: return nil
        }
    }
}

extension PipelineState {
    /// A state that ends a Live Activity (done, saved locally, failed).
    var isLiveTerminal: Bool {
        switch self {
        case .done, .savedLocally, .failed: return true
        default: return false
        }
    }
}

// MARK: - The busy period's summary (CONTRACT-PARALLEL.md section 6)

extension LiveContentState {
    /// The summary while jobs are live: the lead's own content (its stage, rail, counters, title, clock) plus how many jobs
    /// the activity speaks for. `waiting` counts every waiting job, the lead included, so `waiting == jobs` reads as
    /// "all of it is in line".
    static func summary(lead: LiveContentState, jobs: Int, waiting: Int) -> LiveContentState {
        var s = lead
        s.jobs = jobs
        s.waiting = min(waiting, jobs)
        s.savedCount = nil
        s.webpCount = nil
        s.failedCount = nil
        return s
    }

    /// The summary of a period that has ended: "3 saved · 1 webp" (`done`), or, when nothing came out of it and
    /// something failed, "2 couldn't be saved" (`failed`: the shorter dismissal). Nil when there is nothing to say (every job
    /// was cancelled).
    static func finishedSummary(saved: Int, webps: Int, failed: Int, jobs: Int, now: Double) -> LiveContentState? {
        guard saved + webps + failed > 0 else { return nil }
        let nothingCameOut = saved + webps == 0
        var s = LiveContentState(stage: nothingCameOut ? .failed : .done, rail: nothingCameOut ? 0 : 3, since: now)
        s.jobs = jobs
        s.waiting = 0
        s.savedCount = saved
        s.webpCount = webps
        s.failedCount = failed
        return s
    }
}

extension Pipeline {
    /// Which job the summary follows: 0 = running on the server (it has a session and is not waiting), 1 = work of
    /// this device (checking the link, an upload, reading frames), 2 = waiting in a line. Lower is better; the newest
    /// job wins inside a rank. (Contract: "lead = the job running on the server, else the newest live"; a job that only
    /// waits is the lead last, so the card shows something that is happening.)
    var liveLeadRank: Int {
        if line != nil { return 2 }
        switch state {
        case .fetching, .saving, .rendering: return sessionID != nil ? 0 : 1
        default: return 1
        }
    }
}
