import CobaltKit
import SwiftUI

/// "show in finder" for a media's copy in the Mac's "save to a folder" folder: the file selected in Finder
/// (the folder itself when the copy is gone from it). Drawn only on the Mac, only while the folder
/// ledger says one of `videos` was copied there; elsewhere it is empty, so a menu can list it
/// unconditionally. A button for the detail's `more` menu and the library's context menu.
struct ShowInFinderButton: View {
    let model: AppModel
    /// The renditions whose copies to show (the one on screen, or all of a media's).
    let videos: [StoredVideo]

    var body: some View {
        #if os(macOS)
        if model.folderSync.isAvailable, model.folderSync.hasCopy(any: videos) {
            Button(Copy.Folder.menuShowInFinder, systemImage: Symbol.Folder.showInFinder) {
                Task { await model.folderSync.revealInFinder(videos) }
            }
        }
        #else
        EmptyView()
        #endif
    }
}
