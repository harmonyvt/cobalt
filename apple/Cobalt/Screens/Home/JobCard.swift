import CobaltKit
import SwiftUI

// One job in the tray (CONTRACT-PARALLEL option A, sections 3.4, 5, 9): a mini progress card. It tells the same story
// the focused planet's card tells (CONTRACT-ORBIT 2c, `ProgressStory`), smaller: the title, what is happening in plain
// words, the real numbers, a 3 pt bar. A job that is waiting says so ("waiting for the server · 2nd in line"), a saved
// one says where it went and offers "open", a failed one offers "try again" and "dismiss".

// MARK: - the words of the tray (section 9)

/// What `Copy.Jobs` (L3's, Design/Copy+Jobs.swift) does not say: the card's own lines, the "+n more" button, what
/// VoiceOver hears. Everything the contract's copy table pins comes from `Copy.Jobs`.
enum TrayCopy {
    /// "2 running · 1 waiting" / "1 finished"; a tray holding only a multi-item post for the owner: "1 to pick".
    static func header(running: Int, waiting: Int, finished: Int, failed: Int, picking: Int) -> String {
        let text = Copy.Jobs.trayHeader(live: running + waiting, waiting: waiting, finished: finished, failed: failed)
        if !text.isEmpty { return text }
        return "\(picking) to pick"
    }

    static let showLess = "show less"
    static func more(_ n: Int) -> String { "+\(n) more" }
    static let moreA11y = "show all the jobs"

    // a card
    static let dismiss = "dismiss"
    static let tryAgain = "try again"
    static let saved = "saved"
    static let savedWhere = "in the orbit and your library"
    static let webpReady = "webp ready"
    static let pickDetail = "tap to choose"

    static func dismissA11y(_ title: String) -> String { "dismiss \(title)" }
    static func openA11y(_ title: String) -> String { "open \(title)" }
    static func retryA11y(_ title: String) -> String { "try again, \(title)" }
    static let cancelWebpA11y = "cancel the webp"

    /// What VoiceOver hears when a background job lands (polite, no toast: 5.2).
    static func savedAnnouncement(_ title: String) -> String { "\(title) saved." }
    static func webpAnnouncement(_ title: String) -> String { "\(title) webp ready." }
    static func failedAnnouncement(_ title: String) -> String { "\(title) couldn't finish." }

    /// What a cancel or a stop says (3.4).
    static func notice(_ notice: JobNotice) -> String {
        switch notice.kind {
        case .cancelled: return Copy.Jobs.cancelled(notice.title)
        case .cancelledWebp: return Copy.Jobs.cancelledWebp
        case .stoppedFollowing: return Copy.Jobs.stoppedFollowing(notice.title)
        case .stoppedReading: return Copy.Jobs.stoppedReading(notice.title)
        case .couldntCancel: return Copy.Jobs.couldntCancel
        }
    }

    // failures that have words only here (the line, section 17): everything else is `Copy.failure`
    static func failure(_ failure: PipelineFailure, lineMax: Int = 50) -> String {
        if failure == .lineFull { return Copy.Jobs.lineFull(max: lineMax) }
        if case .server(let code) = failure, code == "error.webp.no_video" {
            return "there's no video in that post for cobalt to save."
        }
        return Copy.failure(failure)
    }

    /// A failure that "try again" cannot cure: the input or the key is what is wrong.
    static func isRetryable(_ failure: PipelineFailure) -> Bool {
        switch failure {
        case .noLink, .tooLarge, .unsupported, .keyMissing, .keyInvalid: return false
        default: return true
        }
    }
}

// MARK: - what a pipeline is called

extension Pipeline {
    /// The title on a tray card: what the owner typed, else `service · ref`, else the file's name, else `cobalt`
    /// (CONTRACT-LIBRARY2 decisions 1 and 9, the same resolver as the focused planet's).
    var trayTitle: String {
        var service: String?
        var ref: String?
        var fileName: String?
        let local: StoredVideo? = stored ?? { if case .savedLocally(let v) = state { return v } else { return nil } }()
        if case .link(let info)? = input {
            service = info.service
            ref = info.ref
        } else {
            fileName = media?.name ?? local?.name
        }
        return MediaTitle.text(MediaTitle.resolve(
            custom: runTitle ?? local?.title, service: service, ref: ref, fileName: fileName))
    }
}

