import CobaltKit
import SwiftUI

/// "show in finder" for a media's kept files in the Mac's folder (CONTRACT-OFFLINE.md 13.10): the files selected in Finder
/// (the media's gallery folder for a gallery's items; the folder itself when none of them is there). The Mac's twin of
/// `ShowInFilesButton`: drawn only on the Mac and only while one of the files is kept (`keep` and a file here), so a menu can
/// list it unconditionally; elsewhere it is empty. Disabled, with the reason as its help, while the folder is not connected.
/// A button for the library's context menu and the detail's `more` menu.
struct ShowInFinderButton: View {
    let model: AppModel
    /// Where the files come from: a media (the store's current record of it, so a rename in Finder since the item was
    /// built is already followed) or renditions the caller picked.
    private let source: Source

    private enum Source {
        case item(MediaItem)
        case videos([StoredVideo])
    }

    init(model: AppModel, item: MediaItem) {
        self.model = model
        source = .item(item)
    }

    init(model: AppModel, videos: [StoredVideo]) {
        self.model = model
        source = .videos(videos)
    }

    /// The records to reveal: the current ones for a media, else what was given.
    private var videos: [StoredVideo] {
        switch source {
        case .videos(let videos):
            return videos
        case .item(let item):
            if let local = item.local, let current = model.store.media(id: local.id) { return current.renditions }
            return item.renditions.compactMap(\.local)
        }
    }

    var body: some View {
        #if os(macOS)
        let folder = model.macFolder
        if folder.isAvailable, model.store.canKeep {
            let videos = videos
            if videos.contains(where: \.isOffline) {
                let problem = folder.status.problem
                Button(Copy.Offline.showInFinder, systemImage: Symbol.showInFinder) {
                    Task { await folder.reveal(videos) }
                }
                .disabled(problem == .unreachable)
                .help(problem == .unreachable ? Copy.Folder.notConnected(path: folder.status.path) : "")
            }
        }
        #else
        EmptyView()
        #endif
    }
}
