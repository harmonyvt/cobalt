import CobaltKit
import SwiftUI

// 05 · strata ("the library is a core sample"):
// Offline saves are grouped chronologically into geological strata whose height is proportional
// to their megabyte weight, with a cumulative MB ruler running down the leading edge. Active
// downloads, queued jobs, faults, and pulled core samples sit cleanly at the surface in full-width
// Liquid Glass cards (or the secondary pane in `DuoSplit`), while Paste and File live directly in
// the navigation bar.

// MARK: - Nav Bar Paste & File Controls

/// Paste and File controls designed for the Home navigation bar across iOS (iPhone, Duo Outer,
/// Duo Unfolded, iPad) and macOS. Every item uses `Label(title, systemImage:)` so it adapts
/// cleanly to iPhone Duo's Vertical Controls side rail.
struct HomeCaptureToolbarButtons: View {
    let showsFile: Bool
    @Environment(\.shell) private var shell

    var body: some View {
        Button { shell.paste() } label: {
            Label(Copy.paste, systemImage: Symbol.paste)
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(Copy.pasteA11y)
        .accessibilityIdentifier("capture.paste")
        .help(Copy.pasteA11y)

        if showsFile {
            FileSourceMenu {
                Label(Copy.file, systemImage: Symbol.file)
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(Copy.fileA11y)
            .accessibilityIdentifier("capture.file")
            .help(Copy.fileA11y)
        }
    }
}

// MARK: - Core Sample Column (Strata + Cumulative MB Ruler)

struct StrataColumnView: View {
    let model: AppModel
    let column: StrataColumn
    let selectedID: String?
    let freshID: String?
    let onSelect: (StoredMedia) -> Void
    let onOpenDetail: (StoredMedia) -> Void
    let onSeeAll: () -> Void

    private static let rulerWidth: CGFloat = 44

    var body: some View {
        if column.isEmpty {
            emptyCore
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(column.layers) { layer in
                    StrataLayerRow(
                        model: model,
                        layer: layer,
                        maxLayerBytes: column.maxLayerBytes,
                        rulerWidth: Self.rulerWidth,
                        selectedID: selectedID,
                        freshID: freshID,
                        onSelect: onSelect,
                        onOpenDetail: onOpenDetail)
                }
                rulerFooter
            }
        }
    }

    private var rulerFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(StrataLayout.megabyteTick(for: column.totalBytes))
                .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                .monospacedDigit()
                .foregroundStyle(CobaltColor.text)
                .frame(width: Self.rulerWidth, alignment: .leading)
                .lineLimit(1)

            Text(Copy.Strata.rulerFooter)
                .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onSeeAll) {
                Text(Copy.Strata.seeAll(column.mediaCount))
                    .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.text)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("capture.recent.all")
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var emptyCore: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.emptyOrbit)
                .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.text)
            Text(Copy.Strata.emptyHint)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CobaltColor.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

/// One geological stratum: leading cumulative MB tick + hairline, trailing depth-tinted band
/// whose height scales with its byte weight and contains horizontally scrollable poster thumbnails.
private struct StrataLayerRow: View {
    let model: AppModel
    let layer: StrataLayer
    let maxLayerBytes: Int64
    let rulerWidth: CGFloat
    let selectedID: String?
    let freshID: String?
    let onSelect: (StoredMedia) -> Void
    let onOpenDetail: (StoredMedia) -> Void

    private var rowHeight: CGFloat {
        CGFloat(StrataLayout.layerHeight(bytes: layer.bytes, maxLayerBytes: maxLayerBytes))
    }

    /// Subtle depth-graded tint matching 05 strata (`0.038 + depth * 0.022`, dynamic light/dark).
    private var bandFill: Color {
        let opacity = 0.038 + Double(min(layer.depth, 6)) * 0.022
        return CobaltColor.text.opacity(opacity)
    }