// MARK: - the card's facts

/// What one card says, derived from the job; plain data so the rules can be asserted without a view.
struct JobCardFacts: Equatable {
    enum Kind: Equatable { case running, waiting, picker, saved, webp, failed }

    /// What the x does, and so what it is called to VoiceOver (3.4).
    enum Exit: Equatable {
        /// Nothing was saved yet, or the server still holds it in the line: it is taken away.
        case cancel
        /// The server is doing it: the card stops following (the server finishes what it started).
        case stop
        /// A multi-item post that waits for the owner.
        case dismiss
    }

    var kind: Kind
    var title: String
    var headline: String
    var detail: ProgressStory.Detail?
    var footnote: String?
    var stepText: String
    /// 0...1 when the number is real; nil sweeps; only drawn while `showsBar`.
    var fraction: Double?
    var showsBar: Bool
    var exit: Exit?
    /// A failed card offers "open" (the focus shows the failure with the trim kept) rather than "try again".
    var failureOpens: Bool
    /// "try again" makes sense: the link or the file was fine, the run was not.
    var canRetry: Bool

    @MainActor
    init(job: Job, lineMax: Int, lineMode: LineMode) {
        let p = job.pipeline
        title = p.trayTitle
        headline = ""
        stepText = ""
        fraction = nil
        showsBar = false
        kind = .running
        failureOpens = false
        canRetry = false
        exit = nil
        switch p.state {
        case .fetching, .uploading, .saving, .reading, .rendering:
            if let story = p.progressStory {
                kind = story.waiting ? .waiting : .running
                headline = story.headline
                detail = story.detail
                footnote = story.footnote
                stepText = story.stepText
                fraction = story.fraction
                showsBar = true
            }
            exit = Self.exit(for: p, lineMode: lineMode)
        case .picker:
            kind = .picker
            headline = Copy.Jobs.pickerJob
            detail = .text(TrayCopy.pickDetail)
            stepText = Copy.stepsDone(0, max(1, p.rail.steps.count))
            exit = .dismiss
        case .ready:
            kind = .saved
            headline = TrayCopy.saved
            detail = .text(TrayCopy.savedWhere)
            stepText = Copy.stepsDone(min(p.rail.index, p.rail.steps.count), max(1, p.rail.steps.count))
        case .savedLocally, .image:
            kind = .saved
            headline = TrayCopy.saved
            detail = .text(TrayCopy.savedWhere)
            stepText = Copy.stepDone
        case .done(let result):
            kind = .webp
            headline = TrayCopy.webpReady
            detail = .text([
                Format.size(result.width, result.height), Format.seconds(result.seconds), Format.bytes(result.bytes),
            ].joined(separator: " · "))
            stepText = Copy.stepDone
        case .failed(let f):
            kind = .failed
            headline = TrayCopy.failure(f, lineMax: lineMax)
            stepText = ""
            failureOpens = f.keepsTrim && p.media != nil && p.sessionID != nil
            canRetry = TrayCopy.isRetryable(f)
        case .idle:
            break
        }
    }

    /// 3.4: where the job is decides what x does.
    @MainActor
    static func exit(for p: Pipeline, lineMode: LineMode) -> Exit {
        if case .reading = p.state { return .stop }
        guard p.sessionID != nil else { return .cancel }              // checking, uploading, waiting in the device line
        if lineMode == .server, case .inLine? = p.line { return .cancel }   // queued on the server: DELETE …/line
        return .stop                                                  // the server is doing it
    }
}

// MARK: - the card

struct JobCard: View {
    let job: Job
    let lineMax: Int
    let lineMode: LineMode
    let onOpen: () -> Void
    let onExit: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var facts: JobCardFacts { JobCardFacts(job: job, lineMax: lineMax, lineMode: lineMode) }

