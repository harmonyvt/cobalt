import CobaltKit
import SwiftUI

/// The detail's `more` menu (CONTRACT-MEDIA 1.10), in the contract's order: open in library (from the orbit,
/// when the library has the post), remove from this iphone, delete this webp (webp tab only), delete everything
/// (destructive, last, only when the media has something on the server and a way to delete it).
struct DetailMenu: View {
    let controller: DetailController
    let item: MediaItem
    let rendition: Rendition
    var openInLibrary: () -> Void

    private var model: AppModel { controller.model }

    /// From the orbit, when the library has the post: the library tab, on this media.
    private var showsOpenInLibrary: Bool {
        model.capabilities.library && item.post != nil && model.selectedTab != .library
    }

    var body: some View {
        let deleting = controller.isDeleting
        let busy = controller.isBusy(item)
        Menu {
            if showsOpenInLibrary {
                Button(Copy.Media.openInLibrary, systemImage: Symbol.Media.openInLibrary, action: openInLibrary)
            }
            if item.local != nil {
                Button(Copy.Media.removeMedia, systemImage: Symbol.Media.removeFromDevice) { controller.confirm = .removeMedia }
                    .disabled(deleting)
            }
            if rendition.isWebp {
                if rendition.deletableName != nil {
                    Button(Copy.Media.deleteWebp, systemImage: Symbol.Media.deleteWebp, role: .destructive) {
                        controller.confirm = .deleteWebp(rendition.id)
                    }
                    .disabled(deleting)
                } else if rendition.local != nil {
                    Button(Copy.Media.removeWebp, systemImage: Symbol.Media.removeFromDevice) {
                        controller.confirm = .removeWebp(rendition.id)
                    }
                    .disabled(deleting)
                }
            }
            if controller.canDeleteEverything(item) {
                Button(Copy.Media.deleteEverything, systemImage: Symbol.Media.deleteEverything, role: .destructive) {
                    controller.confirm = .deleteEverything
                }
                .disabled(deleting || busy)
            }
        } label: {
            Label(Copy.Media.more, systemImage: Symbol.Media.more)
        }
        .accessibilityLabel(Copy.Media.more)
    }
}

/// The confirm of each way to get rid of something, one `confirmationDialog` whose words follow the question
/// (CONTRACT-MEDIA 1.12): the destructive button names the act, the cancel says `keep`.
struct DetailDialogs: ViewModifier {
    let controller: DetailController
    let item: MediaItem
    let confirmed: (DetailController.Confirm) -> Void

    private var presented: Binding<Bool> {
        Binding(get: { controller.confirm != nil }, set: { if !$0 { controller.confirm = nil } })
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title(controller.confirm), isPresented: presented, titleVisibility: .visible, presenting: controller.confirm
        ) { ask in
            Button(button(ask), role: .destructive) { confirmed(ask) }
            Button(Copy.Media.keep, role: .cancel) {}
        } message: { ask in
            Text(message(ask))
        }
    }

    private func title(_ ask: DetailController.Confirm?) -> String {
        switch ask {
        case .deleteWebp: return Copy.Media.deleteWebpTitle
        case .removeWebp: return Copy.Media.removeWebpTitle
        case .removeMedia: return Copy.Media.removeMediaTitle
        case .deleteEverything: return Copy.Media.deleteEverythingTitle
        case nil: return ""
        }
    }

    private func button(_ ask: DetailController.Confirm) -> String {
        switch ask {
        case .deleteWebp: return Copy.Media.delete
        case .removeWebp, .removeMedia: return Copy.Media.remove
        case .deleteEverything: return Copy.Media.deleteEverything
        }
    }

    private func message(_ ask: DetailController.Confirm) -> String {
        switch ask {
        case .deleteWebp: return Copy.Media.deleteWebpMessage
        case .removeWebp: return Copy.Media.removeWebpMessage
        case .removeMedia: return Copy.Media.removeMediaMessage(webps: item.webpCount)
        case .deleteEverything: return Self.everythingMessage(controller: controller, item: item)
        }
    }

    /// (b) with the post route: what exists, for everyone. (a) on an older server: only the webps.
    static func everythingMessage(controller: DetailController, item: MediaItem) -> String {
        if controller.usesPostRoute(item) {
            let video = item.video
            let hosted = video?.hosted != nil || video?.publicURL != nil
            return Copy.Media.deleteEverythingMessage(video: video != nil, hosted: hosted, webps: item.webpCount)
        }
        return Copy.Media.deleteEverythingFallbackMessage(webps: controller.deletableWebps(item))
    }
}

extension View {
    func detailDialogs(controller: DetailController, item: MediaItem, confirmed: @escaping (DetailController.Confirm) -> Void) -> some View {
        modifier(DetailDialogs(controller: controller, item: item, confirmed: confirmed))
    }
}
