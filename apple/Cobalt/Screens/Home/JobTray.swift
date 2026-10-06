import CobaltKit
import SwiftUI

// The tray (CONTRACT-PARALLEL option A): a glass stack of mini progress cards for every job that is not the focused
// one. It sits where the paste came from: on the Mac and iPad at the top right under the paste button; on the iPhone
// above the two circles. While a planet is in focus the bottom belongs to it, so on the iPhone (and wherever the
// home column is too narrow to keep the tray beside the planet) the tray shrinks to a pill under the title; tap it
// to open the cards over the top of the screen.
//
// The tray decides nothing about the line or the focus: it shows `JobQueue.alongside` in the order the queue pinned,
// and its buttons call `focus`, `cancel`, `retry`, `dismiss` (3.4, 5.1).

struct JobTray: View {
    enum Style: Equatable {
        /// The iPhone with no planet in focus: above the circles, header chip at the bottom.
        case above
        /// The Mac and iPad: a panel at the top right, header chip on top (it can be folded).
        case panel
        /// A planet is in focus and the room is short: a pill, the cards under it when it is open.
        case pill(centered: Bool)
    }

    let model: AppModel
    let style: Style
    /// How many cards show before "+n more".
    var cap = 2
    /// A line the home screen wants said once ("<title> keeps going alongside.").
    @Binding var note: String?
    /// Counts up when something asked for the tray ("cobalt-apple://jobs"): it opens fully.
    var openRequest = 0
    /// The tray's frame in global space (zero when nothing is drawn), so a tap on the tray is never a tap on a planet.
    var onFrame: (CGRect) -> Void = { _ in }

    @State private var showsAll = false
    @State private var folded = false
    @State private var pillOpen = false
    /// Bumped each second while a finished card lingers, so the queue's 5 s window is re-read.
    @State private var tick = 0
    @State private var announced: Set<Job.ID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var queue: JobQueue { model.queue }

    private var rows: [Job] {
        _ = tick
        return queue.alongside
    }

    // MARK: body

