import CobaltKit
import SwiftUI

// What is left of the work card now that a landed video becomes a focused planet (FocusView.swift):
// the image post, which has no planet, only a file to host.

/// "host original" / "host as-is" (the card's one word) and "save to photos" (an icon), with their done and failed states.
struct SideActions: View {
    let pipeline: Pipeline
    var hostLabel = Copy.hostOriginal
    var showsPhotos = true
    @Environment(\.hapticsEnabled) private var haptics
    @State private var copiedTick = 0

    private var isPublished: Bool { pipeline.hosting == .done }
    private var photosFailed: Bool { if case .failed = pipeline.photos { return true } else { return false } }

    /// The one worded button: "host original" / "host as-is" until it is public, then "copy share" (or "copy
    /// link" when the file has no share page). Save to photos and copy direct are icons beside it.
    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showsPhotos { photosIcon }
                if isPublished, let url = pipeline.hostedOriginalURL, pipeline.shareLink(for: url) != url {
                    // Publishing no longer copies the link by itself: once it is public the button copies it, as
                    // "copy share" (worded) and "copy direct" (icon) when the file has a share page.
                    Button {
                        Pasteboard.copy(url.absoluteString)
                        copiedTick += 1
                    } label: {
                        Label(Copy.LinkPair.copyDirectLink, systemImage: LinkForm.direct.symbol)
                    }
                    .buttonStyle(.cobaltIcon())
                    .accessibilityLabel(Copy.LinkPair.directA11y)
                    Button(LinkForm.share.copyTitle, systemImage: LinkForm.share.symbol) {
                        Pasteboard.copy(pipeline.shareLink(for: url).absoluteString)
                        copiedTick += 1
                    }
                    .buttonStyle(.cobaltPrimary())
                    .accessibilityLabel(Copy.LinkPair.shareA11y)
                } else {
                    StatusButton(title: isPublished ? Copy.copyLink : hostLabel,
                                 systemImage: Symbol.host, status: pipeline.hosting, prominent: true) {
                        if isPublished, let url = pipeline.hostedOriginalURL {
                            Pasteboard.copy(pipeline.shareLink(for: url).absoluteString)
                            copiedTick += 1
                        } else {
                            pipeline.hostOriginal()
                        }
                    }
                }
            }
        }
        .haptic(.success, trigger: copiedTick, enabled: haptics)
        .haptic(.success, trigger: pipeline.photos, enabled: haptics) { $0 == .done }
        .haptic(.success, trigger: pipeline.hosting, enabled: haptics) { $0 == .done }
        .haptic(.error, trigger: pipeline.photos, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
        .haptic(.error, trigger: pipeline.hosting, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
    }

    /// "save to photos" as an icon: green once saved, pulsing while it saves, the retry symbol after a failure. Once
    /// the original is in the owner's album or library (CONTRACT-SYNC.md decision 12) it is a statement, not a button.
    @ViewBuilder
    private var photosIcon: some View {
        switch pipeline.photosPlacement {
        case .inAlbum, .inLibrary:
            Button {} label: {
                Label(pipeline.photosPlacement == .inAlbum ? Copy.Sync.inAlbum : Copy.Sync.inLibrary,
                      systemImage: Symbol.Sync.inPhotos)
            }
            .buttonStyle(.cobaltIcon(state: .done))
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
        case .none:
            Button { pipeline.saveToPhotos() } label: {
                Label(pipeline.photos == .done ? Copy.savedPhotos : Copy.savePhotos,
                      systemImage: pipeline.photos == .done ? Symbol.checkmark : photosFailed ? Symbol.retry : Symbol.savePhotos)
            }
            .buttonStyle(.cobaltIcon(state: pipeline.photos == .done ? .done : pipeline.photos == .working ? .working : .idle))
            .symbolBounce(on: pipeline.photos == .done)
        }
    }
}

/// An image post: nothing to trim, only to host.
struct ImageCardContent: View {
    let pipeline: Pipeline
    let info: MediaInfo
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(info.name)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(info.bytes.map { Format.bytes($0) } ?? "")
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                CloseButton(action: onClose)
            }
            Text(Copy.imageNote)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            SideActions(pipeline: pipeline, hostLabel: Copy.hostAsIs, showsPhotos: false)
        }
    }
}