    private var thumbHeight: CGFloat {
        max(54, rowHeight - 40)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Leading cumulative MB ruler column
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(CobaltColor.text.opacity(0.8))
                    .frame(height: 1.5)
                Text(StrataLayout.megabyteTick(for: layer.cumulativeStartBytes))
                    .font(Font.cobalt(10.5, .medium, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                Spacer(minLength: 0)
            }
            .frame(width: rulerWidth, height: rowHeight, alignment: .topLeading)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(CobaltColor.border.opacity(0.32))
                    .frame(width: 1)
            }
            .accessibilityHidden(true)

            // Geological stratum band
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Copy.Strata.bucketTitle(layer.bucket))
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Copy.Strata.layerMeta(count: layer.media.count, bytes: layer.bytes))
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .monospacedDigit()
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(layer.media.enumerated()), id: \.element.id) { index, media in
                            StrataThumbnail(
                                media: media,
                                index: index + layer.depth * 3,
                                height: thumbHeight,
                                selected: selectedID == media.id,
                                fresh: freshID == media.id)
                                .onTapGesture { onSelect(media) }
                                .contextMenu {
                                    Button(Copy.Strata.openDetail, systemImage: Symbol.openApp) {
                                        onOpenDetail(media)
                                    }
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(
                                    PlanetSpeak.text(title: model.mediaItem(for: media).titleText, media: media))
                                .accessibilityIdentifier("capture.recent.\(media.id)")
                        }
                    }
                    .padding(.trailing, layer.media.count > 3 ? 18 : 0)
                }
                .scrollIndicators(.hidden)
                .frame(height: thumbHeight)
                .mask {
                    if layer.media.count > 3 {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.88),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing)
                    } else {
                        Rectangle()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .topLeading)
            .background(
                bandFill,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 12, topTrailingRadius: 12,
                    style: .continuous)
            )
        }
        .accessibilityElement(children: .contain)
    }
}

private func strataPosterURL(for media: StoredMedia) -> URL? {
    let face = media.face
    if PlanetStills.isStill(face) { return face.posterURL ?? face.fileURL }
    if let url = face.posterURL ?? media.original?.posterURL { return url }
    if let first = media.items.first {
        return first.posterURL ?? (PlanetStills.isStill(first) ? first.fileURL : nil)
    }
    return nil
}

/// One thumbnail tile inside a stratum: aspect 3:4, off-main decoded poster, file-type badge,
/// and PostHog `.mediaMask()`.
private struct StrataThumbnail: View {
    let media: StoredMedia
    let index: Int
    let height: CGFloat
    let selected: Bool
    let fresh: Bool

    private var width: CGFloat { max(44, (height * 0.75).rounded()) }

    private var picture: URL? { strataPosterURL(for: media) }

    private var badgeText: String {
        if media.isGallery { return "\(media.items.count)" }
        let type = PlanetType(media.face)
        return type.label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(FrameGradient.fill(FrameGradient.variant(forIndex: index)))
            if let picture {
                StillImage(url: picture)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(alignment: .bottomLeading) {
            Text(badgeText)
                .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                .dynamicTypeSize(...DynamicTypeSize.large)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(CobaltColor.badgeInk)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
        }
        .overlay {
            if selected {
                shape.strokeBorder(CobaltColor.text, lineWidth: 2)
            } else if fresh {
                shape.strokeBorder(CobaltColor.focus, lineWidth: 2)
            }
        }
        .contentShape(shape)
        // session replay (APP-API-CONTRACT 58): media is always masked
        .mediaMask()
    }
}

// MARK: - Surface Layer (Active Work, Waiting Queue, Faults, Pulled Sample)

struct StrataSurfaceView: View {
    let model: AppModel
    let pipeline: Pipeline
    let photoImport: PhotoImport?
    let showsProgress: Bool
    let showsFailure: Bool
    let showsImage: Bool
    let sampleMedia: StoredMedia?
    let sampleLayerTitle: String?
    let isDefaultNewest: Bool
    let onCloseSample: (() -> Void)?
    let onOpenDetail: (StoredMedia) -> Void

    @Environment(\.shell) private var shell

    private var waitingJobs: [Job] {
        model.queue.alongside
    }

    private var hasAnySurface: Bool {
        showsProgress || showsFailure || showsImage || !waitingJobs.isEmpty || sampleMedia != nil
    }