    var body: some View {
        let f = facts
        VStack(alignment: .leading, spacing: 4) {
            header(f)
            Text(f.headline)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(f.kind == .failed ? CobaltColor.errorText : CobaltColor.text)
                .lineLimit(f.kind == .failed ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if f.kind != .failed {
                detailRow(f)
            }
            if f.showsBar {
                StoryBar(fraction: f.fraction, height: 3)
                    .padding(.vertical, 2)
            }
            if let note = f.footnote {
                Text(note)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if f.kind == .failed { failedRow(f) }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        // a planet passing behind must not make the words hard to read: the glass sits on a quiet page-coloured wash
        .background(CobaltColor.bg.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { if f.kind != .failed || f.failureOpens { onOpen() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(f))
        .accessibilityAction(named: Text(Copy.Jobs.open)) { onOpen() }
    }

    private func header(_ f: JobCardFacts) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(f.title)
                .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            switch f.kind {
            case .saved, .webp:
                Button(Copy.Jobs.open, action: onOpen)
                    .buttonStyle(TrayLinkStyle())
                    .accessibilityLabel(TrayCopy.openA11y(f.title))
            default:
                if let exit = f.exit {
                    Button(action: onExit) {
                        Image(systemName: Symbol.close)
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(CobaltColor.text.opacity(0.08), in: Circle())
                            // a 44 pt target on a phone (HIG) without a 44 pt row
                            .frame(width: 36, height: 28)
                            .contentShape(Rectangle().inset(by: Platform.isMac ? 0 : -8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityLabel(Self.label(exit, title: f.title))
                    #if os(macOS)
                    .help(Self.label(exit, title: f.title))
                    #endif
                }
            }
        }
    }

    private func detailRow(_ f: JobCardFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TrayDetail(detail: f.detail)
            Spacer(minLength: 0)
            if !f.stepText.isEmpty {
                Text(f.stepText)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func failedRow(_ f: JobCardFacts) -> some View {
        HStack(spacing: 6) {
            if f.failureOpens {
                Button(Copy.Jobs.open, action: onOpen)
                    .buttonStyle(TrayPillStyle())
                    .accessibilityLabel(TrayCopy.openA11y(f.title))
            } else if f.canRetry {
                Button(action: onRetry) {
                    Label(TrayCopy.tryAgain, systemImage: Symbol.retry)
                }
                .buttonStyle(TrayPillStyle())
                .accessibilityLabel(TrayCopy.retryA11y(f.title))
            }
            Button(TrayCopy.dismiss, action: onDismiss)
                .buttonStyle(TrayPillStyle())
                .accessibilityLabel(TrayCopy.dismissA11y(f.title))
        }
        .padding(.top, 2)
    }

    static func label(_ exit: JobCardFacts.Exit, title: String) -> String {
        switch exit {
        case .cancel: return Copy.Jobs.cancelA11y(title)
        case .stop: return Copy.Jobs.stopA11y(title)
        case .dismiss: return TrayCopy.dismissA11y(title)
        }
    }

    /// "instagram · Dd7P496wolG, waiting for the server, 2nd in line, step 1 of 4".
    private func spoken(_ f: JobCardFacts) -> String {
        var parts = [f.title, f.headline]
        switch f.detail {
        case .text(let t): parts.append(t)
        case .elapsed(let prefix, _): if let prefix { parts.append(prefix) }
        case nil: break
        }
        if let note = f.footnote { parts.append(note) }
        if !f.stepText.isEmpty { parts.append(f.stepText) }
        return parts.joined(separator: ", ")
    }
}

/// The card's detail line: real numbers only. Unlike the progress card's it may wrap to two lines ("2nd in line · after
/// a share from your iphone"), the tray being narrow.
private struct TrayDetail: View {
    let detail: ProgressStory.Detail?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.captionOnElevated)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: text)
    }
}

// MARK: - small controls

/// A text link on a card: "open".
private struct TrayLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(CobaltColor.text.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Rectangle().inset(by: Platform.isMac ? 0 : -8))
    }
}

/// "try again" / "dismiss" under a failed card.
private struct TrayPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.cobalt(11, .medium, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(CobaltColor.text.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
    }
}
