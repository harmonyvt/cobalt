import CobaltKit
import SwiftUI

// A save run in the screen pane (apple/CONTRACT-PANE.md section 5: home `.save(jobID)`). It is what the `.inspector` column
// of the home screen was, as a page: while the run works, what it is doing and a stop; once the video is saved, the trim's
// settings (quality, width, make webp) and what was made from it; once a webp is made, its link. `keepsRunning`: the page
// says in every shape, the bar included, whether the run is still at work, so closing the pane while it works leaves the
// bar and closing it after leaves nothing.

/// The words only this page has; the rest are the tray's and the focus screen's (`Copy.Jobs`, `TrayCopy`, `Copy`).
private enum SaveCopy {
    static let cancel = "cancel"
    static let stop = "stop"
    static let working = "working on it"
    static let noVideo = "nothing to trim"
}

struct PaneSavePage: View {
    let id: String
    let model: AppModel
    let pane: Pane

    /// The run was in the queue while this page was up: a run that vanishes after that is gone for good at once.
    @State private var seen = false

    private var job: Job? { UUID(uuidString: id).flatMap { model.queue.job($0) } }

    var body: some View {
        Group {
            if let job {
                PaneSaveContent(id: id, job: job, model: model, pane: pane)
            } else {
                PaneGonePage()
                    .task(id: id) { await letGo() }
            }
        }
        .onChange(of: job != nil, initial: true) { _, there in
            if there { seen = true }
        }
    }

    /// A save that is not in the queue (cancelled, dismissed, or a restored route for one that was never there) is never
    /// running: the pane lets go of it, so no bar says "gone". A route restored at launch gets `Pane.confirmWindow` first,
    /// because the queue's ledger puts a run back a moment after the scene starts.
    private func letGo() async {
        if !seen, UUID(uuidString: id) != nil { try? await Task.sleep(for: Pane.confirmWindow) }
        guard !Task.isCancelled, job == nil else { return }
        pane.itemGone(.save(id))
    }
}

struct PaneSaveContent: View {
    let id: String
    let job: Job
    let model: AppModel
    let pane: Pane

    @Environment(\.paneShape) private var shape

    private var pipeline: Pipeline { job.pipeline }
    private var settings: CobaltKit.Settings { model.settings }
    private var item: PaneItem { .save(id) }
    private var facts: JobCardFacts { JobCardFacts(job: job, lineMax: model.capabilities.limits.lineMax, lineMode: model.queue.lineMode) }

    private var canMake: Bool {
        switch pipeline.state {
        case .ready: return true
        case .failed(let f): return f.keepsTrim
        default: return false
        }
    }

    /// The media this run belongs to, as the detail shows it: the device's and the library's webps of the run's video
    /// together (CONTRACT-MEDIA 5).
    private var media: MediaItem? {
        if let mediaID = pipeline.mediaID, let local = model.store.media(id: mediaID) { return model.mediaItem(for: local) }
        guard let sid = pipeline.sessionID else { return nil }
        if let local = model.store.media(session: sid) { return model.mediaItem(for: local) }
        if let post = model.library.posts.first(where: { $0.session?.id == sid }) { return model.mediaItem(for: post) }
        return nil
    }

    /// Webps already made from this video: every tab of the media but the video.
    private var made: [Rendition] { media?.webps ?? [] }

    var body: some View {
        let facts = facts
        Group {
            if shape == .bar { bar(facts) } else { page(facts) }
        }
        // in every shape, the bar included: this is what makes closing the pane leave the bar while the run works
        .onChange(of: job.isLive, initial: true) { _, live in pane.setRunning(live, for: item) }
    }

    // MARK: the page

    private func page(_ facts: JobCardFacts) -> some View {
        PanePage(
            title: facts.title, subtitle: subtitle(facts)
        ) {
            poster
        } controls: {
            controls(facts)
        } body: {
            if !made.isEmpty || pipeline.result != nil {
                madeFromThisVideo
            }
        }
    }

    private func subtitle(_ facts: JobCardFacts) -> String {
        switch facts.kind {
        case .failed: return ""
        default: return facts.headline
        }
    }

    @ViewBuilder
    private var poster: some View {
        let content = ZStack {
            Rectangle().fill(FrameGradient.fill(1))
            if let frame = pipeline.posterFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)

        if shape == .tall {
            content
                .frame(height: Platform.isMac ? 220 : 240)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
        } else {
            content
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: controls

    @ViewBuilder
    private func controls(_ facts: JobCardFacts) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch facts.kind {
            case .running, .waiting:
                running(facts)
            case .failed:
                failed(facts)
            case .saved, .webp, .picker:
                if canMake { trim } else if case .done(let done) = pipeline.state { madeResult(done) }
            }
        }
    }

