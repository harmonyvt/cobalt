import Foundation

/// The 7TV account routes (APP-API-CONTRACT 57.4; keyed). `HTTPCobaltClient` (`HTTPCobaltClient+SevenTv.swift`) and
/// `PreviewClient` (`PreviewSevenTv.swift`) conform; `SevenTvStore` reaches it as `ctx.client as? any SevenTvClient` and treats
/// a client that is not one as a server without the routes (`SevenTvError.off`). Kept apart from `CobaltClient`, like
/// `EditorClient`, so no existing fake has to change. Every call throws `SevenTvError` for the server's refusals.
public protocol SevenTvClient: Sendable {
    /// `GET /7tv`: not linked, or the account and its channels (`relink` with no channels when 7TV signed it out).
    func sevenTvStatus() async throws -> SevenTvStatus
    /// `POST /7tv/link {token}`: checks the token with 7TV, stores it, answers the `GET /7tv` body.
    func linkSevenTv(token: String) async throws -> SevenTvStatus
    /// `DELETE /7tv`: forgets the token.
    func unlinkSevenTv() async throws -> SevenTvStatus
    /// `GET /7tv/channels/<id>/sets`: live first, then by name.
    func sevenTvSets(channelID: String) async throws -> SevenTvChannelSets
    /// `GET /7tv/sets/<id>?q=&page=`: 60 emotes a page; `query` filters by name in the set (nil or empty sends none).
    func sevenTvSet(id: String, query: String?, page: Int) async throws -> SevenTvSetPage
    /// `POST /7tv/sets {owner_id, name}`: the new set (201).
    func createSevenTvSet(ownerID: String, name: String) async throws -> SevenTvSetInfo
    /// `PATCH /7tv/sets/<id> {name}`.
    func renameSevenTvSet(id: String, name: String) async throws -> SevenTvSetInfo
    /// `POST /7tv/sets/<id>/emotes {emote_id, alias?, override_conflicts?}` (nil alias and false override are left out). A name
    /// already in the set without `override_conflicts` is `SevenTvError.nameTaken` (409, with the emote holding it when known).
    func addSevenTvEmote(setID: String, emoteID: String, alias: String?, overrideConflicts: Bool) async throws -> SevenTvEmoteChange
    /// `PATCH /7tv/sets/<id>/emotes/<emote> {alias, from?}`: renames the emote in this set; `from` is its current alias.
    func renameSevenTvEmote(setID: String, emoteID: String, alias: String, from: String?) async throws -> SevenTvEmoteChange
    /// `DELETE /7tv/sets/<id>/emotes/<emote>?alias=`: `alias` picks one when the emote is in the set twice.
    func removeSevenTvEmote(setID: String, emoteID: String, alias: String?) async throws -> SevenTvEmoteChange
    /// `POST /7tv/channels/<id>/live {set_id}`: the channel's live set (nil clears it).
    func makeSevenTvSetLive(channelID: String, setID: String?) async throws -> SevenTvLiveChange
    /// `POST /7tv/emotes` (57.9): a library picture as a new emote of the linked account (201), added to `setID` when given;
    /// cropped and shrunk first by the server when the draft asks or the file is too big (57.10, `fitted`).
    func uploadSevenTvEmote(_ draft: SevenTvUploadDraft) async throws -> SevenTvUploadResult
    /// `GET /7tv/emotes/<id>` (57.9): one emote; `pending` while 7TV is still processing a new upload.
    func sevenTvEmote(id: String) async throws -> SevenTvEmoteInfo
    /// `GET /7tv/uploads`: the emotes uploaded through capystore (57.9), newest first, at most 100.
    func sevenTvUploads() async throws -> [SevenTvUploadedEmote]
}

/// The paths and bodies of the routes, in one place so the HTTP client and the tests agree.
enum SevenTvRoute {
    static let status = "/7tv"
    static let link = "/7tv/link"
    static let sets = "/7tv/sets"
    static let uploads = "/7tv/emotes"
    /// `GET /7tv/uploads`: what capystore uploaded.
    static let myUploads = "/7tv/uploads"

    static func channelSets(_ channelID: String) -> String { "/7tv/channels/\(segment(channelID))/sets" }
    static func channelLive(_ channelID: String) -> String { "/7tv/channels/\(segment(channelID))/live" }
    static func set(_ setID: String) -> String { "/7tv/sets/\(segment(setID))" }
    static func emotes(_ setID: String) -> String { "/7tv/sets/\(segment(setID))/emotes" }
    static func emote(_ setID: String, _ emoteID: String) -> String { "/7tv/sets/\(segment(setID))/emotes/\(segment(emoteID))" }

    static func emoteInfo(_ emoteID: String) -> String { "/7tv/emotes/\(segment(emoteID))" }

    /// `POST /7tv/emotes`: empty tags, false toggles, a missing set or alias, and no crop or size are left out. `crop` is
    /// `{x, y, w, h}` (fractions, clamped into the picture; the whole picture is left out), `size` 32...1000.
    static func uploadBody(_ draft: SevenTvUploadDraft) -> [String: Any] {
        var body: [String: Any] = ["file": draft.fileID, "name": draft.name]
        let tags = SevenTvEmoteRule.cleanTags(draft.tags)
        if !tags.isEmpty { body["tags"] = tags }
        if draft.zeroWidth { body["zero_width"] = true }
        if draft.isPrivate { body["private"] = true }
        if let setID = draft.setID, !setID.isEmpty {
            body["set_id"] = setID
            if let alias = draft.alias, !alias.isEmpty { body["alias"] = alias }
        }
        if let crop = draft.crop?.clamped, !crop.isWhole {
            body["crop"] = ["x": crop.x, "y": crop.y, "w": crop.w, "h": crop.h]
        }
        if let size = SevenTvEmoteRule.clampSize(draft.size) { body["size"] = size }
        return body
    }

    /// `?q=&page=` of a set's page: `q` only when there is one, `page` at least 1.
    static func setQuery(query: String?, page: Int) -> [(String, String)] {
        var items: [(String, String)] = []
        if let q = query.flatMap(SevenTvRule.cleanFilter) { items.append(("q", q)) }
        items.append(("page", String(max(1, page))))
        return items
    }

    static func addBody(emoteID: String, alias: String?, overrideConflicts: Bool) -> [String: Any] {
        var body: [String: Any] = ["emote_id": emoteID]
        if let alias, !alias.isEmpty { body["alias"] = alias }
        if overrideConflicts { body["override_conflicts"] = true }
        return body
    }

    /// "copy to set": the emote under the name it has in the set it comes from (always sent, so a renamed emote keeps it).
    static func copyBody(_ emote: SevenTvSetItem, overrideConflicts: Bool = false) -> [String: Any] {
        addBody(emoteID: emote.emoteID, alias: emote.alias, overrideConflicts: overrideConflicts)
    }

    static func renameBody(alias: String, from: String?) -> [String: Any] {
        var body: [String: Any] = ["alias": alias]
        if let from, !from.isEmpty { body["from"] = from }
        return body
    }

    static func liveBody(setID: String?) -> [String: Any] {
        ["set_id": setID.map { $0 as Any } ?? NSNull()]
    }

    /// A path segment: anything but letters and digits percent-encoded (7TV ids are both, so this changes nothing for them).
    static func segment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
    }
}
