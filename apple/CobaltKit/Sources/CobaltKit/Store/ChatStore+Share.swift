import Foundation

// A chat shared as a web page (APP-API-CONTRACT 46): the share sheet's calls. Each one keeps `shares[threadID]` as the
// server answered it, so the sheet and the thread's menu read one value.
extension ChatStore {
    /// `GET /chat/threads/<id>/share`.
    @discardableResult
    public func loadShare(_ threadID: String) async throws -> ChatShare? {
        let share = try await ctx.client.chatShare(threadID: threadID)
        shares[threadID] = .some(share)
        return share
    }

    /// `PUT /chat/threads/<id>/share`: shares it (a new share starts with media on, code off) or changes the live share.
    @discardableResult
    public func share(_ threadID: String, _ change: ChatShareChange = ChatShareChange()) async throws -> ChatShare {
        let share = try await ctx.client.shareChat(threadID: threadID, change)
        shares[threadID] = .some(share)
        return share
    }

    /// `POST /chat/threads/<id>/share/rotate`.
    @discardableResult
    public func rotateShare(_ threadID: String) async throws -> ChatShare {
        let share = try await ctx.client.rotateChatShare(threadID: threadID)
        shares[threadID] = .some(share)
        return share
    }

    /// `DELETE /chat/threads/<id>/share`.
    public func stopShare(_ threadID: String) async throws {
        try await ctx.client.stopChatShare(threadID: threadID)
        shares[threadID] = .some(nil)
    }

    /// The thread's share as last read: nil while not read yet or not shared.
    public func shareOf(_ threadID: String) -> ChatShare? { shares[threadID] ?? nil }
}
