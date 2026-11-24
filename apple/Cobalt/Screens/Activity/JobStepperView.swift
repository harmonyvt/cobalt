import CobaltKit
import SwiftUI

// The one stepper (apple 03-PHASE3 3.2, 3.4.2): the five steps of `JobStatus.steps` (queued, wake, source, library, device) as a
// short vertical list, so a save that is waking a container, switching downloaders or still copying to the device says exactly
// which step it is on and with which numbers. It draws what the status says and decides nothing: the steps, their states and
// their numbers come from CobaltKit (`JobStep`), the words from `Copy.Activity`.
//
// A step is a glyph, its name and, on the right, the real number it has (never a guess). The step the job is on has a bar when it
// has a fraction. Not tappable. VoiceOver reads the whole list as one element with a value, not five stops.

struct JobStepperView: View {
    let status: JobStatus
    /// The steps already done collapse to one line ("2 done") when false; the sheet shows them all.
    var showsDone = true
    /// Only the step the job is on, as one line: a row that has not started (waiting in a line) is not a five-step list until
    /// the owner opens it.
    var collapsed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let steps = status.steps
        let current = steps.first { $0.state == .active || $0.state == .warning || $0.state == .failed } ?? steps.first
        let shown = collapsed ? [current].compactMap { $0 } : steps
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { step in
                row(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: steps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Activity.stepsA11y)
        .accessibilityValue(shown.map(Copy.Activity.stepA11y).joined(separator: ". "))
    }

    private func row(_ step: JobStep) -> some View {
        let detail = Copy.Activity.stepDetail(step)
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        name(step)
                        if let detail { detailText(detail, step) }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        name(step)
                        Spacer(minLength: 8)
                        if let detail { detailText(detail, step) }
                    }
                }
            }
            if step.state == .active, let fraction = step.fraction {
                ProgressBar(fraction: fraction)
                    .padding(.leading, 24)
            }
        }
    }

    private func name(_ step: JobStep) -> some View {
        HStack(spacing: 8) {
            glyph(step.state)
                .frame(width: 16, height: 16)
            Text(Copy.Activity.stepName(step.id))
                .font(step.state == .active ? Font.cobalt(11.5, .semibold, relativeTo: .caption) : CobaltType.captionSmall)
                .foregroundStyle(step.state == .pending ? CobaltColor.caption : CobaltColor.text)
        }
    }

    private func detailText(_ text: String, _ step: JobStep) -> some View {
        Text(text)
            .font(CobaltType.captionSmall)
            .monospacedDigit()
            .foregroundStyle(detailInk(step.state))
            .multilineTextAlignment(.trailing)
            .lineLimit(3)
    }

    private func detailInk(_ state: JobStep.State) -> Color {
        switch state {
        case .failed: return ActivityInk.bad
        case .warning: return ActivityInk.warn
        default: return CobaltColor.caption
        }
    }

    @ViewBuilder
    private func glyph(_ state: JobStep.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(CobaltColor.text)
        case .active:
            Image(systemName: "circle.inset.filled")
                .foregroundStyle(CobaltColor.text)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ActivityInk.warn)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(CobaltColor.caption.opacity(0.7))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(ActivityInk.bad)
        }
    }
}

/// A 3 pt bar, the prototype's `pbar`: a track and a fill. Decorative (the percent is in the row's words).
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CobaltColor.railTrack)
                Capsule().fill(CobaltColor.text)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

#if DEBUG
private func previewStatus(_ stage: JobStatus.Stage, kind: JobStatus.Kind = .save, fraction: Double? = nil, woke: Bool = false, engine: SaveEngine? = .ytdlp, fallbackFrom: SaveEngine? = nil) -> JobStatus {
    JobStatus(
        id: "job:preview", ref: .pipeline(UUID()), kind: kind, title: "youtube · dQw4w9", sourceHost: "youtube.com", stage: stage,
        fraction: fraction, startedAt: Date(), updatedAt: Date(), engine: engine, fallbackFrom: fallbackFrom, woke: woke)
}

#Preview("stepper · states") {
    ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            JobStepperView(status: previewStatus(.waking(engine: .ytdlp)))
            JobStepperView(status: previewStatus(.downloading(bytes: 12_000_000, total: 40_000_000), fraction: 0.3, woke: true, fallbackFrom: .cobalt))
            JobStepperView(status: previewStatus(.deviceCopy(bytes: 3_000_000, total: 4_000_000), fraction: 0.75))
            JobStepperView(status: previewStatus(.completed(cloudSaved: true, deviceCopy: .failed(code: "error.app.disk_full"))))
            JobStepperView(status: previewStatus(.failed(failure: .unreachable, retryable: true)))
        }
        .padding(16)
    }
    .background(CobaltColor.bg)
}
#endif
