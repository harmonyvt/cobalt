import CobaltKit
import SwiftUI

// How a tab's `NavigationStack` pushes the one detail screen (apple/04-PHASE4 4.2). On the iPhone the capture tab's recent
// saves and the library's grid push the SAME `MediaDetail`; only the iPad and the Mac open a post in the pane.
//
//     NavigationLink(value: MediaDetailRoute(post: post)) { row }      // or: path.append(MediaDetailRoute(item: item))
//     NavigationStack { content.mediaDetailDestination() }             // once, inside the stack
//
// The destination reads the media as it is now (the post may not have loaded yet, a chat result, a deep link) and waits for
// it, so a route built from just an id is enough.

/// A media to open the unified detail on: its library post id, the `post:<id>` form `MediaItem.id` has, or the id of a media
/// only this device holds. Hashable, so it goes in a `NavigationPath` and survives a restore.
struct MediaDetailRoute: Hashable {
    /// What `AppModel.paneMedia(id:)` resolves.
    let id: String
    /// The tab to open on (`Rendition.ID`); nil: the face.
    var initial: Rendition.ID?

    init(id: String, initial: Rendition.ID? = nil) {
        self.id = id
        self.initial = initial
    }

    init(post: LibraryPost, initial: Rendition.ID? = nil) {
        self.init(id: post.id, initial: initial)
    }

    init(item: MediaItem, initial: Rendition.ID? = nil) {
        self.init(id: item.id, initial: initial)
    }

    init(media: StoredMedia, initial: Rendition.ID? = nil) {
        self.init(id: media.id, initial: initial)
    }
}

extension View {
    /// Registers `navigationDestination(for: MediaDetailRoute.self)` on the enclosing stack: a pushed route shows the unified
    /// `MediaDetail`. The model comes from the window's `PaneHost` (`\.mediaDetailModel`); a stack outside one (a sheet, a
    /// preview) passes it.
    func mediaDetailDestination(model: AppModel? = nil) -> some View {
        modifier(MediaDetailDestination(explicit: model))
    }
}

private struct MediaDetailDestination: ViewModifier {
    let explicit: AppModel?
    @Environment(\.mediaDetailModel) private var environment: AppModel?

    func body(content: Content) -> some View {
        let model = explicit ?? environment
        content.navigationDestination(for: MediaDetailRoute.self) { route in
            if let model {
                MediaDetailRouteView(model: model, route: route)
            }
        }
    }
}

/// The destination: the detail on the media the route names, once the library has it. A post that is not loaded yet is
/// asked for (the library's `locate`), and one that is nowhere says so.
private struct MediaDetailRouteView: View {
    let model: AppModel
    let route: MediaDetailRoute

    @State private var first: MediaItem?
    @State private var missing = false

    var body: some View {
        let now = model.paneMedia(id: route.id)
        Group {
            if let item = now ?? first {
                MediaDetail(model: model, item: item, initial: route.initial)
            } else if missing {
                Text(Copy.Media.deleted)
                    .font(CobaltType.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: now, initial: true) { _, found in
            if let found { first = found; missing = false }
        }
        .task(id: route) {
            guard model.paneMedia(id: route.id) == nil else { return }
            if model.library.posts.isEmpty, model.capabilities.library { await model.library.refresh() }
            if model.paneMedia(id: route.id) == nil, route.id.hasPrefix("post:") || model.store.media(id: route.id) == nil {
                _ = await model.library.locate(postID: route.id.hasPrefix("post:") ? String(route.id.dropFirst(5)) : route.id)
            }
            if model.paneMedia(id: route.id) == nil { missing = true }
        }
    }
}