    var body: some View {
        let all = rows
        let shown = (showsAll || all.count <= cap) ? all : Array(all.prefix(cap))
        let hidden = all.count - shown.count
        let message = noteText
        let counts = Counts(all)
        Group {
            if !all.isEmpty || message != nil {
                GlassEffectContainer(spacing: 8) {
                    switch style {
                    case .above: above(shown, hidden: hidden, all: all, counts: counts, message: message)
                    case .panel: panel(shown, hidden: hidden, all: all, counts: counts, message: message)
                    case .pill(let centered): pill(all, counts: counts, message: message, centered: centered)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Copy.Jobs.trayA11y)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: all.map(\.id))
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: showsAll)
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: folded)
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: pillOpen)
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: message)
        .onChange(of: all.isEmpty && message == nil) { _, gone in if gone { onFrame(.zero) } }
        .onChange(of: openRequest) { _, _ in
            folded = false
            showsAll = true
            pillOpen = true
        }
        .onChange(of: all.isEmpty) { _, empty in if empty { pillOpen = false } }
        // a finished card lingers 5 s (JobQueue.finishedLinger): re-read the queue each second while one does
        .task(id: counts.finished > 0) {
            guard counts.finished > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
            }
        }
        // what lands in the background is told to VoiceOver, politely; nothing else on screen says it (5.2)
        .onChange(of: all.filter { $0.isFinished || $0.isFailed }.map(\.id)) { _, ids in announce(ids, in: all) }
        .task { announced = Set(rows.filter { $0.isFinished || $0.isFailed }.map(\.id)) }
        .onChange(of: message) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .task(id: message) { await clearNote(after: message) }
    }

    // MARK: the three shapes

    private func above(_ shown: [Job], hidden: Int, all: [Job], counts: Counts, message: String?) -> some View {
        VStack(spacing: 6) {
            noteView(message)
            if !all.isEmpty {
                cards(shown)
                moreButton(hidden)
                header(counts, folds: false)
            }
        }
        .frame(maxWidth: 460)
    }

    private func panel(_ shown: [Job], hidden: Int, all: [Job], counts: Counts, message: String?) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            noteView(message)
            if !all.isEmpty {
                header(counts, folds: true)
                if !folded {
                    cards(shown)
                    moreButton(hidden)
                }
            }
        }
        .frame(width: 300)
    }

    private func pill(_ all: [Job], counts: Counts, message: String?, centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .trailing, spacing: 8) {
            if !all.isEmpty {
                Button { pillOpen.toggle() } label: {
                    HStack(spacing: 7) {
                        Circle().fill(CobaltColor.text).frame(width: 7, height: 7)
                        Text(counts.text)
                            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                            .lineLimit(1)
                        Image(systemName: pillOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(CobaltColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(counts.text)
                .accessibilityHint(pillOpen ? Copy.Jobs.trayHide : Copy.Jobs.trayShow)
                .accessibilityAddTraits(.isButton)
                if pillOpen {
                    ScrollView {
                        VStack(spacing: 6) { cards(all) }
                            .padding(.bottom, 4)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 440)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            noteView(message)
        }
        .frame(maxWidth: 360)
    }

    // MARK: pieces

    private func cards(_ jobs: [Job]) -> some View {
        ForEach(jobs) { job in
            JobCard(
                job: job, lineMax: model.capabilities.limits.lineMax, lineMode: queue.lineMode,
                onOpen: { open(job) },
                onExit: { Task { await queue.cancel(job.id) } },
                onRetry: { queue.retry(job.id) },
                onDismiss: { queue.dismiss(job.id) })
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity), removal: .opacity))
        }
    }

    @ViewBuilder
    private func moreButton(_ hidden: Int) -> some View {
        if hidden > 0 || showsAll && rows.count > cap {
            Button { showsAll.toggle() } label: {
                Text(showsAll ? TrayCopy.showLess : TrayCopy.more(hidden))
                    .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsAll ? TrayCopy.showLess : TrayCopy.moreA11y)
            .transition(.opacity)
        }
    }

    private func header(_ counts: Counts, folds: Bool) -> some View {
        HStack(spacing: 8) {
            Text(counts.text)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .accessibilityAddTraits(.updatesFrequently)
            if folds {
                Spacer(minLength: 0)
                Button { folded.toggle() } label: {
                    Image(systemName: folded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(CobaltColor.text)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle().inset(by: Platform.isMac ? 0 : -8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(folded ? Copy.Jobs.trayShow : Copy.Jobs.trayHide)
                .accessibilityAddTraits(.isButton)
                #if os(macOS)
                .help(folded ? Copy.Jobs.trayShow : Copy.Jobs.trayHide)
                #endif
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, folds ? 6 : 14)
        .frame(height: 36)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, alignment: folds ? .trailing : .center)
    }

    @ViewBuilder
    private func noteView(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity)
        }
    }

    // MARK: actions

    private func open(_ job: Job) {
        queue.focus(job.id)
        pillOpen = false
    }

    // MARK: the note

    /// What the tray says besides the cards: the last cancel or stop (3.4), a line from the home screen, or what a
    /// relaunch put back (3.5). One at a time, the newest first.
    private var noteText: String? {
        if let notice = queue.notice { return TrayCopy.notice(notice) }
        if let note { return note }
        if queue.restoredCount > 0 { return Copy.Jobs.relaunch(queue.restoredCount) }
        if let name = queue.restoredGoneFiles.first { return Copy.Jobs.fileGone(name) }
        return nil
    }

    /// A line stays long enough to read: the long one about a stop twice as long.
    private func clearNote(after message: String?) async {
        guard let message else { return }
        let seconds: Double = message.count > 70 ? 9 : 5
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, noteText == message else { return }
        if queue.notice != nil { queue.clearNotice() }
        else if note != nil { note = nil }
        else { queue.acknowledgeRestored() }
    }

    private func announce(_ ids: [Job.ID], in jobs: [Job]) {
        for job in jobs where ids.contains(job.id) && !announced.contains(job.id) {
            announced.insert(job.id)
            let title = job.pipeline.trayTitle
            let text: String
            switch job.pipeline.state {
            case .done: text = TrayCopy.webpAnnouncement(title)
            case .failed: text = TrayCopy.failedAnnouncement(title)
            default: text = TrayCopy.savedAnnouncement(title)
            }
            AccessibilityNotification.Announcement(text).post()
        }
    }

    // MARK: counts

    /// "2 running · 1 waiting" / "1 finished", from the cards the tray shows (the focused job is not one).
    struct Counts: Equatable {
        var running = 0
        var waiting = 0
        var finished = 0
        var failed = 0
        var picking = 0

        @MainActor
        init(_ jobs: [Job]) {
            for job in jobs {
                if job.isFailed { failed += 1 }
                else if job.isLive { if job.pipeline.line != nil { waiting += 1 } else { running += 1 } }
                else if job.isPicker { picking += 1 }
                else if job.isFinished { finished += 1 }
            }
        }

        var text: String {
            TrayCopy.header(running: running, waiting: waiting, finished: finished, failed: failed, picking: picking)
        }
    }
}

// MARK: - previews

#if DEBUG
/// A preview app whose server holds the line (`AppModel.previewLine`), with `links` pasted as a batch: the tray as it
/// looks over the home screen, light and dark.
@MainActor
func trayPreviewModel(_ mode: LinePreviewMode = .server, links: Int, focusFirst: Bool = false) -> AppModel {
    let model = AppModel.previewLine(mode)
    model.queue.trayIsShown = true
    let keys = ["Dd7P496wolG", "Dd8RkQ2xLpe", "De1Hj4tYm0Z", "De2Ab9cQwEr", "De3Zx7LkPoN", "De4Mn5BvCxS", "De5Qw8ErTyU"]
    let urls = keys.prefix(links).map { URL(string: "https://www.instagram.com/reel/\($0)/")! }
    if focusFirst, let first = urls.first {
        model.queue.add([.link(first)], via: .paste)
        model.queue.add(Array(urls.dropFirst()).map { .link($0) }, via: .review)
    } else {
        model.queue.add(urls.map { .link($0) }, via: .review)
    }
    return model
}

private struct TrayPreview: View {
    let style: JobTray.Style
    @State private var model: AppModel
    @State private var note: String?

    init(_ style: JobTray.Style, model: AppModel) {
        self.style = style
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack(alignment: style == .panel ? .topTrailing : .bottom) {
            CobaltColor.bg.ignoresSafeArea()
            JobTray(model: model, style: style, cap: style == .panel ? 5 : 2, note: $note)
                .padding(14)
        }
    }
}

#Preview("tray · phone · 3 jobs") {
    TrayPreview(.above, model: trayPreviewModel(links: 3))
        .frame(width: 390, height: 640)
}
#Preview("tray · phone · 6 jobs, dark") {
    TrayPreview(.above, model: trayPreviewModel(links: 6))
        .frame(width: 390, height: 640)
        .preferredColorScheme(.dark)
}
#Preview("tray · phone · behind a share") {
    TrayPreview(.above, model: trayPreviewModel(.serverBusyWithShare, links: 2))
        .frame(width: 390, height: 640)
}
#Preview("tray · phone · docked pill") {
    TrayPreview(.pill(centered: true), model: trayPreviewModel(links: 3))
        .frame(width: 390, height: 640)
}
#Preview("tray · mac · 5 jobs", traits: .fixedLayout(width: 640, height: 640)) {
    TrayPreview(.panel, model: trayPreviewModel(links: 5))
}
#Preview("tray · mac · dark, line full", traits: .fixedLayout(width: 640, height: 640)) {
    TrayPreview(.panel, model: trayPreviewModel(.serverFull, links: 2))
        .preferredColorScheme(.dark)
}
#Preview("tray · device line, busy elsewhere", traits: .fixedLayout(width: 640, height: 640)) {
    TrayPreview(.panel, model: trayPreviewModel(.deviceBusy(seconds: 40), links: 2))
}
#endif
