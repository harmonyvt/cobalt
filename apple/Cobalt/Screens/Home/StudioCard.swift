import CobaltKit
import SwiftUI

// What is left of the work card now that a landed video becomes a focused planet (FocusView.swift):
// the image post, which has no planet, only a file to host.

/// "save to photos" and "host original" / "host as-is", with their done and failed states.
struct SideActions: View {
    let pipeline: Pipeline
    var hostLabel = Copy.hostOriginal
    var showsPhotos = true
    @Environment(\.hapticsEnabled) private var haptics

    var body: some View {
        ButtonRow {
            if showsPhotos {
                switch pipeline.photosPlacement {
                case .inAlbum, .inLibrary:
                    // already in the owner's album or library (CONTRACT-SYNC.md decision 12): a statement, not a button
                    Button(pipeline.photosPlacement == .inAlbum ? Copy.Sync.inAlbum : Copy.Sync.inLibrary,
                           systemImage: Symbol.Sync.inPhotos) {}
                        .buttonStyle(.cobaltDone())
                        .allowsHitTesting(false)
                        .accessibilityRemoveTraits(.isButton)
                case .none:
                    StatusButton(title: pipeline.photos == .done ? Copy.savedPhotos : Copy.savePhotos,
                                 systemImage: Symbol.savePhotos, status: pipeline.photos) {
                        pipeline.saveToPhotos()
                    }
                }
            }
            // Publishing no longer copies the link by itself: once it is public the button copies it.
            StatusButton(title: pipeline.hosting == .done ? Copy.copyLink : hostLabel,
                         systemImage: Symbol.host, status: pipeline.hosting, prominent: true) {
                if pipeline.hosting == .done, let url = pipeline.hostedOriginalURL {
                    Pasteboard.copy(url.absoluteString)
                } else {
                    pipeline.hostOriginal()
                }
            }
        }
        .haptic(.success, trigger: pipeline.photos, enabled: haptics) { $0 == .done }
        .haptic(.success, trigger: pipeline.hosting, enabled: haptics) { $0 == .done }
        .haptic(.error, trigger: pipeline.photos, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
        .haptic(.error, trigger: pipeline.hosting, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
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
