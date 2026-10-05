import CobaltKit
import SwiftUI
import UIKit

// Small pieces the compact share sheet needs and the app's shared views do not have: copy for the
// new buttons (Cobalt/Design/Copy.swift belongs to the app lane), a poster, a shimmer that stands in
// for the filmstrip while frames load, and the system share sheet for the finished webp.

enum ShareCopy {
    static let copyWebpLink = "copy webp link"
    static let share = "share"
    static let continueInBackground = "continue in background"
    static let stay = "stay"
    /// The caption under the countdown row. `s` is whole seconds, rounded up.
    static func continuingIn(_ s: Int) -> String { "continuing in background in \(s) s" }
    /// Spoken once, when the countdown starts (never every second).
    static func continuingAnnouncement(_ s: Int) -> String {
        "continuing in background in \(s) seconds. choose stay to keep this open."
    }
    static let notifyWhenDone = "we'll notify you when it's done."
    static let openLater = "open cobalt later to see it."
    static func savingPhotos(_ step: PhotosStep) -> String {
        if case .downloading(let progress) = step, let total = progress.total, total > 0 {
            return "getting the video · \(Int(Double(progress.bytes) / Double(total) * 100))%"
        }
        return "saving to photos"
    }
    static let tapToTryAgain = "try saving again"
    static let photosDenied = "allow cobalt to add to photos in settings, then try again."
    static let photosFailed = "photos couldn't save this one."
    static let previewFailed = "couldn't load the preview \u{2014} the webp still works."
    static let webpReady = "your webp is ready."

    // The quick card (CONTRACT-SHARE-QUICK.md section 5).
    static let quickSaving = "saving to cobalt"
    /// Under "saving to cobalt" until the link is known.
    static let quickChecking = "reading the link"
    static let quickHeld = "cobalt has it"
    static let quickNotify = "we'll notify you when it's saved"
    static let quickOpenLater = "open cobalt to see it"
    static let quickFailed = "couldn't save"
    static let quickOpenCobalt = "open cobalt"
    static let quickExpandA11y = "show the full sheet"

    /// The instant share's one-line failure card (CONTRACT-SHARE-QUICK.md section 9). Lowercase, one line
    /// each: what happened, and the card's button says what to do (open cobalt).
    static func instantFailure(_ failure: InstantShare.Failure) -> String {
        switch failure {
        case .noKey: return "cobalt can't find your key from here"
        case .noLink: return "there's no link here that cobalt can save"
        case .couldNotStart: return "couldn't start the save"
        case .rejected(let status) where status == 401 || status == 403: return "the server didn't accept your key"
        case .rejected(let status) where status == 429: return "the server is busy, try again in a moment"
        case .rejected(let status) where status >= 500: return "the server isn't available right now"
        case .rejected: return "the server said no"
        case .unreachable: return "couldn't reach the server"
        }
    }

    /// Why a save to photos failed, in one line. A server-side miss reads like the rest of the app;
    /// anything else is most often the photos permission.
    static func photosFailure(_ failure: PipelineFailure) -> String {
        if failure.isPhotosDenied { return photosDenied }
        if failure == .server(code: PipelineFailure.photosFailedCode) { return photosFailed }
        return Copy.failure(failure)
    }
}

enum ShareSymbol {
    /// "continue in background": the sheet gets out of the way, the work carries on.
    static let background = "moon.zzz"
    static let share = "square.and.arrow.up"
    /// "stay": keep the sheet open, stop the countdown.
    static let stay = "hand.raised"
    /// The quick card's expand control: the full sheet.
    static let expand = "chevron.up"
    /// The quick card's failure mark.
    static let failed = "exclamationmark"
}

/// The ring around "continue in background"'s icon while the countdown runs: it drains from full to
/// empty between `endsAt - seconds` and `endsAt`. Drawn from the clock (`TimelineView`), never from
/// state, so it costs no model updates. Reduce Motion: the caller leaves it out and the caption's
/// whole-second text is the only signal.
struct CountdownRing: View {
    let endsAt: Date
    let seconds: Int
    let symbol: String
    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let left = max(0, endsAt.timeIntervalSince(context.date))
            let fraction = max(0, min(1, left / Double(max(1, seconds))))
            ZStack {
                Circle().stroke(CobaltColor.border.opacity(0.55), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(CobaltColor.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 7, weight: .semibold))
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// "continuing in background in N s": whole seconds left, rounded up, ticking once a second on the
/// second (the schedule is anchored on the countdown's own start, so each tick is a new whole number).
struct CountdownCaption: View {
    let endsAt: Date
    let seconds: Int
    /// One line (the compact row) or free to wrap (large Dynamic Type).
    var singleLine = true

    /// Whole seconds to show for `left` seconds remaining: rounded up, clamped to 1...seconds, so a
    /// fresh N s countdown reads N (never N + 1) and the last second reads 1.
    static func whole(left: TimeInterval, seconds: Int) -> Int {
        max(1, min(seconds, Int((left - 0.001).rounded(.up))))
    }

    var body: some View {
        TimelineView(.periodic(from: endsAt.addingTimeInterval(-Double(seconds)), by: 1)) { context in
            let whole = Self.whole(left: endsAt.timeIntervalSince(context.date), seconds: seconds)
            Text(ShareCopy.continuingIn(whole))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
                .lineLimit(singleLine ? 1 : nil)
                .fixedSize(horizontal: singleLine, vertical: true)
        }
        // the announcement carries it once; the text changing every second stays out of VoiceOver
        .accessibilityHidden(true)
    }
}

/// A stand-in for the filmstrip while its frames are still being read. Neutral grey with a slow
/// sweep: never the near-black frame base, which read as a dead bar. It keeps the strip's height so
/// nothing moves when the real frames arrive. After `giveUpAfter` seconds the sweep stops (the frames
/// are not coming; a quiet grey bar is honest).
struct StripPlaceholder: View {
    var height: CGFloat = 72
    var giveUpAfter: Double = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waiting = true

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CobaltColor.elevated)
            .frame(height: height)
            .overlay { if waiting && !reduceMotion { ShimmerSweep().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) } }
            .task {
                try? await Task.sleep(for: .seconds(giveUpAfter))
                waiting = false
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.framesA11y)
    }
}

/// A soft highlight crossing its container, contrast-safe in both appearances.
struct ShimmerSweep: View {
    var body: some View {
        GeometryReader { proxy in
            PhaseAnimator([-1.0, 1.0]) { phase in
                LinearGradient(
                    colors: [.clear, CobaltColor.surface.opacity(0.7), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width)
            } animation: { _ in
                .easeInOut(duration: 1.3)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The first real frame, small, at its own aspect. Nothing at all until a frame exists (no empty
/// rectangle); it develops in like a filmstrip cell does.
struct PosterThumb: View {
    let frame: Frame
    var maxHeight: CGFloat = 112
    var maxWidth: CGFloat = 132

    private var size: CGSize {
        let w = CGFloat(max(1, frame.image.width)), h = CGFloat(max(1, frame.image.height))
        let k = min(maxWidth / w, maxHeight / h)
        return CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    }

    var body: some View {
        Image(decorative: frame.image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
                    .strokeBorder(CobaltColor.hairline, lineWidth: 1)
            }
            .accessibilityHidden(true)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// The system share sheet for one URL (the finished webp's public link).
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
