import CobaltKit
import Foundation
import SwiftUI

/// What the progress card says right now (CONTRACT-ORBIT 2c): one value built from the pipeline (the
/// app and the share sheet) or from the Live Activity's state (the widget), so every surface tells the
/// same story. Numbers are only ever the real ones: bytes over a total the server sent, frames the
/// phone or the server counted. With none, `fraction` is nil and the bar is indeterminate.
struct ProgressStory: Equatable {
    enum Phase: Equatable { case fetching, uploading, saving, reading, rendering, hosting, ready, finished, failed }

    enum Detail: Equatable {
        /// "2.1 of 4.3 MB", "frame 42 of 150".
        case text(String)
        /// Seconds since `since`, with an optional lead ("waking the server · 4 s").
        case elapsed(prefix: String?, since: Date)
    }

    var phase: Phase
    /// What is happening, in plain lowercase words.
    var headline: String
    var detail: Detail?
    /// 0...1 for the current step when the server or the phone reports bytes or frames; nil is indeterminate.
    var fraction: Double?
    /// Frames of the video read so far (the star grows rings from it).
    var framesRead = 0
    var waking = false
    var footnote: String?
    var steps: [Rail.Step]
    /// The current step (earlier ones are done); `steps.count` when everything is done.
    var index: Int
    /// The run waits for the owner (the trim) after the last finished step: nothing is current.
    var awaiting = false
    var failed = false
    /// The run is queued, not working (CONTRACT-PARALLEL 3.2, 9): the server's line or the device's has not got to
    /// it yet. The bar stays empty and the stepper does not pulse: waiting is not progress.
    var waiting = false

    var count: Int { steps.count }
    var finished: Bool { phase == .finished }

    /// The text beside the detail: "step 2 of 4", "3 of 4 done", "done".
    var stepText: String {
        if finished { return Copy.stepDone }
        if failed { return Copy.stepOf(min(index + 1, count), count) }
        if awaiting { return Copy.stepsDone(min(index, count), count) }
        return Copy.stepOf(min(index + 1, count), count)
    }

    /// The step the dots mark as current, nil while nothing is (waiting, finished).
    var current: Int? { finished || awaiting ? nil : min(index, count - 1) }

    /// Everything VoiceOver needs in one string: "step 2 of 4, saving to your library, 2.1 of 4.3 MB".
    var spoken: String {
        var parts = [stepText, headline]
        switch detail {
        case .text(let t): parts.append(t)
        case .elapsed(let prefix, _): if let prefix { parts.append(prefix) }
        case nil: break
        }
        if let footnote { parts.append(footnote) }
        return parts.joined(separator: ", ")
    }

    /// The glyph of the step the run is in (the compact island, the minimal ring).
    var currentStep: Rail.Step { steps[min(max(index, 0), count - 1)] }
}

// MARK: - from a status

extension ProgressStory {
    /// What the words need and a `JobStatus` does not say: the status is stages and numbers (and one `ahead` count for a wait),
    /// the card also says where the clock started, the place in line and who is ahead, the service of the link, which part
    /// of a save the server is on, the cause of a switch of downloaders, and the rail's glyphs (`steps` stay the rail's:
    /// "step 2 of 4" is its words, the status's five-step stepper is the activity sheet's).
    struct Context {
        /// The run's own rail (the card's dots and "step n of m").
        var rail: Rail
        /// "instagram": the service of a link (`Copy.fetching(from:)`).
        var service: String?
        /// When the step the run is in began (the card's own clock).
        var since: Date
        /// Why the run waits: the place, who is behind, or what the busy server is doing.
        var line: LinePosition?
        /// A line is words at a save that has not started and at a webp that has not begun; anywhere else it is ignored.
        var waitable: Bool
        var savePhase: SavePhase
        var isPlainCobalt: Bool
        /// The run is uploading a file (the status says `.downloading` for both an upload and a save from a site).
        var isUploading: Bool
        var fallbackCode: String?
        /// The stage a line hides: a status says "queued" for any run that has a line, the card only waits at `waitable`
        /// ones and shows the real stage everywhere else.
        var hidden: Core?
    }

    /// The running stages the card has words for.
    enum Core: Equatable {
        case fetching(waking: Bool, engine: SaveEngine?)
        case uploading(bytes: Int64, total: Int64?)
        case saving(bytes: Int64?, total: Int64?)
        case reading(done: Int, total: Int)
        case decoding(done: Int, total: Int)
        case packing
        case working
    }

