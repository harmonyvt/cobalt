import CobaltKit

/// Emotes that a screen holds in full and wants the pane to open by id (`PaneItem.emote(id)`, `.emoteAddToSet(id)`: the
/// pane's items carry an id only). The caller remembers the hit just before opening the pane; the page asks for it by id.
/// The Twitch chat does this with an emote it was handed (`TwitchChatEmote.asHit`); the 7tv tab does not need to (its
/// owned emotes and open set are found on their own). Bounded: the 64 newest are kept.
@MainActor
enum SevenTvEmoteHits {
    private static var hits: [String: EmoteHit] = [:]
    private static var order: [String] = []
    private static let limit = 64

    static func remember(_ hit: EmoteHit) {
        if hits[hit.id] == nil { order.append(hit.id) }
        hits[hit.id] = hit
        while order.count > limit { hits[order.removeFirst()] = nil }
    }

    static func hit(_ id: String) -> EmoteHit? { hits[id] }
}
