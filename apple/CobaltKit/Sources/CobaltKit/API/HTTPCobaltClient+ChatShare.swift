import Foundation

// Shared chats (APP-API-CONTRACT 46.2) on the real client, keyed. The requests come from the generated endpoints; the
// replies are decoded as `ChatShare`. Refusals stay `CobaltError.api(code:httpStatus:)` (`error.chat.not_found`,
// `error.chat_share.not_found`, `error.chat_share.empty`, `error.share.off`).
extension HTTPCobaltClient {
    private struct ShareWire: Decodable { var share: ChatShare? }

    /// `GET /chat/threads/<id>/share`: the live share, or nil.
    public func chatShare(threadID: String) async throws -> ChatShare? {
        try await send(Endpoints.chatShareGet(id: threadID), as: ShareWire.self, timeout: 20).share
    }

    /// `PUT /chat/threads/<id>/share`: shares the chat, or changes the live share.
    public func shareChat(threadID: String, _ change: ChatShareChange) async throws -> ChatShare {
        let wire = try await send(Endpoints.chatSharePut(id: threadID), as: ShareWire.self, body: change.body, timeout: 30)
        guard let share = wire.share else { throw CobaltError.invalidResponse(httpStatus: 200) }
        return share
    }

    /// `POST /chat/threads/<id>/share/rotate`: a new key; the old link stops at once.
    public func rotateChatShare(threadID: String) async throws -> ChatShare {
        let wire = try await send(Endpoints.chatShareRotate(id: threadID), as: ShareWire.self, timeout: 20)
        guard let share = wire.share else { throw CobaltError.invalidResponse(httpStatus: 200) }
        return share
    }

    /// `DELETE /chat/threads/<id>/share`: stops sharing.
    public func stopChatShare(threadID: String) async throws {
        struct Ok: Decodable {}
        _ = try await send(Endpoints.chatShareDelete(id: threadID), as: Ok.self, timeout: 20)
    }
}
