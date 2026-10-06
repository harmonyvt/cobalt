import CobaltKit
import SwiftUI
import UIKit

/// The compact share sheet for a gallery (apple/CONTRACT-GALLERY.md 1.12, board `Share-Gallery`).
///
/// ONE height for the sheet's whole life (the owner hated empty space and a sheet that resizes under his thumb). Every
/// state draws inside the same frame: a header, then a body whose height depends only on `flow.rows`, decided before the
/// sheet first showed. Checking draws row 1 live and bars where rows 2-3 will be; the answer fills the rows in place; a
/// refused request or an older server replaces the body's contents, not its size. The row heights are `ScaledMetric`s of
/// one text style, so they are the same in every state at any one Dynamic Type setting. Nothing here animates size.
struct ShareGallerySheet: View {
    let flow: ShareGalleryFlow
    /// The content's own height, so the controller can size the sheet to it (called on every layout change; it is a
    /// constant for one `rows` value and one Dynamic Type setting, so the fitter resizes at most once).
    var onFit: ((CGFloat) -> Void)?

    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var layoutsHeight: CGFloat = 116
    private let gap: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shareReducesMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }

    private var summary: ShareGalleryFlow.Summary? { flow.summary }

    /// The body's height: the three rows and their gaps, or the first row alone. The same in every phase.
    private var bodyHeight: CGFloat {
        flow.rows == .full ? rowHeight * 2 + layoutsHeight + gap * 2 : rowHeight
    }

    var body: some View {
        ScrollView {
            VStack(spacing: gap) {
                header.frame(height: headerHeight)
                content
                    .frame(maxWidth: .infinity, minHeight: bodyHeight, maxHeight: bodyHeight, alignment: .top)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFit?($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(CobaltColor.bg.ignoresSafeArea())
        // the compact sheet is a fixed-size layout: past this the labels would not fit their rows
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // No animation on a phase change: a cross-fade lays the old words over the new ones, and the sheet never moves.
        .transaction(value: flow.phase) { $0.animation = nil }
        .sensoryFeedback(.error, trigger: failed)
        .sensoryFeedback(.success, trigger: sent)
        .onChange(of: flow.phase) { _, phase in
            if phase == .choosing || phase == .oldServer { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.shareSheetA11y)
    }

    private var failed: Bool { if case .failed = flow.phase { return true } else { return false } }
    private var sent: Bool { if case .sent = flow.phase { return true } else { return false } }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            // the mark trails the words, so the words never shift sideways between states
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    headline
                    Text(subline)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                headerMark
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            CloseButton { flow.cancel() }
                .disabled(flow.isSending)
        }
    }

    @ViewBuilder
    private var headerMark: some View {
        switch flow.phase {
        case .resolving, .checking, .sending:
            ProgressView().controlSize(.small).frame(width: 18, height: 18)
        case .sent:
            Image(systemName: Symbol.checkmark)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        case .failed, .oldServer:
            Image(systemName: ShareSymbol.failed)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CobaltColor.errorText)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        case .choosing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch flow.phase {
        case .resolving, .checking:
            if flow.waking {
                // seconds count from the share; ticks once a second, never changes the line's height
                TimelineView(.periodic(from: flow.startedAt, by: 1)) { context in
                    headText(Copy.Gallery.wakingServer(max(0, Int(context.date.timeIntervalSince(flow.startedAt)))))
                }
            } else {
                headText(Copy.Gallery.checkingLink)
            }
        case .choosing:
            headText(flow.title)
        case .oldServer:
            headText(Copy.Gallery.serverNoGallery)
        case .sending(let request):
            headText(sendingHead(request))
        case .sent:
            headText(Copy.Gallery.sentToCobalt)
        case .failed(let failure):
            headText(ShareCopy.instantFailure(failure), color: CobaltColor.errorText)
        }
    }

    private func headText(_ text: String, color: Color = CobaltColor.text) -> some View {
        Text(text)
            .font(CobaltType.bodySemibold)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var subline: String {
        switch flow.phase {
        case .choosing:
            guard let summary else { return flow.title }
            return Copy.Gallery.count(photos: summary.photos, videos: summary.videos)
        default:
            return flow.title
        }
    }

    private func sendingHead(_ request: ShareGalleryFlow.Request) -> String {
        switch request {
        case .single: return ShareCopy.quickSaving
        case .saveNow, .timeout: return Copy.Gallery.savingEverything
        case .saveAll, .slideshowWebp, .galleryImage:
            guard let summary else { return Copy.Gallery.savingEverything }
            return Copy.Gallery.savingItems(summary.count, photosOnly: summary.photosOnly)
        }
    }

    // MARK: body

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .oldServer:
            messageCard(Copy.Gallery.serverNoGallerySub)
        case .failed:
            messageCard(nil)
        default:
            rows
        }
    }

    /// What the old-server card and a failure share: a line of words (or none) and, at the bottom, `open cobalt` and
    /// `close`. Fixed 44 pt buttons so the card is the rows' height whatever it says.
    private func messageCard(_ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text {
                Text(text)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(ShareCopy.quickOpenCobalt, systemImage: Symbol.openApp) { flow.openCobalt() }
                    .buttonStyle(.cobaltPrimary(compact: true))
                Button(ShareCopy.closeLabel) { flow.cancel() }
                    .buttonStyle(.cobaltSecondary(compact: true))
            }
            .frame(height: Metrics.hit)
        }
    }

    private var chosen: ShareGalleryFlow.Request? {
        switch flow.phase {
        case .sending(let request), .sent(let request): return request
        default: return nil
        }
    }

    /// The three rows (or the first). The sheet is `checking` until the picker is known (`summary == nil`): row 1 is
    /// `save now`, rows 2-3 are bars. After that the rows are real; a tap makes the others dim.
    @ViewBuilder
    private var rows: some View {
        let skeleton = summary == nil
        let live = flow.phase == .choosing
        VStack(spacing: gap) {
            saveRow(skeleton: skeleton, live: live)
            if flow.rows == .full {
                if skeleton {
                    SkeletonRow(height: rowHeight, animated: !reduceMotion)
                    SkeletonRow(height: layoutsHeight, animated: !reduceMotion)
                } else if let summary {
                    webpRow(summary, live: live)
                    imageRow(summary, live: live)
                }
            }
        }
    }

    private func saveRow(skeleton: Bool, live: Bool) -> some View {
        let enabled = skeleton ? flow.canSaveNow : live
        let label = skeleton ? Copy.Gallery.saveNow : Copy.Gallery.saveAll(summary?.count ?? 0)
        let sub = skeleton ? ShareCopy.saveNowSub : Copy.Gallery.intoCobaltAndFiles
        return ChoiceRow(
            symbol: Symbol.Gallery.folder, title: label, sub: sub, prominent: true, height: rowHeight,
            dimmed: !enabled && !isChosen(.saveAll) && !isChosen(.saveNow)
        ) { flow.choose(.saveAll) }
        .disabled(!enabled)
    }

    private func webpRow(_ summary: ShareGalleryFlow.Summary, live: Bool) -> some View {
        let sec = "\(Int(SlideshowPlan.defaultPhotoSeconds)) s"
        let sub: String
        if !flow.canMake {
            sub = Copy.Gallery.serverCantMake
        } else if summary.photosOnly {
            sub = Copy.Gallery.shareWebpSub(
                sec, "\(Int(summary.webpSeconds.rounded())) s", Copy.Gallery.size(summary.webpBytes))
        } else {
            sub = ShareCopy.webpSubWithVideos(sec)
        }
        let enabled = live && flow.canMake
        return ChoiceRow(
            symbol: Symbol.Gallery.slideshowWebp, title: Copy.Gallery.saveAndWebp, sub: sub, prominent: false,
            height: rowHeight, dimmed: !enabled && !isChosen(.slideshowWebp)
        ) { flow.choose(.slideshowWebp) }
        .disabled(!enabled)
    }

    private func imageRow(_ summary: ShareGalleryFlow.Summary, live: Bool) -> some View {
        let sub: String
        if !flow.canMake {
            sub = Copy.Gallery.serverCantMake
        } else if !summary.imagePossible {
            sub = Copy.Gallery.needsTwoPhotos
        } else if summary.videos > 0 {
            sub = Copy.Gallery.photosAndSkipped(summary.photos, summary.videos)
        } else {
            sub = Copy.Gallery.noBorders
        }
        let enabled = live && flow.canMake && summary.imagePossible
        return LayoutRow(
            title: Copy.Gallery.saveAndImage, sub: sub, height: layoutsHeight, enabled: enabled,
            chosen: { layout in isChosen(.galleryImage(layout)) }
        ) { layout in flow.choose(.galleryImage(layout)) }
    }

    private func isChosen(_ request: ShareGalleryFlow.Request) -> Bool { chosen == request }
}

