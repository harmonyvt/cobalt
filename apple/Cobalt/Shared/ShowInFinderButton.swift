import CobaltKit
import SwiftUI

/// "show in finder" for a media's kept files in the Mac's folder (CONTRACT-OFFLINE.md 13.10): the files selected in Finder
/// (a gallery's folder for its items; the folder itself when none is there). Drawn only on the Mac, only while one of
/// `videos` is kept in the folder; elsewhere it is empty, so a menu can list it unconditionally. Disabled while the folder is
/// not connected. A button for the detail's `more` menu and the library's context menu. (Wave M1 compile shim: the Mac
/// surfaces lane reworks it with the rest of the offline items.)
struct ShowInFinderButton: View {
    let model: AppModel
    /// The renditions whose files to show (the one on screen, or all of a media's).
    let videos: [StoredVideo]

    var body: some View {
        #if os(macOS)
        if model.macFolder.isAvailable, videos.contains(where: { $0.place == .offline }) {
            Button(Copy.Folder.menuShowInFinder, systemImage: Symbol.Folder.showInFinder) {
                Task { await model.macFolder.reveal(videos) }
            }
            .disabled(model.macFolder.status.problem == .unreachable)
        }
        #else
        EmptyView()
        #endif
    }
}
