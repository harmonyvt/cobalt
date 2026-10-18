import CobaltKit
import SwiftUI

extension LibraryController {
    /// "ask about this" is offered while the server has chat and the media has a library post to attach.
    func canAskAbout(_ item: MediaItem) -> Bool { model.capabilities.chat && item.post != nil }

    /// Starts a chat about the post: the thread is made with it attached to the draft, the chat tab opens on it with the
    /// keyboard up. A refusal (200 chats, chat off, offline) shows as the usual status line.
    func askAbout(_ item: MediaItem) {
        guard let post = item.post else { return }
        Task {
            do {
                try await model.askAbout([post])
            } catch {
                showStatus(Copy.Chat.message(for: error))
            }
        }
    }
}
