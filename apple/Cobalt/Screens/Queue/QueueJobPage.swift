import CobaltKit
import SwiftUI

// One of this device's jobs in the screen pane (apple/CONTRACT-PANE.md section 5): what the queue's job row opens. It tells
// the story the tray's card tells (`JobCardFacts`, the same words), bigger: the title, what is happening in plain words,
// the real numbers and the bar, and the buttons that card has (stop or cancel, try again, dismiss, open). `keepsRunning`
// while the job is live: closing leaves the bar (a glyph, the title, the line, one stop button).

struct QueueJobPage: View {
    let id: String
    let model: AppModel

    @Environment(Pane.self) private var pane
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHeaderHeight) private var headerHeight

    private var item: PaneItem { .job(id) }

    private var job: Job? {
        UUID(uuidString: id).flatMap { model.queue.job($0) }
    }

    var body: some View {
        Group {
            if let job {
                page(job)
            } else {
                PaneGonePage(message: Copy.Queue.jobGone)
            }
        }
        .onChange(of: job?.isLive, initial: true) { _, live in
            // a job that is not there (cancelled, dismissed, retired, or a restored route for one that never was) is never
            // running: the pane lets go of it instead of keeping a bar that says "gone"
            if let live { pane.setRunning(live, for: item) } else { pane.itemGone(item) }
        }
    }

    private func page(_ job: Job) -> some View {
        let facts = JobCardFacts(job: job, lineMax: model.capabilities.limits.lineMax, lineMode: model.queue.lineMode)
        return PanePage(
            title: facts.title, subtitle: facts.headline, progress: facts.showsBar ? facts.fraction : nil
        ) {
            hero(facts)
        } controls: {
            controls(job, facts)
        } body: {
            story(facts)
        }
    }

    // MARK: slots

    private func glyph(_ facts: JobCardFacts) -> String {
        switch facts.kind {
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .picker: "square.grid.2x2"
        case .saved: "checkmark.circle"
        case .webp: "photo.stack"
        case .failed: "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private func hero(_ facts: JobCardFacts) -> some View {
        ZStack {
            CobaltColor.surface
            Image(systemName: glyph(facts))
                .font(.system(size: shape == .bar ? 18 : 40, weight: shape == .bar ? .semibold : .light))
                .foregroundStyle(facts.kind == .failed ? CobaltColor.errorText : CobaltColor.text)
                .accessibilityHidden(true)
        }
        .frame(maxHeight: shape == .bar ? nil : 200)
        .padding(.top, shape == .tall ? headerHeight : 0)
        .background(CobaltColor.surface)
    }

    @ViewBuilder
    private func controls(_ job: Job, _ facts: JobCardFacts) -> some View {
        if shape == .bar {
            if let exit = facts.exit {
                Button { run(exit, job) } label: {
                    Image(systemName: Symbol.close).font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if os(iOS)
                .controlSize(.large)
                #endif
                .accessibilityLabel(JobCard.label(exit, title: facts.title))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if facts.showsBar { StoryBar(fraction: facts.fraction, height: 4) }
                let actions = actions(job, facts)
                if !actions.isEmpty { PaneActionGrid(actions) }
            }
        }
    }

    /// What the job's words say under the controls: the detail (real numbers only), the note, the step.
    @ViewBuilder
    private func story(_ facts: JobCardFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QueueDetailLine(detail: facts.detail)
            if let note = facts.footnote {
                Text(note).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            if !facts.stepText.isEmpty {
                Text(facts.stepText).font(CobaltType.caption).foregroundStyle(CobaltColor.caption).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // MARK: the buttons

    private func actions(_ job: Job, _ facts: JobCardFacts) -> [PaneAction] {
        var out: [PaneAction] = []
        if let exit = facts.exit {
            out.append(PaneAction(Self.exitName(exit), systemImage: Symbol.close, role: exit == .dismiss ? nil : .destructive) {
                run(exit, job)
            })
        }
        switch facts.kind {
        case .saved, .webp:
            out.append(PaneAction(Copy.Queue.open, systemImage: Symbol.openApp) { open(job) })
        case .failed:
            if facts.failureOpens {
                out.append(PaneAction(Copy.Queue.open, systemImage: Symbol.openApp) { open(job) })
            } else if facts.canRetry {
                out.append(PaneAction(Copy.Queue.tryAgain, systemImage: Symbol.retry, needsServer: true) {
                    model.queue.retry(job.id)
                })
            }
            out.append(PaneAction(Copy.Queue.dismiss, systemImage: Symbol.keep) {
                model.queue.dismiss(job.id)
                pane.close()
            })
        case .running, .waiting, .picker:
            break
        }
        return out
    }

    private static func exitName(_ exit: JobCardFacts.Exit) -> String {
        switch exit {
        case .cancel: Copy.Queue.cancel
        case .stop: Copy.Queue.stopFollowing
        case .dismiss: Copy.Queue.dismiss
        }
    }

    /// What the card's x does (3.4): take the job away, stop following it, or let a pick go.
    private func run(_ exit: JobCardFacts.Exit, _ job: Job) {
        let id = job.id
        Task {
            switch exit {
            case .cancel, .stop: await model.queue.cancel(id)
            case .dismiss:
                if job.isPicker { await model.queue.cancel(id) } else { model.queue.dismiss(id) }
            }
        }
    }

    /// "open": where the work lives, the save tab with the job in focus.
    private func open(_ job: Job) {
        guard model.queue.job(job.id) != nil else { return }
        model.queue.focus(job.id)
        model.selectedTab = .save
        pane.close()
    }
}

/// The job's detail line: real numbers only (an elapsed time counts up).
private struct QueueDetailLine: View {
    let detail: ProgressStory.Detail?

    var body: some View {
        switch detail {
        case .text(let text):
            line(text)
        case .elapsed(let prefix, let since):
            TimelineView(.periodic(from: since, by: 0.5)) { context in
                line(Copy.elapsedLine(prefix, seconds: Int(max(0, context.date.timeIntervalSince(since)))))
            }
        case nil:
            EmptyView()
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.body)
            .foregroundStyle(CobaltColor.text)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
private struct QueueJobHost: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    @State private var model = AppModel.previewQueue(.busy)

    var body: some View {
        AreaPageHost(item: .job(model.queue.jobs.first?.id.uuidString ?? ""), shape: shape, hinge: hinge) {
            QueueJobPage(id: model.queue.jobs.first?.id.uuidString ?? "", model: model)
        }
        .cobaltRoot(model: model)
    }
}

#Preview("queue job · tall", traits: .fixedLayout(width: 440, height: 800)) {
    QueueJobHost(shape: .tall)
}
#Preview("queue job · wide", traits: .fixedLayout(width: 1000, height: 560)) {
    QueueJobHost(shape: .wide)
}
#Preview("queue job · bar", traits: .fixedLayout(width: 402, height: 64)) {
    QueueJobHost(shape: .bar)
}
#Preview("queue job · gone", traits: .fixedLayout(width: 440, height: 600)) {
    AreaPageHost(item: .job("00000000-0000-0000-0000-000000000000"), shape: .tall) {
        QueueJobPage(id: "00000000-0000-0000-0000-000000000000", model: .previewQueue(.quiet))
    }
}
#endif
