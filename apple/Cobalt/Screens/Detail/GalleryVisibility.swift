import CobaltKit
import SwiftUI

/// The one public/private switch of a whole post (CONTRACT-GALLERY 1.19): `public · 12 links` / `private · no links`, over the
/// photos and every file made from them, on every tab. Turning it off asks first, because every link stops working for
/// everyone; turning it on again brings back the same links. A server without the post switch keeps the per-file one.
struct GalleryVisibilitySection: View {
    let controller: DetailController
    let item: MediaItem
    let rendition: Rendition

    @State private var asking = false
    @Environment(\.hapticsEnabled) private var haptics

    private var changing: Bool { controller.postVisibility == .working }
    private var isOn: Bool { controller.isPostPublic(item) }
    private var links: Int { controller.publicLinks(of: item) }
    private var many: Bool { item.detailShape == .gallery || item.made.count > 0 }

    var body: some View {
        if controller.canSwitchPost(item) {
            Section {
                Toggle(isOn: Binding(get: { isOn }, set: { choose($0) })) {
                    Label(title, systemImage: isOn ? Symbol.Media.isPublic : Symbol.Media.isPrivate)
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(changing || controller.isDeleting)
                .confirmationDialog(Copy.Media.makePrivateTitle, isPresented: $asking, titleVisibility: .visible) {
                    Button(Copy.Media.makePrivate, role: .destructive) {
                        Task { await controller.setPostPublic(false, for: item) }
                    }
                    Button(Copy.Media.keepPublic, role: .cancel) {}
                } message: {
                    Text(Copy.Media.makePrivateMessage)
                }
                .accessibilityHint(footnote.text)
            } footer: {
                Text(footnote.text)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(footnote.isProblem ? CobaltColor.errorText : Color.secondary)
                    .lineSpacing(2)
            }
            .motion(Motion.rows, value: footnote.text)
            .haptic(.error, trigger: controller.visibilityFailed[DetailController.postKey], enabled: haptics) { $0 != nil }
        } else if controller.canSwitchVisibility(rendition) {
            VisibilitySection(controller: controller, rendition: rendition)
        }
    }

    /// `public · 12 links` for a gallery; `public link` for one photo.
    private var title: String {
        if changing { return Copy.Media.publicLink }
        guard many else { return Copy.Media.publicLink }
        return isOn ? Copy.Gallery.publicLinks(links) : Copy.Gallery.privateNoLinks
    }

    private func choose(_ want: Bool) {
        guard want != isOn, !changing else { return }
        if want {
            Task { await controller.setPostPublic(true, for: item) }
        } else {
            asking = true
        }
    }

    /// The request in flight, a failure, the cache's caveat, or what the state means.
    private var footnote: (text: String, isProblem: Bool) {
        if changing { return (isOn ? Copy.Media.turningOff : Copy.Media.makingLink, false) }
        if let failed = controller.visibilityFailed[DetailController.postKey] { return (failed, true) }
        if !isOn, controller.visibilityCacheNote.contains(DetailController.postKey) {
            return ("\(Copy.Media.publicOff) \(Copy.Media.cacheNote)", false)
        }
        return (isOn ? Copy.Media.publicOn : Copy.Media.publicOff, false)
    }
}