    var body: some View {
        if hasAnySurface {
            VStack(alignment: .leading, spacing: 10) {
                // Waiting / parallel background jobs
                if !waitingJobs.isEmpty {
                    waitingStack
                }

                // Active download or photo import
                if showsProgress {
                    progressSurface
                }

                // Failure fault card
                if showsFailure {
                    failureSurface
                }

                // Single-image capture card
                if showsImage, case .image(let info) = pipeline.state {
                    ImageCardContent(pipeline: pipeline, info: info) { pipeline.reset() }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Pulled core sample (or newest on unfolded/regular split)
                if let sampleMedia {
                    StrataSampleCard(
                        model: model,
                        media: sampleMedia,
                        layerTitle: sampleLayerTitle,
                        isDefaultNewest: isDefaultNewest,
                        onClose: onCloseSample,
                        onOpenDetail: { onOpenDetail(sampleMedia) })
                        .id(sampleMedia.id)
                }
            }
        }
    }

    // MARK: waiting queue

    private var waitingStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(waitingJobs.prefix(3)) { job in
                let facts = JobCardFacts(
                    job: job,
                    lineMax: model.capabilities.limits.lineMax,
                    lineMode: model.queue.lineMode)
                HStack(spacing: 8) {
                    Image(systemName: facts.kind == .failed ? Symbol.error : Symbol.queued)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(facts.kind == .failed ? CobaltColor.errorText : CobaltColor.caption)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(facts.title)
                            .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                        Text(facts.headline.isEmpty ? Copy.Strata.waiting : facts.headline)
                            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(facts.kind == .failed ? CobaltColor.errorText : CobaltColor.caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if facts.kind == .failed, facts.canRetry {
                        Button { model.queue.retry(job.id) } label: {
                            Label(TrayCopy.tryAgain, systemImage: Symbol.retry).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.cobaltIcon(.small))
                    } else if facts.kind == .saved || facts.kind == .webp || facts.kind == .picker {
                        Button { model.queue.focus(job.id) } label: {
                            Text(Copy.Strata.open)
                                .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                                .foregroundStyle(CobaltColor.text)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 32)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        if job.isLive {
                            Task { await model.queue.cancel(job.id) }
                        } else {
                            model.queue.dismiss(job.id)
                        }
                    } label: {
                        Label(Copy.cancel, systemImage: Symbol.close).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { model.queue.focus(job.id) }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            facts.kind == .failed ? CobaltColor.error.opacity(0.35) : CobaltColor.border.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: facts.kind == .failed ? [] : [5, 4]))
                )
            }
        }
    }

    // MARK: active progress surface

