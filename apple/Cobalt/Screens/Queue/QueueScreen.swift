import CobaltKit
import SwiftUI

// The queue tab (apple/CONTRACT.md section 12): everything cobalt is doing, in one calm list. A header that counts
// what runs and waits, then the sections in a fixed order: now, waiting, library indexing, downloads, photos, recently
// finished, failed. This device's jobs are the tray's own cards (`JobCard`), so a job reads the same here as over the
// home screen; everything else is a `QueueRow` in the same style. Every action goes through `AppModel.perform`, which
// routes it to the store that owns the work. The screen tells the model when it is on screen: `GET /queue` is only
// polled then.

struct QueueScreen: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// +1 per cancel, retry, dismiss or open the owner asks for (a light tap).
    @State private var actionTicks = 0
    @State private var confirmingCancel: QueueItem?

    private var unified: UnifiedQueue { model.unifiedQueue }

    var body: some View {
        let groups = unified.sections
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if groups.isEmpty {
                    empty
                } else {
                    header(unified.summary, indexing: groups.contains { $0.section == .indexing })
                    ForEach(groups) { group in
                        section(group)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? Motion.fade : Motion.rows, value: groups.flatMap { $0.items.map(\.id) })
        }
        .scrollIndicators(.automatic)
        .background(CobaltColor.bg)
        .refreshable { _ = await unified.refresh() }
        .confirmationDialog(
            Copy.Editor.cancelRenderTitle,
            isPresented: Binding(get: { confirmingCancel != nil }, set: { if !$0 { confirmingCancel = nil } }),
            titleVisibility: .visible
        ) {
            Button(Copy.Editor.cancelRender, role: .destructive) {
                if let item = confirmingCancel {
                    actionTicks += 1
                    Task { await model.perform(.cancel, on: item) }
                }
                confirmingCancel = nil
            }
            Button(Copy.Editor.keepRendering, role: .cancel) { confirmingCancel = nil }
        }
        .navigationTitle(Copy.Queue.title)
        .toolbar {
            if model.capabilities.queue {
                ToolbarItem(placement: .primaryAction) {
                    Button(Copy.Queue.refresh, systemImage: Symbol.retry) { Task { _ = await unified.refresh() } }
                        #if os(macOS)
                        .help(Copy.Queue.refresh)
                        #endif
                }
            }
        }
        .haptic(.impact(weight: .light), trigger: actionTicks)
        .haptic(.error, rising: unified.summary.failed)
        .onAppear { unified.setVisible(true) }
        .onDisappear { unified.setVisible(false) }
    }

    // MARK: header

    private func header(_ s: QueueSummary, indexing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.isQuiet && indexing ? Copy.Queue.onlyIndexing : Copy.Queue.header(running: s.running, waiting: s.waiting, failed: s.failed))
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: s)
                .accessibilityAddTraits([.isHeader, .updatesFrequently])
            if let line = statusLine {
                Text(line)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(unified.serverProblem ? CobaltColor.errorText : CobaltColor.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "can't reach the server · …" after a failed poll, else when the server last answered.
    private var statusLine: String? {
        guard model.capabilities.queue else { return nil }
        if unified.serverProblem { return Copy.Queue.serverProblem }
        return unified.updatedAt.map { Copy.Queue.updated(Format.when($0, now: Date())) }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(Copy.Queue.emptyTitle, systemImage: Symbol.queueEmpty)
                .font(CobaltType.body)
        } description: {
            Text(Copy.Queue.emptyBody)
                .font(CobaltType.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: sections

    private func section(_ group: QueueGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.name(group.section))
                Text("\(group.items.count)")
                    .monospacedDigit()
                    .foregroundStyle(CobaltColor.caption)
            }
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.text)
            .padding(.leading, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Queue.sectionA11y(Self.name(group.section), count: group.items.count))
            .accessibilityAddTraits(.isHeader)
            ForEach(group.items) { item in
                row(item)
                    .contextMenu { menu(item) }
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    @ViewBuilder
    private func row(_ item: QueueItem) -> some View {
        switch item.kind {
        case .job(let job):
            JobCard(
                job: job, lineMax: model.capabilities.limits.lineMax, lineMode: model.queue.lineMode,
                onOpen: { model.open(item) },
                onExit: { run(job.isPicker ? .dismiss : .cancel, item) },
                onRetry: { run(.retry, item) },
                onDismiss: { run(.dismiss, item) })
        default:
            QueueRow(facts: QueueRowFacts(item: item, now: Date()), actions: item.actions) { action in run(action, item) }
        }
    }

    @ViewBuilder
    private func menu(_ item: QueueItem) -> some View {
        ForEach(item.actions, id: \.self) { action in
            Button(label(action, item), systemImage: Self.symbol(action), role: action == .cancel ? .destructive : nil) {
                run(action, item)
            }
        }
    }

    private func run(_ action: QueueAction, _ item: QueueItem) {
        if action == .cancel, case .edit = item.kind {
            confirmingCancel = item
            return
        }
        if action != .open { actionTicks += 1 }
        Task { await model.perform(action, on: item) }
    }

    // MARK: words

    static func name(_ section: QueueSection) -> String {
        switch section {
        case .now: return Copy.Queue.now
        case .waiting: return Copy.Queue.waiting
        case .indexing: return Copy.Queue.indexing
        case .downloads: return Copy.Queue.downloads
        case .photos: return Copy.Queue.photos
        case .finished: return Copy.Queue.finished
        case .failed: return Copy.Queue.failed
        }
    }

    /// The context menu's words: a job the server is already doing is "stop" (it stops following, 3.4), never "cancel".
    private func label(_ action: QueueAction, _ item: QueueItem) -> String {
        switch action {
        case .cancel:
            if case .edit = item.kind { return Copy.Editor.cancelRender }
            if case .download = item.kind { return Copy.Queue.stop }
            if let job = item.job, JobCardFacts.exit(for: job.pipeline, lineMode: model.queue.lineMode) == .stop {
                return Copy.Queue.stopFollowing
            }
            return Copy.Queue.cancel
        case .retry: return Copy.Queue.tryAgain
        case .dismiss: return Copy.Queue.dismiss
        case .open:
            switch item.destination {
            case .library?: return Copy.Queue.openLibrary
            case .settings?: return Copy.Queue.openSettings
            case .edit?: return Copy.Editor.openEdit
            default: return Copy.Queue.open
            }
        }
    }

    static func symbol(_ action: QueueAction) -> String {
        switch action {
        case .cancel: return Symbol.close
        case .retry: return Symbol.retry
        case .dismiss: return Symbol.keep
        case .open: return Symbol.openApp
        }
    }
}

// MARK: - a row that is not one of this device's jobs

/// What a non-job row says, derived from the item; plain data so the words can be checked without a view.
struct QueueRowFacts: Equatable {
    var symbol: String
    var title: String
    var headline: String
    var detail: String?
    var footnote: String?
    /// Small lines under the row (the index's next posts).
    var extra: [String] = []
    /// 0...1 when the number is real; nil sweeps; only drawn while `showsBar`.
    var fraction: Double?
    var showsBar = false
    var isError = false
    /// The poster of an edit's render (small, beside the title); nil for every other row.
    var poster: URL?

    @MainActor
    init(item: QueueItem, now: Date) {
        symbol = Symbol.serverWork
        title = ""
        headline = ""
        switch item.kind {
        case .server(let w):
            symbol = Symbol.serverWork
            title = Copy.Queue.serverTitle(kind: w.kind, share: w.isShare, keyName: w.keyName, mine: w.mine)
            headline = w.running ? Copy.Queue.serverRunning : Copy.Queue.serverWaiting(w.position ?? 2)
            if let link = w.link, let info = LinkInfo(link) { detail = "\(info.service) · \(info.ref)" }
            footnote = Copy.Queue.serverNote
            showsBar = w.running
        case .download(let row):
            symbol = Symbol.keepOffline
            title = row.name
            switch row.state {
            case .downloading(let p):
                headline = Copy.Offline.downloading(bytes: p.bytes, total: p.total ?? row.expectedBytes)
                if let total = p.total ?? row.expectedBytes, total > 0 { fraction = Double(p.bytes) / Double(total) }
                showsBar = true
            case .failed(let f):
                symbol = Symbol.offlineFailed
                headline = Copy.Queue.downloadFailed(f)
                isError = true
            default:
                symbol = Symbol.offlineWaiting
                headline = Copy.Queue.downloadWaiting
            }
        case .photos(let p):
            symbol = Symbol.photosAlbum
            title = Copy.Queue.photosTitle
            headline = Copy.Queue.photosProgress(done: p.done, total: p.total)
            fraction = p.total > 0 ? Double(p.done) / Double(p.total) : nil
            showsBar = true
        case .indexing(let s):
            symbol = Symbol.indexing
            title = Copy.Queue.indexTitle
            headline = Copy.Queue.indexProgress(indexed: s.indexed, posts: s.posts)
            detail = Copy.Queue.indexDetail(pending: s.pending, ratePerHour: s.ratePerHour)
            var notes = [s.running == true ? Copy.Queue.indexRunning : Copy.Queue.indexWaiting]
            if let last = s.lastRunAt { notes.append(Copy.Queue.indexLastRun(Format.when(last, now: now))) }
            if s.failed > 0 { notes.append(Copy.Queue.indexFailed(s.failed)) }
            footnote = notes.joined(separator: " · ")
            extra = s.next.prefix(3).map { "\(Copy.Queue.indexNext) · \($0.title ?? $0.postKey)" }
            fraction = s.fraction
            showsBar = true
        case .posters(let n):
            symbol = Symbol.posters
            title = Copy.Queue.postersTitle
            headline = Copy.Queue.postersPending(n)
        case .finished(let w):
            symbol = Symbol.finished
            title = w.title
            let when = Format.when(w.finishedAt, now: now)
            switch w.outcome {
            case .saved:
                headline = Copy.Queue.finishedAt(Copy.Queue.saved, when: when)
            case .webp(let r):
                headline = Copy.Queue.finishedAt(Copy.Queue.webpReady, when: when)
                detail = [Format.size(r.width, r.height), Format.seconds(r.seconds), Format.bytes(r.bytes)].joined(separator: " · ")
            }
        case .edit(let render):
            symbol = Symbol.Editor.render
            title = Copy.Editor.queueTitle(render.title)
            poster = render.posterURL
            switch render.status {
            case .done:
                let size = [render.width, render.height].compactMap { $0 }
                headline = Copy.Editor.queueDone(
                    Copy.Editor.clock(render.duration ?? render.secondsTotal),
                    size.count == 2 ? Format.size(size[0], size[1]) : Format.bytes(render.bytes ?? 0))
            case .error:
                headline = Copy.Editor.renderFailed(Copy.Editor.renderReason(render.error))
                isError = true
            case .cancelled:
                headline = Copy.Editor.renderLine(render)
            default:
                headline = Copy.Editor.renderLine(render)
                showsBar = true
                fraction = render.status == .queued ? nil : render.progress
            }
        case .job:
            break
        }
    }

    /// "library search, 32 of 284 posts indexed, 252 to go · about 180 an hour, …".
    var spoken: String {
        ([title, headline] + [detail, footnote].compactMap { $0 } + extra).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct QueueRow: View {
    let facts: QueueRowFacts
    let actions: [QueueAction]
    let perform: (QueueAction) -> Void

    var body: some View {
        let f = facts
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: f.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(f.isError ? CobaltColor.errorText : CobaltColor.text)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(f.title)
                    .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let poster = f.poster {
                    EditorPoster(url: poster, maxPixel: 96)
                        .frame(width: 36, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .accessibilityHidden(true)
                }
                if actions.contains(.cancel) {
                    Button { perform(.cancel) } label: {
                        Image(systemName: Symbol.close)
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(CobaltColor.text.opacity(0.08), in: Circle())
                            .frame(width: 36, height: 28)
                            .contentShape(Rectangle().inset(by: Platform.isMac ? 0 : -8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityLabel("\(Copy.Queue.cancel) \(f.title)")
                    #if os(macOS)
                    .help(Copy.Queue.cancel)
                    #endif
                } else if actions.contains(.open) && !f.isError {
                    Button(Copy.Queue.open) { perform(.open) }
                        .buttonStyle(QueuePillStyle(compact: true))
                        .accessibilityLabel("\(Copy.Queue.open) \(f.title)")
                }
            }
            Text(f.headline)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(f.isError ? CobaltColor.errorText : CobaltColor.text)
                .lineLimit(f.isError ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
                .contentTransition(.opacity)
            if let detail = f.detail {
                caption(detail)
            }
            if f.showsBar {
                StoryBar(fraction: f.fraction, height: 3)
                    .padding(.vertical, 2)
            }
            if let note = f.footnote {
                caption(note)
            }
            ForEach(f.extra, id: \.self) { line in
                Text(line)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if actions.contains(.retry) || (actions.contains(.dismiss) && f.isError) {
                HStack(spacing: 6) {
                    if actions.contains(.retry) {
                        Button { perform(.retry) } label: { Label(Copy.Queue.tryAgain, systemImage: Symbol.retry) }
                            .buttonStyle(QueuePillStyle())
                            .accessibilityLabel("\(Copy.Queue.tryAgain), \(f.title)")
                    }
                    if actions.contains(.dismiss) {
                        Button(Copy.Queue.dismiss) { perform(.dismiss) }
                            .buttonStyle(QueuePillStyle())
                            .accessibilityLabel("\(Copy.Queue.dismiss) \(f.title)")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.bg.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { if actions.contains(.open) { perform(.open) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(f.spoken)
        .accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(Self.actionName(action)) { perform(action) }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.captionOnElevated)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func actionName(_ action: QueueAction) -> String {
        switch action {
        case .cancel: return Copy.Queue.cancel
        case .retry: return Copy.Queue.tryAgain
        case .dismiss: return Copy.Queue.dismiss
        case .open: return Copy.Queue.open
        }
    }
}

/// "open", "try again" and "dismiss" on a row: the tray's pill, in the queue's own file.
private struct QueuePillStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minHeight: compact ? 28 : 32)
            .background(CobaltColor.text.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - previews

#if DEBUG
private struct QueuePreview: View {
    @State private var model: AppModel

    init(_ state: QueuePreviewState) {
        let model = AppModel.previewQueue(state)
        model.selectedTab = .queue
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack { QueueScreen(model: model) }
            .cobaltRoot(model: model)
    }
}

#Preview("queue · busy") {
    QueuePreview(.busy)
}
#Preview("queue · busy, dark") {
    QueuePreview(.busy)
        .preferredColorScheme(.dark)
}
#Preview("queue · this device only") {
    QueuePreview(.localOnly)
}
#Preview("queue · empty") {
    QueuePreview(.quiet)
}
#Preview("queue · plain scenario") {
    PreviewHost(.happy, tab: .queue) { model in NavigationStack { QueueScreen(model: model) } }
}
#Preview("queue · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    QueuePreview(.busy)
}
#endif
