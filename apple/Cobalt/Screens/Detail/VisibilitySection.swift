import CobaltKit
import SwiftUI

/// The public/private switch of one rendition, video or webp (CONTRACT-VISIBILITY 6.2): one `Toggle`, `globe` while
/// the link is public and `lock.fill` while it is not, and under it what that means. There is no second button to
/// make a link: on is a link, off is none. The link itself (selectable) and its copy and share buttons are drawn
/// where they always were and only exist while the rendition has a public URL.
///
/// Turning it on moves the switch at once and says "making the link…" until the server answers (the switch is
/// disabled meanwhile); a failure puts it back and says so. Turning it off asks first, because the link stops
/// working for everyone; making it public again brings back the same link.
struct VisibilitySection: View {
    let controller: DetailController
    let rendition: Rendition

    @State private var asking = false
    @Environment(\.hapticsEnabled) private var haptics

    private var model: AppModel { controller.model }
    private var changing: Bool { model.isChangingVisibility(rendition) }
    private var isOn: Bool { rendition.visibility == .public }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isOn }, set: { want in choose(want) })) {
                Label(Copy.Media.publicLink, systemImage: isOn ? Symbol.Media.isPublic : Symbol.Media.isPrivate)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(changing || controller.isDeleting)
            .confirmationDialog(Copy.Media.makePrivateTitle, isPresented: $asking, titleVisibility: .visible) {
                Button(Copy.Media.makePrivate, role: .destructive) {
                    Task { await controller.setVisibility(rendition, public: false) }
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
        .haptic(.error, trigger: controller.visibilityFailed[rendition.id], enabled: haptics) { $0 != nil }
    }

    /// The row's switch: on goes straight to the server; off asks first.
    private func choose(_ want: Bool) {
        guard want != isOn, !changing else { return }
        if want {
            Task { await controller.setVisibility(rendition, public: true) }
        } else {
            asking = true
        }
    }

    /// What sits under the switch: the request in flight, a failure, the cache's caveat, or what the state means.
    private var footnote: (text: String, isProblem: Bool) {
        if changing { return (isOn ? Copy.Media.makingLink : Copy.Media.turningOff, false) }
        if let failed = controller.visibilityFailed[rendition.id] { return (failed, true) }
        if !isOn, controller.visibilityCacheNote.contains(rendition.id) {
            return ("\(Copy.Media.publicOff) \(Copy.Media.cacheNote)", false)
        }
        return (isOn ? Copy.Media.publicOn : Copy.Media.publicOff, false)
    }
}
