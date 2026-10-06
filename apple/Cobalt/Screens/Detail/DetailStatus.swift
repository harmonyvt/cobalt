import CobaltKit
import SwiftUI

/// The state under the actions of any tab: a delete going, failing or only half done (with `try again`), a failed button, a
/// neutral line that says what just happened (`copied 12 links.`), and why `delete everything` is off. Shared by the video's
/// buttons and the gallery's.
struct DetailStatus: View {
    let controller: DetailController
    let item: MediaItem
    /// Called after an action that leaves this screen.
    var leave: () -> Void = {}

    @Environment(\.shell) private var shell

    var body: some View {
        let phase = controller.phase
        VStack(spacing: 8) {
            switch phase {
            case .deleting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Media.deleting).font(Font.cobalt(12, .regular, relativeTo: .footnote)).foregroundStyle(CobaltColor.caption)
                }
                .accessibilityElement(children: .combine)
            case .failed:
                problem(Copy.Media.deleteFailed, retry: true)
            case .partial(let remaining):
                problem(Copy.Media.deletePartial(remaining: remaining), retry: true)
            case .busy:
                problem(busyLine, retry: false)
            case .idle:
                if let notice = controller.notice {
                    problem(notice, retry: false)
                } else if let flash = controller.flash {
                    Text(flash)
                        .font(Font.cobalt(12, .regular, relativeTo: .caption)).foregroundStyle(CobaltColor.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.updatesFrequently)
                } else if controller.canDeleteEverything(item), controller.isBusy(item) {
                    // delete everything is off while this media's own run is going
                    Text(busyLine)
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption)).foregroundStyle(CobaltColor.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .motion(Motion.rows, value: phase)
        .motion(Motion.rows, value: controller.flash)
        .frame(maxWidth: .infinity)
    }

    /// "still making a webp from this": a gallery's own run is saving or making something from the post.
    private var busyLine: String { item.detailShape == .classic ? Copy.Media.deleteBusy : DetailWords.postBusy }

    private func problem(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.errorText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            if retry {
                Button(Copy.Media.tryAgain, systemImage: Symbol.Media.retry) {
                    Task {
                        if case .popWithStatus(let message) = await controller.tryAgain(item) {
                            shell.showStatus(message)
                            leave()
                        }
                    }
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
        .accessibilityElement(children: .contain)
    }
}