    /// The run is working: what it is doing, the real numbers, a bar, and the stop.
    private func running(_ facts: JobCardFacts) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if facts.showsBar {
                StoryBar(fraction: facts.fraction, height: 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TrayDetail(detail: facts.detail)
                Spacer(minLength: 0)
                if !facts.stepText.isEmpty {
                    Text(facts.stepText)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                }
            }
            if let footnote = facts.footnote {
                Text(footnote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let exit = facts.exit {
                PaneActionGrid([
                    PaneAction(exit == .stop ? SaveCopy.stop : SaveCopy.cancel, systemImage: Symbol.close, role: .destructive, id: "stop") {
                        Task { await model.queue.cancel(job.id) }
                    },
                ])
            }
        }
    }

    /// The video is saved (or a render keeps its trim): the selection, quality and width, and the one big button.
    private var trim: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(Copy.selection, systemImage: Symbol.selection)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                LengthReadout(seconds: pipeline.trim.length, over: pipeline.trimOverLimit, font: CobaltType.readoutLarge)
                Text(Copy.timecodeRange(pipeline.trim))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(Copy.quality, systemImage: Symbol.quality)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                QualityPicker(settings: settings)
            }
            LabeledContent {
                Text(Copy.widthName(settings.webpWidth)).font(Font.cobalt(13)).foregroundStyle(CobaltColor.text)
            } label: {
                Label(Copy.width, systemImage: Symbol.width)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            }
            PaneActionGrid([
                PaneAction(Copy.makeWebp, systemImage: Symbol.makeWebp, needsServer: true, disabled: !canMake, id: "make-webp") {
                    pipeline.makeWebp()
                },
            ])
        }
    }

    /// A webp that was just made: its numbers and its link.
    private func madeResult(_ result: WebpResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Format.size(result.width, result.height)) · \(Format.seconds(result.seconds)) · \(Format.bytes(result.bytes))")
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
            PaneActionGrid(copyActions(for: result.url))
        }
    }

    private func copyActions(for url: URL) -> [PaneAction] {
        let paired = pipeline.shareLink(for: url) != url
        var out = [PaneAction(
            paired ? Copy.LinkPair.copyShareLink : Copy.copyLink, systemImage: Symbol.copyLink, id: "copy-share"
        ) { Pasteboard.copy(pipeline.shareLink(for: url).absoluteString) }]
        if paired {
            out.append(PaneAction(Copy.LinkPair.copyDirectLink, systemImage: Symbol.LinkPair.direct, id: "copy-direct") {
                Pasteboard.copy(url.absoluteString)
            })
        }
        return out
    }

    private func failed(_ facts: JobCardFacts) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(facts.headline)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
            PaneActionGrid(failedActions(facts))
            if canMake { trim }
        }
    }

    private func failedActions(_ facts: JobCardFacts) -> [PaneAction] {
        var actions: [PaneAction] = []
        if facts.canRetry {
            actions.append(PaneAction(TrayCopy.tryAgain, systemImage: Symbol.retry, needsServer: true, id: "retry") {
                model.queue.retry(job.id)
            })
        }
        actions.append(PaneAction(TrayCopy.dismiss, systemImage: Symbol.close, id: "dismiss") {
            model.queue.dismiss(job.id)
            pane.close()
        })
        return actions
    }

    // MARK: what was made

    private var madeFromThisVideo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.madeFromThisVideo)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .padding(.horizontal, 16)
            VStack(spacing: 8) {
                if let result = pipeline.result, made.isEmpty {
                    madeRow(title: "\(Format.size(result.width, result.height)) · \(Format.seconds(result.seconds))",
                            detail: "\(Format.bytes(result.bytes)) · \(Copy.publicLink)", url: result.url, open: nil)
                }
                if let media {
                    ForEach(made) { webp in
                        madeRow(title: rowTitle(webp, of: media), detail: Copy.publicLink, url: webp.publicURL) {
                            pane.open(.post(media.post?.id ?? media.id))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func rowTitle(_ webp: Rendition, of media: MediaItem) -> String {
        [webp.tabName(of: media), DetailMeta.size(webp), webp.bytes.map { Format.bytes($0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// `webp 1 · 480×854 · 4.5 MB`: a tap opens the media's page; the copy buttons stay.
    private func madeRow(title: String, detail: String, url: URL?, open: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Button { open?() } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(FrameGradient.fill(1))
                        .frame(width: 44, height: 78)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(Font.cobalt(12.5, .regular, relativeTo: .footnote))
                            .foregroundStyle(CobaltColor.text)
                            .multilineTextAlignment(.leading)
                        Text(detail)
                            .font(CobaltType.caption)
                            .foregroundStyle(CobaltColor.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
            if let url {
                IconRow(spacing: 6) {
                    ForEach(LinkForm.allCases, id: \.self) { form in
                        if form == .share || pipeline.shareLink(for: url) != url {
                            Button {
                                Pasteboard.copy((form == .share ? pipeline.shareLink(for: url) : url).absoluteString)
                            } label: {
                                Label(form.menuTitle, systemImage: form.symbol)
                            }
                            .buttonStyle(.cobaltIcon(.small))
                        }
                    }
                }
                .fixedSize()
            }
        }
        .padding(10)
        .background(CobaltColor.surface, in: .rect(cornerRadius: 16))
    }

    // MARK: the bar

    /// The run as the bar over the tab: its picture, its title and what it is doing, a hairline of progress, one stop.
    private func bar(_ facts: JobCardFacts) -> some View {
        PanePage(
            title: facts.title, subtitle: facts.headline, progress: facts.showsBar ? facts.fraction : nil
        ) {
            poster
        } controls: {
            if job.isLive, facts.exit != nil {
                PaneIconButton(action: PaneAction(SaveCopy.stop, systemImage: Symbol.close) {
                    Task { await model.queue.cancel(job.id) }
                })
            }
        }
    }
}

// MARK: - previews

#if DEBUG
#Preview("save · ready to trim", traits: .fixedLayout(width: 440, height: 900)) {
    SavePreview()
}

private struct SavePreview: View {
    @State private var pane = Pane(route: PaneRoute(item: .save("preview"), state: .screen))

    var body: some View {
        PreviewHost(.happy, script: .input) { model in
            Group {
                if let job = model.queue.focused ?? model.queue.jobs.first {
                    PaneSaveContent(id: job.id.uuidString, job: job, model: model, pane: pane)
                } else {
                    PaneGonePage()
                }
            }
            .environment(\.paneShape, .tall)
            .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
            .environment(pane)
            .background(CobaltColor.bg)
        }
    }
}
#endif
