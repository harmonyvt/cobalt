import Foundation

extension AppModel {
    /// The server makes chat videos (`features.chat_video`, APP-API-CONTRACT 45).
    public var canMakeChatVideos: Bool { capabilities.chatVideo }

    /// "make video" (45.1): queues a render that replays the thread, from `options.from` (or the start) to its end. The render
    /// joins the editor's renders at once, so the queue and the render's Live Activity show it before the next poll. Throws
    /// `ChatError` (`.off` without `features.chat_video`, `.busy` while a reply is written, `.videoEmpty`, `.notFound`),
    /// `EditError` (`.queueFull`, `.off`) or the transport's error; nothing is queued then.
    @discardableResult
    public func makeChatVideo(threadID: String, options: ChatVideoOptions) async throws -> EditRender {
        guard capabilities.chatVideo else { throw ChatError.off }
        guard !chat.isBusy(threadID) else { throw ChatError.busy }
        let render = try await ctx.client.makeChatVideo(
            threadID: threadID, shape: options.shape, theme: options.theme, speed: options.speed.rawValue, from: options.from,
            to: nil, notify: options.notify)
        editor.mergeRenders([render])
        await unifiedQueue.refresh()
        return render
    }
}