// MARK: - Rows

/// One choice: a tile, a title, a line under it. `prominent` inverts it (the one primary row).
private struct ChoiceRow: View {
    let symbol: String
    let title: String
    let sub: String
    let prominent: Bool
    let height: CGFloat
    /// Greyed because another choice was made (a disabled row on its own is dimmed by the environment).
    let dimmed: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RowTile(symbol: symbol, prominent: prominent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(CobaltType.bodyMedium)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(sub)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(prominent ? CobaltColor.onText.opacity(0.8) : CobaltColor.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(prominent ? CobaltColor.onText : CobaltColor.text)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(prominent ? CobaltColor.text : CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : (dimmed ? 0.45 : 0.9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(sub)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RowTile: View {
    let symbol: String
    let prominent: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(prominent ? CobaltColor.onText : CobaltColor.text)
            .frame(width: 30, height: 30)
            .background((prominent ? CobaltColor.onText : CobaltColor.text).opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// `save + gallery image` with its four layouts inline. Tapping a layout IS the choice.
private struct LayoutRow: View {
    let title: String
    let sub: String
    let height: CGFloat
    let enabled: Bool
    let chosen: (GalleryLayout) -> Bool
    let choose: (GalleryLayout) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RowTile(symbol: Symbol.Gallery.galleryImage, prominent: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(sub)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 5) {
                ForEach(GalleryLayout.allCases, id: \.self) { layout in
                    LayoutButton(layout: layout, enabled: enabled, dimmed: !enabled && !chosen(layout)) { choose(layout) }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct LayoutButton: View {
    let layout: GalleryLayout
    let enabled: Bool
    let dimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LayoutGlyph(layout: layout)
                Text(Copy.Gallery.layout(layout))
                    .font(Font.cobalt(10, relativeTo: .caption2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : (dimmed ? 0.45 : 0.9))
        .accessibilityLabel(ShareCopy.layoutA11y(Copy.Gallery.layout(layout)))
    }
}

/// The layout drawn small: cells one point apart on a dark ground, as the board draws them.
private struct LayoutGlyph: View {
    let layout: GalleryLayout

    private var shape: (cols: Int, rows: Int, size: CGSize) {
        switch layout {
        case .strip: return (1, 3, CGSize(width: 10, height: 22))
        case .grid2: return (2, 3, CGSize(width: 16, height: 22))
        case .grid3: return (3, 3, CGSize(width: 22, height: 22))
        case .row: return (3, 1, CGSize(width: 24, height: 9))
        }
    }

    var body: some View {
        let s = shape
        VStack(spacing: 1) {
            ForEach(0..<s.rows, id: \.self) { _ in
                HStack(spacing: 1) {
                    ForEach(0..<s.cols, id: \.self) { _ in Rectangle().fill(CobaltColor.elevated) }
                }
            }
        }
        .padding(1)
        .background(CobaltColor.text)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .frame(width: s.size.width, height: s.size.height)
        .accessibilityHidden(true)
    }
}

/// Where a row will be, before the answer: two bars, no words. Breathes slowly; still under Reduce Motion.
private struct SkeletonRow: View {
    let height: CGFloat
    let animated: Bool
    @State private var bright = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(CobaltColor.elevated).frame(height: 9).frame(maxWidth: .infinity, alignment: .leading).scaleEffect(x: 0.46, anchor: .leading)
            Capsule().fill(CobaltColor.elevated).frame(height: 7).frame(maxWidth: .infinity, alignment: .leading).scaleEffect(x: 0.74, anchor: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .center)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(animated ? (bright ? 1 : 0.5) : 0.75)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bright = true }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Previews and the evidence harness: the sheet over a stand-in server, with the height it reports.
struct ShareGalleryPreviewHost: View {
    @State private var flow: ShareGalleryFlow
    let onFit: ((CGFloat) -> Void)?

    init(_ scenario: ShareGalleryPreview, holding: Bool = true, onFit: ((CGFloat) -> Void)? = nil) {
        _flow = State(initialValue: ShareGalleryFlow.preview(scenario, holding: holding))
        self.onFit = onFit
    }

    var body: some View {
        ShareGallerySheet(flow: flow, onFit: onFit)
    }
}

#Preview("gallery · instagram 10 (warm)") { ShareGalleryPreviewHost(.instagram) }
#Preview("gallery · cold server, checking") { ShareGalleryPreviewHost(.instagramCold) }
#Preview("gallery · x 4") { ShareGalleryPreviewHost(.x) }
#Preview("gallery · mixed") { ShareGalleryPreviewHost(.mixed) }
#Preview("gallery · photo + video") { ShareGalleryPreviewHost(.photoAndVideo) }
#Preview("gallery · older server") { ShareGalleryPreviewHost(.oldServer) }
#Preview("gallery · no makes (one row)") { ShareGalleryPreviewHost(.noMake) }
#Preview("gallery · no makes (late)") { ShareGalleryPreviewHost(.noMakeLate) }
#Preview("gallery · request refused") { ShareGalleryPreviewHost(.requestRefused, holding: false) }
#Preview("gallery · dark") { ShareGalleryPreviewHost(.instagram).preferredColorScheme(.dark) }
#endif