    @ViewBuilder
    private var progressSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .idle = pipeline.state, let photoImport, case .loading(let fraction) = photoImport.phase {
                HStack(alignment: .top, spacing: 10) {
                    ProgressCard(story: .photoImport(fraction: fraction))
                    Button { photoImport.cancel() } label: {
                        Label(Copy.cancel, systemImage: Symbol.close).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
            } else if let story = pipeline.progressStory {
                HStack(alignment: .top, spacing: 10) {
                    if let status = JobStatus(pipeline: pipeline, now: Date()) {
                        CaptureJobCard(story: story, status: status)
                    } else {
                        ProgressCard(story: story)
                    }
                    Button {
                        if let focused = model.queue.focusedID {
                            Task { await model.queue.cancel(focused) }
                        } else {
                            pipeline.cancel()
                        }
                    } label: {
                        Label(Copy.Strata.stop, systemImage: Symbol.stop).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: failure surface

    @ViewBuilder
    private var failureSurface: some View {
        if case .failed(let f) = pipeline.state {
            let message = TrayCopy.failure(f, lineMax: model.capabilities.limits.lineMax)
            let canRetry = f.isRetryable && model.queue.focusedID != nil
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Symbol.error)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(CobaltColor.errorText)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .font(Font.cobalt(13, .medium, relativeTo: .footnote))
                            .foregroundStyle(CobaltColor.errorText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pipeline.trayTitle)
                            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if canRetry, let focused = model.queue.focusedID {
                        Button { model.queue.retry(focused) } label: {
                            Label(TrayCopy.tryAgain, systemImage: Symbol.retry)
                                .font(Font.cobalt(12.5, .semibold, relativeTo: .footnote))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 38)
                                .background(CobaltColor.text, in: Capsule())
                                .foregroundStyle(CobaltColor.onText)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { pipeline.reset() } label: {
                        Label(TrayCopy.dismiss, systemImage: Symbol.close)
                            .font(Font.cobalt(12.5, .medium, relativeTo: .footnote))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                            .foregroundStyle(CobaltColor.text)
                            .overlay(Capsule().strokeBorder(CobaltColor.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(CobaltColor.error.opacity(0.36), lineWidth: 1)
            )
        } else if let photoImport, case .failed(let f) = photoImport.phase {
            InlineStatus(message: Copy.failure(f)) {
                Button { photoImport.dismissFailure() } label: {
                    Label(Copy.ok, systemImage: Symbol.checkmark)
                }
                .buttonStyle(.cobaltIcon(.small))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(CobaltColor.error.opacity(0.36), lineWidth: 1)
            )
        }
    }
}

// MARK: - Core Sample Peek Card

/// Pulled core sample card at the surface: displays the selected media's poster, metadata,
/// status badges (`public`, `webp`, `in photos`), and live quick actions (`public share` /
/// `copy share link`, `convert to webp`, `save to photos`, `open detail`).
struct StrataSampleCard: View {
    let model: AppModel
    let media: StoredMedia
    let layerTitle: String?
    let isDefaultNewest: Bool
    let onClose: (() -> Void)?
    let onOpenDetail: () -> Void

    @State private var controller: DetailController
    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics

    init(
        model: AppModel,
        media: StoredMedia,
        layerTitle: String?,
        isDefaultNewest: Bool,
        onClose: (() -> Void)?,
        onOpenDetail: @escaping () -> Void
    ) {
        self.model = model
        self.media = media
        self.layerTitle = layerTitle
        self.isDefaultNewest = isDefaultNewest
        self.onClose = onClose
        self.onOpenDetail = onOpenDetail
        _controller = State(initialValue: DetailController(model: model))
    }

    private var item: MediaItem { model.mediaItem(for: media) }
    private var rendition: Rendition { controller.selected(in: item) }

    private var picture: URL? { strataPosterURL(for: media) }

    private var liveLink: URL? {
        rendition.privateURL ?? rendition.hosted?.url ?? rendition.publicURL
    }

    private var isPlacedInPhotos: Bool {
        controller.photos[rendition.id] == .done || controller.placement(of: rendition, in: item) != .none
    }

    private var metaLine: String {
        var parts: [String] = []
        if let service = item.service { parts.append(service) }
        if let d = media.face.duration, !PlanetStills.isStill(media.face) { parts.append(Format.seconds(d)) }
        parts.append(Copy.storage(media.totalBytes))
        return parts.joined(separator: " · ")
    }

    private var headerTitle: String {
        if isDefaultNewest { return Copy.Strata.newest }
        if let layerTitle { return Copy.Strata.sampleFrom(layerTitle) }
        return Copy.Strata.newest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card header
            HStack(alignment: .center, spacing: 8) {
                Text(headerTitle)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isDefaultNewest {
                    Text(Copy.Strata.tapToOpen)
                        .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                } else if let onClose {
                    Button(action: onClose) {
                        Label(Copy.closeA11y, systemImage: Symbol.close).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
            }

            // Poster + metadata
            HStack(alignment: .top, spacing: 12) {
                Button(action: onOpenDetail) {
                    samplePoster
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Capture.openA11y(item.titleText))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.titleText)
                        .font(Font.cobalt(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metaLine)
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)

                    Text("\(Copy.Strata.savedPrefix) \(Copy.Strata.relativeSaved(media.latestAt))")
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)

                    if media.isHosted || liveLink != nil || !media.webps.isEmpty || isPlacedInPhotos {
                        statusBadges
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 2-column action grid (even column count, Duo-safe)
            actionGrid

            if let notice = controller.notice {
                Text(notice)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .haptic(.success, trigger: controller.copiedID, enabled: haptics) { $0 != nil }
        .haptic(.error, trigger: controller.notice, enabled: haptics) { $0 != nil }
    }

    private var samplePoster: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(FrameGradient.fill(1))
            if let picture {
                StillImage(url: picture)
            }
        }
        .frame(width: 60, height: 80)
        .clipShape(shape)
        .overlay(alignment: .bottomLeading) {
            Text(media.isGallery ? "\(media.items.count)" : PlanetType(media.face).label)
                .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.badgeInk)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
        }
        .mediaMask()
    }

    private var statusBadges: some View {
        HStack(spacing: 6) {
            if media.isHosted || liveLink != nil {
                badgePill(Copy.Strata.publicBadge, symbol: Symbol.linkBadge)
            }
            if !media.webps.isEmpty {
                badgePill(Copy.Strata.webpBadge, symbol: Symbol.webpBadge)
            }
            if isPlacedInPhotos {
                badgePill(Copy.Strata.inPhotosBadge, symbol: Symbol.savePhotos)
            }
        }
    }

    private func badgePill(_ text: String, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(Font.cobalt(10, .medium, relativeTo: .caption2))
        }
        .foregroundStyle(CobaltColor.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .overlay(Capsule().strokeBorder(CobaltColor.border.opacity(0.65), lineWidth: 0.75))
    }

    private var actionGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        return LazyVGrid(columns: columns, spacing: 8) {
            // 1. Copy share link or Public share
            if let url = liveLink {
                let copied = controller.copiedID == rendition.id
                sampleActionButton(
                    title: copied ? Copy.linkCopied : Copy.copyLink,
                    systemImage: copied ? Symbol.checkmark : Symbol.copyLink,
                    prominent: true
                ) {
                    controller.copy(url, for: rendition.id)
                }
            } else if controller.canSwitchVisibility(rendition) {
                let busy = model.isChangingVisibility(rendition)
                sampleActionButton(
                    title: Copy.publicShare,
                    systemImage: Symbol.publicShare,
                    prominent: false,
                    disabled: busy
                ) {
                    Task { await controller.setVisibility(rendition, public: true) }
                }
            } else if rendition.file != nil, model.capabilities.studio {
                sampleActionButton(
                    title: Copy.publicShare,
                    systemImage: Symbol.publicShare,
                    prominent: false,
                    disabled: controller.hosting == .working
                ) {
                    Task { await controller.publicShare(rendition) }
                }
            }

            // 2. Convert to webp
            if controller.canMakeWebp(item) {
                sampleActionButton(
                    title: media.webps.isEmpty ? Copy.convertToWebp : Copy.anotherWebp,
                    systemImage: Symbol.convert,
                    prominent: false
                ) {
                    shell.makeWebp(item)
                }
            }

            // 3. Save to photos
            if RenditionPhotos.canSave(rendition) {
                let saving = controller.photos[rendition.id] == .working
                sampleActionButton(
                    title: isPlacedInPhotos ? Copy.savedPhotos : Copy.savePhotos,
                    systemImage: isPlacedInPhotos ? Symbol.checkmark : Symbol.savePhotos,
                    prominent: false,
                    disabled: saving
                ) {
                    Task { await controller.savePhotos(rendition, in: item) }
                }
            }

            // 4. Open full detail
            sampleActionButton(
                title: Copy.Strata.openDetail,
                systemImage: Symbol.openApp,
                prominent: liveLink == nil
            ) {
                onOpenDetail()
            }
        }
    }

    private func sampleActionButton(
        title: String,
        systemImage: String,
        prominent: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Font.cobalt(12, prominent ? .semibold : .medium, relativeTo: .caption))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: Metrics.hit)
                .padding(.horizontal, 10)
                .foregroundStyle(prominent ? CobaltColor.onText : CobaltColor.text)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(CobaltColor.text)
                    }
                }
                .overlay {
                    if !prominent {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(CobaltColor.border.opacity(0.75), lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}
