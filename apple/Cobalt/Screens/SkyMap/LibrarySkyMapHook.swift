import CobaltKit
import SwiftUI

// The one place the library reaches the sky map: the toolbar button, the presentation and "open this star's post".
// Screen: `SkyMapScreen`. Contract: `deploy/cloudflare/APP-API-CONTRACT.md` section 21 (`GET /library/map`).

/// The toolbar button, only on a server that has the search (the map is made of its embeddings) and not while
/// selecting. A plain button like the view switcher's, so on the iPhone and iPad it joins that glass capsule.
struct LibrarySkyMapButton: View {
    let controller: LibraryController

    var body: some View {
        Button {
            controller.showingSkyMap = true
        } label: {
            Image(systemName: Symbol.SkyMap.button)
        }
        .accessibilityLabel(Copy.SkyMap.title)
        .help(Copy.SkyMap.hint)
    }
}

/// Presents the sky map: a full-screen cover on the iPhone and iPad (the sky wants every pixel, with its own close
/// button), a large sheet on the Mac. A star the owner opens closes the map first and the library shows the post once
/// the cover has gone (pushing a detail under a dismissing cover is not reliable).
struct LibrarySkyMapPresenter: ViewModifier {
    let model: AppModel
    @Bindable var controller: LibraryController
    @State private var pending: String?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $controller.showingSkyMap, onDismiss: openPending) { screen }
        #else
        content.sheet(isPresented: $controller.showingSkyMap, onDismiss: openPending) {
            screen.frame(minWidth: 860, idealWidth: 1120, minHeight: 620, idealHeight: 780)
        }
        #endif
    }

    private var screen: some View {
        SkyMapScreen(model: model) { postKey in
            pending = postKey
            controller.showingSkyMap = false
        } onClose: {
            controller.showingSkyMap = false
        }
    }

    private func openPending() {
        guard let key = pending else { return }
        pending = nil
        Task { await controller.openFromSkyMap(key) }
    }
}

extension LibraryController {
    /// A star of the sky map was chosen. `MapPost.id` is the post key, which is the library's post id, so the library
    /// loads pages until the post is in (`locate`), makes sure no filter hides it, and then opens it the way a tap does:
    /// the phone pushes the detail, the iPad and Mac select it in the inspector. The tile is lit either way.
    func openFromSkyMap(_ postKey: String) async {
        guard await library.locate(postID: postKey), let post = library.post(id: postKey) else {
            showStatus(Copy.Library2.notFound)
            return
        }
        if !model.libraryRows.contains(where: { $0.id == postKey }) {
            library.query = ""
            library.show = .everything
            library.kindFilter = .all
        }
        if compact || library.viewMode == .mosaic { reveal = LibraryReveal(id: postKey) }
        if compact {
            open(model.mediaItem(for: post), initial: nil)
        } else {
            selection = postKey
            inspectorOpen = true
        }
    }
}
