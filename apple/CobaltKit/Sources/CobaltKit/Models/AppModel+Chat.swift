import Foundation

extension AppModel {
    /// "ask about this" (APP-API-CONTRACT 27.4): makes a chat thread with these posts attached to its draft (they go with the
    /// first message the owner sends), opens the chat tab on it and asks for the composer's keyboard. At most
    /// `ChatRule.attachmentLimit` posts. Throws `ChatError` (`.off` without `features.chat`, `.tooMany` at 200 threads) or
    /// the transport's error; nothing opens then.
    public func askAbout(_ posts: [LibraryPost]) async throws {
        guard capabilities.chat else { throw ChatError.off }
        let shown = Array(posts.prefix(ChatRule.attachmentLimit))
        guard !shown.isEmpty else { throw ChatError.badRequest }
        try await chat.startThread(with: shown.map(\.id), posts: shown)
        queueShown = false                 // a sheet over the shell would hide the tab
        selectedTab = .chat
    }

    /// Opens a post of a chat reply in the library tab (iPad and Mac): the library loads pages until the post is in and
    /// shows it, exactly as "open in library" does.
    public func revealInLibrary(postID: String) {
        library.expandedPostID = postID
        selectedTab = .library
    }
}
