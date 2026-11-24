import CobaltKit
import SwiftUI

// The capture tab's phone pieces (apple 04-PHASE4 4.1, "capture"): what the home screen draws on a compact width in place of the
// three bare glass circles, the old 7tv search circle gone (it lives in the live tab). The orbit stays behind all of it as the
// showcase; nothing here is a hit target the orbit has to share (HomeScreen counts the whole bottom block as chrome).
//
//   CaptureControls   paste, photos, files: glass capsules with their words on them, so nobody has to guess what a circle is.
//   RecentSavesStrip  the newest saves as a row of thumbnails; a tap pushes the unified detail (`MediaDetailRoute`).
//   CaptureJobCard    the save that is running, with the one stepper (`JobStepperView`) instead of the card's own dots.

// MARK: - the labelled intake controls

struct CaptureControls: View {
    let model: AppModel
    let glass: Namespace.ID
    @Environment(\.shell) private var shell

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }
            VStack(spacing: 10) { buttons }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var buttons: some View {
        CaptureButton(id: "paste", glass: glass, title: Copy.paste, systemImage: Symbol.paste, a11y: Copy.pasteA11y) { shell.paste() }
            .accessibilityIdentifier("capture.paste")
        if model.capabilities.showsFileButton {
            // the card an upload opens into morphs out of this one (HomeScreen's `glassID` is "file" for any file input)
            CaptureButton(id: "file", glass: glass, title: Copy.sourcePhotos, systemImage: Symbol.sourcePhotos, a11y: Copy.Capture.photosA11y) {
                shell.choosePhotos()
            }
            .accessibilityIdentifier("capture.photos")
            CaptureButton(id: "files", glass: glass, title: Copy.sourceFiles, systemImage: Symbol.sourceFiles, a11y: Copy.Capture.filesA11y) {
                shell.chooseFile()
            }
            .accessibilityIdentifier("capture.files")
        }
    }
}

private struct CaptureButton: View {
    let id: String
    let glass: Namespace.ID
    let title: String
    let systemImage: String
    let a11y: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(CaptureCapsuleStyle())
        .glassEffectID(id, in: glass)
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        .accessibilityLabel(a11y)
    }
}

/// The home circles' look (black glass, white ink) as a capsule that carries its word.
private struct CaptureCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.cobalt(15, .semibold, relativeTo: .body))
            .foregroundStyle(CobaltColor.circleInk)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .haptic(.impact(weight: .medium), trigger: configuration.isPressed) { $0 }
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.tint(CobaltColor.circle).interactive(), in: .capsule)
            .frame(minHeight: Metrics.hit)
            .contentShape(.capsule)
    }
}

// MARK: - recent saves

struct RecentSavesStrip: View {
    let model: AppModel
    let media: [StoredMedia]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Copy.Capture.recent)
                    .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { model.selectedTab = .library } label: {
                    Text(Copy.Capture.seeAll)
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.text)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture.recent.all")
            }
            .padding(.horizontal, 4)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(media) { item in
                        // the stack's `.mediaDetailDestination` shows it: the one `MediaDetail` the library's grid pushes too
                        NavigationLink(value: MediaDetailRoute(media: item)) { RecentThumb(media: item) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Copy.Capture.openA11y(PlanetSpeak.text(title: model.mediaItem(for: item).titleText, media: item)))
                            .accessibilityIdentifier("capture.recent.\(item.id)")
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            // a horizontal scroll view takes whatever height it is offered: the thumbnails' own
            .frame(height: RecentThumb.size.height)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// One thumbnail: the poster (or the photo itself) at its own corner radius, the length of a video in the corner.
private struct RecentThumb: View {
    let media: StoredMedia
    static let size = CGSize(width: 56, height: 72)

    private var picture: URL? {
        let face = media.face
        if PlanetStills.isStill(face) { return face.posterURL ?? face.fileURL }
        return face.posterURL ?? media.original?.posterURL
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
        ZStack {
            shape.fill(FrameGradient.fill(1))
            if let picture { StillImage(url: picture) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(alignment: .bottomLeading) {
            if let seconds = media.face.duration, !PlanetStills.isStill(media.face) {
                Text(Format.seconds(seconds))
                    .font(CobaltType.badge)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(CobaltColor.badgeInk)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(4)
            }
        }
        // session replay (APP-API-CONTRACT 58): media is always masked
        .mediaMask()
    }
}

// MARK: - the active job

/// The save that is running, on the capture tab's glass card: what it is doing in plain words, then the five steps with the
/// numbers they really have. `status` is the focused pipeline's own (`JobStatus(pipeline:)`), so this card, the tray's
/// cards, the pill and the sheet cannot disagree.
struct CaptureJobCard: View {
    let story: ProgressStory
    let status: JobStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(story.headline)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            JobStepperView(status: status)
            if let note = story.footnote {
                Text(note)
                    .font(Font.cobalt(11, .regular, relativeTo: .footnote))
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Capture.jobA11y)
        .accessibilityIdentifier("capture.job")
    }
}
