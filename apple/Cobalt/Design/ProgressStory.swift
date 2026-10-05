import CobaltKit
import Foundation

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

    /// The card for a running state; nil for states that have no card (idle, picker, ready, done...).
    var progressStory: ProgressStory? {
        let rail = self.rail
        func story(
            _ phase: ProgressStory.Phase, _ headline: String, detail: ProgressStory.Detail? = nil,
            fraction: Double? = nil, read: Int = 0, waking: Bool = false, footnote: String? = nil
        ) -> ProgressStory {
            ProgressStory(
                phase: phase, headline: headline, detail: detail, fraction: fraction.map { min(1, max(0, $0)) },
                framesRead: read, waking: waking, footnote: footnote, steps: rail.steps, index: rail.index)
        }
        func ratio(_ done: Int64, _ total: Int64?) -> Double? {
            total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }
        }
        switch state {
        case .fetching(let since, let waking):
            return story(
                .fetching, Copy.fetching(from: linkService),
                detail: .elapsed(prefix: waking ? Copy.waking : nil, since: since),
                waking: waking, footnote: waking ? Copy.wakingNote : nil)
        case .uploading(let progress):
            let detail = progress.total.map { ProgressStory.Detail.text(Copy.bytesOf(progress.bytes, $0)) }
                ?? .text(Format.bytes(progress.bytes))
            return story(.uploading, Copy.uploading, detail: detail, fraction: ratio(progress.bytes, progress.total))
        case .saving(let bytes, let total, let since):
            let headline = isPlainCobalt ? Copy.savingLocally : Copy.saving
            guard let bytes else { return story(.saving, headline, detail: .elapsed(prefix: nil, since: since)) }
            let detail = total.flatMap { $0 > 0 ? ProgressStory.Detail.text(Copy.bytesOf(bytes, $0)) : nil }
                ?? .text(Format.bytes(bytes))
            return story(.saving, headline, detail: detail, fraction: ratio(bytes, total))
        case .reading(let developed, let total):
            return story(
                .reading, Copy.reading, detail: .text(Copy.frameOf(developed, total)),
                fraction: total > 0 ? Double(developed) / Double(total) : nil, read: developed)
        case .rendering(.decoding(let done, let total)):
            return story(
                .rendering, Copy.makingWebp, detail: .text(Copy.frameOf(done, total)),
                fraction: total > 0 ? Double(done) / Double(total) : nil)
        case .rendering(.packing(let since)):
            return story(.rendering, Copy.packing, detail: .elapsed(prefix: nil, since: since))
        case .rendering(.working(let since)):
            return story(.rendering, Copy.makingWebp, detail: .elapsed(prefix: nil, since: since))
        default:
            return nil
        }
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