    /// The core of a status stage; nil for a stage the card has no words for (finished, failed, a choice to make, a queue).
    static func core(of stage: JobStatus.Stage, isUploading: Bool) -> Core? {
        switch stage {
        case .waking(let engine): return .fetching(waking: true, engine: engine)
        case .fetching: return .fetching(waking: false, engine: nil)
        case .downloading(let bytes, let total), .storing(let bytes, let total):
            if isUploading { return .uploading(bytes: bytes ?? 0, total: total) }
            return .saving(bytes: bytes, total: total)
        case .readingFrames(let done, let total): return .reading(done: done, total: total)
        case .rendering(let phase, let done, let total):
            switch phase {
            case .decode?: return .decoding(done: done ?? 0, total: total ?? 0)
            case .pack?: return .packing
            default: return .working
            }
        case .queued, .galleryProgress, .deviceCopy, .completed, .failed, .awaitingChoice: return nil
        }
    }

    /// The card for a run that is working or waiting; nil for a status that has none (finished, failed, a choice to make, a
    /// gallery, a device copy). Stage, numbers, `fraction` and the waiting come from the status; the words stay here.
    init?(status: JobStatus, context c: Context) {
        guard status.kind != .gallery else { return nil }
        let rail = c.rail
        func story(
            _ phase: Phase, _ headline: String, detail: Detail? = nil, fraction: Double? = nil, read: Int = 0,
            waking: Bool = false, footnote: String? = nil
        ) -> ProgressStory {
            ProgressStory(
                phase: phase, headline: headline, detail: detail, fraction: fraction.map { min(1, max(0, $0)) },
                framesRead: read, waking: waking, footnote: footnote, steps: rail.steps, index: rail.index)
        }
        func ratio(_ done: Int64, _ total: Int64?) -> Double? {
            total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }
        }
        // the status's own fraction, except where a line hid the stage it would have measured
        var viaStatus = true
        let core: Core
        if status.stage.isWaiting {
            // Waiting is read first (CONTRACT-PARALLEL 3.2): a queued save is `.fetching` and a queued webp is
            // `.rendering(.working)`, and `line` says why.
            if c.waitable, let line = c.line {
                self = Self.waiting(line, isRender: status.kind == .webpRender, rail: rail)
                return
            }
            guard let hidden = c.hidden else { return nil }
            core = hidden
            viaStatus = false
        } else if let found = Self.core(of: status.stage, isUploading: c.isUploading) {
            core = found
        } else {
            return nil
        }
        switch core {
        case .fetching(let waking, let engine):
            // "waking yt-dlp" when the server says which downloader is starting; the device's own guess (before the
            // server has answered) only knows "the server"
            self = story(
                .fetching, Copy.fetching(from: c.service),
                detail: .elapsed(prefix: waking ? Copy.Save.waking(engine) : nil, since: c.since),
                waking: waking, footnote: Self.engineFootnote(status: status, fallbackCode: c.fallbackCode, waking: waking))
        case .uploading(let bytes, let total):
            let detail = total.map { Detail.text(Copy.bytesOf(bytes, $0)) } ?? .text(Format.bytes(bytes))
            self = story(.uploading, Copy.uploading, detail: detail, fraction: viaStatus ? status.fraction : ratio(bytes, total))
        case .saving(let bytes, let total):
            // The server's two parts of a save are two different things to say (apple 02-PHASE2 2.2.2): reading the post
            // from its site ("downloading from x.com · 18.1 of 37.6 MB") and writing it to the library ("storing in your
            // library · 72%"). Anything else (an upload, plain cobalt, a server without steps) keeps its one line.
            let headline: String
            switch c.savePhase {
            case .downloading: headline = Copy.fetching(from: c.service)
            case .storing: headline = Copy.Save.storing
            case .unknown: headline = c.isPlainCobalt ? Copy.savingLocally : Copy.saving
            }
            let note = Self.engineFootnote(status: status, fallbackCode: c.fallbackCode, waking: false)
            guard let bytes else { self = story(.saving, headline, detail: .elapsed(prefix: nil, since: c.since), footnote: note); return }
            let fraction = viaStatus ? status.fraction : ratio(bytes, total)
            let detail: Detail
            if c.savePhase == .storing, let fraction {
                detail = .text(Copy.Save.percent(fraction))
            } else {
                detail = total.flatMap { $0 > 0 ? Detail.text(Copy.bytesOf(bytes, $0)) : nil } ?? .text(Format.bytes(bytes))
            }
            self = story(.saving, headline, detail: detail, fraction: fraction, footnote: note)
        case .reading(let done, let total):
            self = story(
                .reading, Copy.reading, detail: .text(Copy.frameOf(done, total)),
                fraction: viaStatus ? status.fraction : (total > 0 ? Double(done) / Double(total) : nil), read: done)
        case .decoding(let done, let total):
            self = story(
                .rendering, Copy.makingWebp, detail: .text(Copy.frameOf(done, total)),
                fraction: viaStatus ? status.fraction : (total > 0 ? Double(done) / Double(total) : nil))
        case .packing:
            self = story(.rendering, Copy.packing, detail: .elapsed(prefix: nil, since: c.since))
        case .working:
            self = story(.rendering, Copy.makingWebp, detail: .elapsed(prefix: nil, since: c.since))
        }
    }

    /// The small line under a save: why it is slow to start ("it sleeps when idle.") and, once the save changed downloaders
    /// on its own, which one took over and why ("switched to yt-dlp · cobalt couldn't download it"). Nil when neither.
    static func engineFootnote(
        engine: SaveEngine?, fallbackFrom: SaveEngine?, fallbackCode: String?, waking: Bool
    ) -> String? {
        var parts: [String] = []
        if let from = fallbackFrom {
            parts.append(Copy.Save.switched(from: from, to: engine ?? (from == .cobalt ? .ytdlp : .cobalt), code: fallbackCode))
        }
        if waking { parts.append(Copy.wakingNote) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func engineFootnote(status: JobStatus, fallbackCode: String?, waking: Bool) -> String? {
        engineFootnote(engine: status.engine, fallbackFrom: status.fallbackFrom, fallbackCode: fallbackCode, waking: waking)
    }

    /// "waiting for the server · 2nd in line · your webp goes next".
    private static func waiting(_ line: LinePosition, isRender: Bool, rail: Rail) -> ProgressStory {
        let phase: Phase = isRender ? .rendering : .fetching
        var detail: Detail
        var footnote: String?
        switch line {
        case .inLine(let place, let behind):
            // a focused webp goes ahead of every save that has not started: right behind the one running
            detail = .text(Copy.Jobs.lineDetail(place: place, webpNext: isRender && place == 2))
            footnote = behind.flatMap { $0.isEmpty ? nil : Copy.Jobs.behind($0) }
        case .serverBusy(let since, let label):
            // the card's own clock adds " · 4 s" (`Copy.Jobs.busyElsewhere` is the same words with a fixed number)
            let what = label.flatMap { $0.isEmpty ? nil : $0 } ?? "a save that isn't in this list"
            detail = .elapsed(prefix: "it's busy with \(what)", since: since)
        }
        return ProgressStory(
            phase: phase, headline: Copy.Jobs.waiting, detail: detail, fraction: 0, footnote: footnote,
            steps: rail.steps, index: rail.index, waiting: true)
    }
}

// MARK: - from the pipeline

extension Pipeline {
    /// True on a plain cobalt server (the rail has no webp or host step).
    var isPlainCobalt: Bool {
        !rail.steps.contains(.webp) && !rail.steps.contains(.host)
    }

    var linkService: String? {
        if case .link(let info) = input { return info.service }
        return nil
    }

    /// What `ProgressStory(status:)` needs besides the status, read off this run.
    var progressContext: ProgressStory.Context {
        var since = Date()
        var waitable = false
        var uploading = false
        var hidden: ProgressStory.Core?
        switch state {
        case .fetching(let began, _):
            since = began
            waitable = true
        case .uploading(let progress):
            uploading = true
            hidden = .uploading(bytes: progress.bytes, total: progress.total)
        case .saving(let bytes, let total, let began):
            since = began
            hidden = .saving(bytes: bytes, total: total)
        case .rendering(.decoding(let done, let total)):
            hidden = .decoding(done: done, total: total)
        case .rendering(.packing(let began)):
            since = began
            hidden = .packing
        case .rendering(.working(let began)):
            since = began
            waitable = true
        default:
            break
        }
        return ProgressStory.Context(
            rail: rail, service: linkService, since: since, line: line, waitable: waitable, savePhase: saveStatus.phase,
            isPlainCobalt: isPlainCobalt, isUploading: uploading, fallbackCode: saveStatus.fallbackCode, hidden: hidden)
    }

    /// The card for a running state; nil for states that have no card (idle, picker, ready, done...). Built from the run's
    /// `JobStatus` (the one projection every surface reads) and the words around it.
    var progressStory: ProgressStory? {
        guard let status = JobStatus(pipeline: self, now: Date()) else { return nil }
        return ProgressStory(status: status, context: progressContext)
    }

    /// The small line under a save: why it is slow to start ("it sleeps when idle.") and, once the save changed downloaders
    /// on its own, which one took over and why ("switched to yt-dlp · cobalt couldn't download it"). Nil when neither.
    func engineFootnote(waking: Bool) -> String? {
        ProgressStory.engineFootnote(
            engine: saveStatus.engine, fallbackFrom: saveStatus.fallbackFrom, fallbackCode: saveStatus.fallbackCode, waking: waking)
    }

    /// Publishing the original (public share): indeterminate, the last step becomes "publish".
    func hostingStory(since: Date) -> ProgressStory {
        var steps = rail.steps
        if let last = steps.indices.last, steps.count == 4 { steps[last] = .host }
        return ProgressStory(
            phase: .hosting, headline: Copy.hostingOriginal, detail: .elapsed(prefix: nil, since: since),
            steps: steps, index: steps.count - 1)
    }
}

// MARK: - previews (the words table)

#if DEBUG
/// Every stage a card has words for, built the way the app builds one (`ProgressStory(status:context:)`) from a made-up
/// status: the table the words are read against. The real runs are compared with the old mapper by lane (e)'s evidence.
private struct StoryTable: View {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let rail = Rail(steps: [.fetch, .save, .read, .webp], index: 0, finished: false)

    private static func status(_ stage: JobStatus.Stage, kind: JobStatus.Kind = .save, fraction: Double? = nil) -> JobStatus {
        JobStatus(
            id: "t", ref: .pipeline(UUID()), kind: kind, stage: stage, fraction: fraction, startedAt: now, updatedAt: now,
            engine: .ytdlp, fallbackFrom: .cobalt)
    }

    private static func context(
        line: LinePosition? = nil, waitable: Bool = false, phase: SavePhase = .unknown, uploading: Bool = false
    ) -> ProgressStory.Context {
        ProgressStory.Context(
            rail: rail, service: "instagram", since: now, line: line, waitable: waitable, savePhase: phase, isPlainCobalt: false,
            isUploading: uploading, fallbackCode: "error.api.fetch.fail", hidden: nil)
    }

    private static var rows: [(String, ProgressStory?)] {
        [
            ("fetching", ProgressStory(status: status(.fetching(engine: nil, fallbackFrom: nil)), context: context())),
            ("waking", ProgressStory(status: status(.waking(engine: .ytdlp)), context: context())),
            ("uploading", ProgressStory(status: status(.downloading(bytes: 2_100_000, total: 4_300_000), fraction: 0.49), context: context(uploading: true))),
            ("downloading", ProgressStory(status: status(.downloading(bytes: 18_100_000, total: 37_600_000), fraction: 0.48), context: context(phase: .downloading))),
            ("storing", ProgressStory(status: status(.storing(bytes: 720, total: 1000), fraction: 0.72), context: context(phase: .storing))),
            ("saving, no steps", ProgressStory(status: status(.storing(bytes: 720, total: 1000), fraction: 0.72), context: context())),
            ("reading", ProgressStory(status: status(.readingFrames(done: 4, total: 9), fraction: 4.0 / 9), context: context())),
            ("making webp", ProgressStory(status: status(.rendering(phase: .decode, done: 42, total: 150), kind: .webpRender, fraction: 0.28), context: context())),
            ("packing", ProgressStory(status: status(.rendering(phase: .pack, done: nil, total: nil), kind: .webpRender), context: context())),
            ("in line", ProgressStory(status: status(.queued(ahead: 1)), context: context(line: .inLine(2, behind: "a share from your iphone"), waitable: true))),
            ("server busy", ProgressStory(status: status(.queued(ahead: nil)), context: context(line: .serverBusy(since: now, label: nil), waitable: true))),
            ("finished (no card)", ProgressStory(status: status(.completed(cloudSaved: true, deviceCopy: .savedOnDevice)), context: context())),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0).font(.caption2).foregroundStyle(.secondary)
                    Text(row.1?.spoken ?? "no card").font(.footnote)
                }
            }
        }
        .padding()
    }
}

#Preview("progress words, every stage") { StoryTable() }
#endif
