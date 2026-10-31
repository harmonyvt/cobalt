import Foundation

public struct TransferProgress: Sendable, Equatable {
    public var bytes: Int64
    public var total: Int64?
}

public enum RemoteFile: Sendable, Equatable {
    case open(URL)                 // tunnel, redirect, picker item, public media: never sent the key
    case studioSource(session: String)
    case libraryItem(id: String)   // keyed
}

public protocol CobaltClient: Sendable {
    var baseURL: URL { get }
    func capabilities() async -> Capabilities
    func resolve(_ link: URL) async throws -> CobaltResult                         // POST /
    func createStudio(link: URL) async throws -> StudioCreated                    // POST /studio
    func upload(file: URL, name: String, contentType: String,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult  // PUT /studio/upload
    func session(_ id: String, wait: Int) async throws -> StudioSession          // GET /studio/<id>?wait=
    func sourceURL(session id: String) -> URL                                     // GET /studio/<id>/source (no key)
    func render(session id: String, _ request: RenderRequest) async throws -> String   // job id
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus
    func publish(session id: String) async throws -> HostedFile                  // POST /studio/<id>/publish
    func publish(item id: String) async throws -> HostedFile                     // POST /library/items/<id>/publish
    func openStudio(item id: String) async throws -> StudioCreated               // POST /library/items/<id>/studio
    func library(cursor: String?, limit: Int) async throws -> LibraryPage        // GET /library
    // One file per rendition, public or private (CONTRACT-VISIBILITY.md 6.1; APP-API-CONTRACT 16). The defaults
    // below forward to the calls above (or say the server cannot), so a client that predates them still compiles.
    /// `POST /studio` with `public` next to `url` (only when the server has `public_default`); nil omits the field.
    func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated
    /// `PUT /studio/upload` with `?public=1` when `makePublic` is true.
    func upload(file: URL, name: String, contentType: String, public makePublic: Bool?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult
    /// `GET /library` with `v=2` when `v2` (only when the server has `features.visibility`): one entry per file.
    func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage
    /// `PATCH /library/items/<id>/visibility {"public"}` (keyed): the file as it is now, and whether the edge cache
    /// was cleared. Idempotent. Throws `.unsupported` on a client or server that cannot.
    func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange
    // The server's line (APP-API-CONTRACT section 17; `features.line`). Defaults forward to the calls above (queue
    // ignored) or say the server cannot, so a client that predates the line still compiles.
    /// `POST /studio` with `queue: true` (the answer says `queued` and `queue_ahead` instead of `429 error.studio.busy`)
    /// and the post's custom `title` (17.3; nil omits both).
    func createStudio(link: URL, public makePublic: Bool?, queue: Bool, title: String?) async throws -> StudioCreated
    /// `POST /library/items/<id>/studio` with `?queue=1` when `queue`.
    func openStudio(item id: String, queue: Bool) async throws -> StudioCreated
    /// `PUT /studio/upload` with `?queue=1` and `?title=` (17.3); an adopted session that had to wait is `queued`.
    func upload(file: URL, name: String, contentType: String, public makePublic: Bool?, queue: Bool, title: String?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult
    /// `DELETE /studio/<id>/line`: cancels a save that has not started. `409 error.studio.started` is `.started`.
    func cancelQueued(session id: String) async throws -> QueueCancel
    /// `DELETE /studio/<id>/render/<job>`: cancels a render that has not started.
    func cancelQueued(session id: String, job: String) async throws -> QueueCancel
    /// `GET /studio/line` (keyed).
    func line() async throws -> ServerLineSnapshot
    /// `PUT /studio/line/notify`: one Hark message when everything this key has in flight is done (17.8). Returns how
    /// many jobs the server watches (0 = nothing in flight, or no notify bridge).
    func setLineNotify() async throws -> Int
    /// `DELETE /studio/line/notify` (idempotent).
    func cancelLineNotify() async throws
    /// `GET /queue` (keyed; APP-API-CONTRACT 23, only when `features.queue`): the line, the search index's backlog and
    /// the posters, in one snapshot for the queue tab. Defaulted below (`.unsupported`) so older fakes compile.
    func queue() async throws -> QueueSnapshot
    func deleteMedia(name: String) async throws                                   // DELETE /media/<name>
    /// `DELETE /library/items/<id>/post` (CONTRACT-MEDIA 6.1), only when `features.delete_post`: deletes
    /// the whole post the file `itemID` belongs to. A partial result is returned, not thrown.
    func deletePost(anchor itemID: String) async throws -> PostDeleteResult
    /// `PATCH /library/items/<id>/post` (CONTRACT-LIBRARY2 4.2), only when `features.titles`: sets (or, with
    /// nil, clears) the custom title of the post the file `itemID` belongs to. The caller sends a title
    /// that `MediaTitle.clean` already accepted.
    func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult
    // Live Activities (APP-API-CONTRACT section 8; keyed; the server never wakes its container for these)
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws   // PUT /live/start-token
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply                // PUT /live/runs/<run>
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws                     // POST /live/runs/<run>/state
    func endLiveRun(_ run: UUID) async throws                                                  // DELETE /live/runs/<run>
    func liveSelftest() async throws -> LiveSelftest                                           // GET /live/selftest
    // Notify bridge (APP-API-CONTRACT section 9; keyed; for a build with no APNs). Defaults do nothing
    // so a client that predates the bridge keeps compiling.
    func setNotify(session id: String, _ optIn: NotifyOptIn) async throws                     // PUT /studio/<id>/notify
    func cancelNotify(session id: String) async throws                                          // DELETE /studio/<id>/notify
    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL
    // Photos and galleries (APP-API-CONTRACT 18.2, 18.4, 18.5, 18.10-18.13; `features.gallery`, `features.gallery_make`).
    // Defaults forward to the calls above or say the server cannot, so a client that predates galleries still compiles.
    /// `POST /studio` with everything `options` carries: `items`, `item_count`, the share sheet's chained `slideshow`
    /// or `gallery_image` (18.12), `origin`, `notify`. Without gallery fields it is the plain create.
    func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated
    /// `POST /studio/<sid>/slideshow` (keyed): a slideshow webp or mp4 of the post's items. `items` are the post's items
    /// as known (their types make the wire's `seconds`: a number for a photo, `null` for a video or gif). `focused`
    /// puts it ahead of every waiting save (`priority: "focused"`, only with the server's line).
    func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool) async throws -> RenderAccepted
    /// `POST /studio/<sid>/gallery-image` (keyed): the borderless gallery image. `plan.items` must be photos.
    func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool) async throws -> RenderAccepted
    /// `GET /studio/<sid>/render/<job>` of a slideshow or gallery-image make: the phase, then the made file's row.
    func makeStatus(session: String, job: String, wait: Int) async throws -> MakeStatus
    /// `POST /studio/<sid>/items/retry` (keyed): fetch only these indices again (a save job in the line).
    func retryItems(session: String, items: [Int]) async throws -> StudioCreated
    /// `DELETE /library/items/<id>` (keyed): one item, slideshow, crop or export. The last item of a post is
    /// `409 error.library.last_item` (use `deletePost`).
    func deleteItem(_ itemID: String) async throws
    /// `PUT /library/items/<id>/made` (keyed, 18.6): a file made on the device from the item `itemID` (a crop: `role .crop`,
    /// an `image/jpeg` body, `spec` the JSON of `made_spec`, at most 512 bytes). The row joins the post and follows its
    /// public/private switch. Nothing changes on the server when it throws.
    func uploadMade(
        item itemID: String, role: GalleryRole, file: URL, contentType: String, name: String, spec: Data,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> MadeUpload
    /// `PATCH /library/items/<id>/visibility {"public", "scope": "post"}` (keyed): the whole post's files at once.
    func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult
    /// `GET /library` with `v=3` when `v3` (only when the server has `features.gallery`): `v=2` plus gallery items,
    /// made files and each post's `kind`.
    func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage
    /// `GET /emotes?q=` (APP-API-CONTRACT section 20). Stores nothing.
    func searchEmotes(query: String) async throws -> [EmoteHit]
    /// `GET /emotes?q=&sort=&page=` (section 20.1): browse a sort, with or without a name.
    func browseEmotes(query: String, sort: EmoteSort, page: Int) async throws -> EmotePage
    /// `POST /emotes` `{id}`. The first save is new; the same id again is the same file.
    func saveEmote(id: String) async throws -> SavedEmote
    /// `GET /library/search?q=&limit=&v=` (APP-API-CONTRACT 21; keyed; only when `features.search`): the posts best
    /// first, each with its `score`. `version` is the `GET /library` shape the posts come in (2 or 3; nil sends none).
    /// Defaulted below (`.unsupported`) so older fakes compile.
    func librarySearch(query: String, limit: Int, version: Int?) async throws -> LibrarySearchResult
    /// `GET /library/search/post?key=` (keyed; only when `features.search`): how one post sits in the search index.
    func librarySearchStatus(postKey: String) async throws -> LibrarySearchStatus
    /// `GET /library/about?key=` (APP-API-CONTRACT 34; keyed; only when `features.about`): the post's sentence, tags,
    /// sound, the words its vector reads closest to and its nearest posts. `404 error.library.not_found` is
    /// `CobaltError.api`. Defaulted below (`.unsupported`) so older fakes compile.
    func libraryAbout(postKey: String) async throws -> LibraryAbout
    /// `PATCH /library/about {key, tags}` (keyed): replaces the owner's tags (nil goes back to the server's own) and
    /// answers the `GET` body. Defaulted below (`.unsupported`).
    func setLibraryAboutTags(postKey: String, tags: [String]?) async throws -> LibraryAbout
    /// `GET /library/map` (APP-API-CONTRACT 21; keyed): every embedded post with its int8 vector, newest first, for the
    /// sky map. Defaulted below (`.unsupported`) so older fakes compile.
    func libraryMap() async throws -> LibraryMap
    // How agents reach the MCP (APP-API-CONTRACT 35.5; keyed). Defaulted below (`.unsupported`) so older fakes compile.
    /// `GET /mcp/settings`: the mode and the live private link's use (never its secret). A server without the route
    /// is `CobaltError.api(code:httpStatus: 404)`.
    func mcpSettings() async throws -> McpSettings
    /// `POST /mcp/settings {mode}`: turning `.private` on answers the new link once (`linkUrl`); leaving it revokes
    /// the link for good.
    func setMcpMode(_ mode: McpSettings.Mode) async throws -> McpChange
    /// `POST /mcp/settings/rotate`: a new private link, the old one stops at once. `409 error.mcp.not_private` outside
    /// `.private`.
    func rotateMcpLink() async throws -> McpChange
    // Gallery share links (APP-API-CONTRACT 24; keyed; only when `features.share_sets`). Defaulted below
    // (`.unsupported`) so older fakes compile.
    /// `POST /share/sets` `{items, title?}`: one link for 2..`share_set_max` public library files, in the order given
    /// (nil `title` omits the field). Throws `ShareSetError` for the server's refusals.
    func createShareSet(items: [String], title: String?) async throws -> ShareSet
    /// `GET /share/sets`: the live sets, newest first.
    func shareSets() async throws -> [ShareSet]
    /// `DELETE /share/sets/<id>`: revokes the link at once. An unknown id is `ShareSetError.notFound`.
    func revokeShareSet(id: String) async throws
    /// `POST /share/sets` `{items, title?, private?}` (APP-API-CONTRACT 36.3): nil `isPrivate` omits the field (the server
    /// uses `new_links`). Private: the files may be any live files, and the answer is already private. Defaulted below:
    /// nil and false fall back to `createShareSet(items:title:)`, true is `.unsupported`.
    func createShareSet(items: [String], title: String?, private isPrivate: Bool?) async throws -> ShareSet
    /// `PATCH /share/sets/<id>` `{items?, title?, expect?}` (APP-API-CONTRACT 41.1; only when `features.share_set_edit`):
    /// the whole new list of files (nil leaves it), the title kept, set or cleared, and the list last seen (nil sends
    /// none). Answers the link as stored. Throws `ShareSetError` (`.changed(set)` when the list moved on, `.hidden(ids)`,
    /// `.notPublic(ids)`, `.badRequest`, `.notFound`). Defaulted below (`.unsupported`) so older fakes compile.
    func updateShareSet(id: String, items: [String]?, title: ShareSetTitleChange, expect: [String]?) async throws -> ShareSet
    // Private share links (APP-API-CONTRACT 36; keyed; only when `features.private_links`). Defaulted below
    // (`.unsupported`) so older fakes compile. All throw `PrivateLinkError` for the server's refusals.
    /// `GET /share/private`: every live private link, newest first, and `new_links`.
    func privateLinks() async throws -> PrivateLinkList
    /// `PUT /share/private/items|sets/<id>`: turns the private link on (a public file goes off first) and answers it;
    /// already on answers the same link.
    func enablePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink
    /// `DELETE /share/private/items|sets/<id>`: the private link stops. A file stays off; a gallery link is public again.
    func revokePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws
    /// `POST /share/private/items|sets/<id>/rotate`: a new key, the old one a 404 at once. `.notFound` when none is live.
    func rotatePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink
    /// `POST /share/private/rotate-all`: every live key rotated in one batch.
    func rotateAllPrivateLinks() async throws -> PrivateLinkRotation
    /// `PATCH /share/private/settings {new_links}`: answers the value now stored.
    func setNewLinks(_ value: NewLinks) async throws -> NewLinks
    /// `POST /share/collections/<id>/privacy`: the private links of the collection's live gallery links after the change
    /// (empty after `.makePublic`). Throws `ShareCollectionError` (`.notFound`, `.badRequest`).
    func setCollectionPrivacy(id: String, _ change: CollectionPrivacy) async throws -> [PrivateLink]
    // Accounts (APP-API-CONTRACT 42; only when `features.accounts`). Defaulted in `HTTPCobaltClient+Account.swift`
    // (`.unsupported`) so older fakes compile. Refusals are `AccountError` (`.codeInvalid`, `.notFound`); a revoked or
    // ended token stays the generic `CobaltError.api(error.api.auth.key.invalid)`.
    /// `POST /auth/exchange {code, verifier, old_key?}` (open, never sends the stored key in the header): the device's token.
    func exchangeSignIn(code: String, verifier: String, oldKey: String?) async throws -> AuthExchange
    /// `GET /auth/me`.
    func accountMe() async throws -> AccountMe
    /// `GET /auth/sessions`: active sessions, most recently used first.
    func accountSessions() async throws -> [AccountSession]
    /// `DELETE /auth/sessions/<id>`: that device is signed out on its next request.
    func deleteAccountSession(id: String) async throws
    /// `POST /auth/signout`: true when the caller was a session (now revoked); a key is never revoked here.
    func signOutSession() async throws -> Bool
    /// `POST /auth/signout-others`: how many other sessions were revoked.
    func signOutOtherSessions() async throws -> Int
    /// `GET /auth/keys`: the keys for tools, newest first.
    func accountKeys() async throws -> [AccountKey]
    /// `DELETE /auth/keys/<id>`: revokes a key (never a session).
    func deleteAccountKey(id: String) async throws
    // Share link collections (APP-API-CONTRACT 26; keyed; only when `features.share_collections`). Defaulted below
    // (`.unsupported`) so older fakes compile. All throw `ShareCollectionError` for the server's refusals.
    /// `GET /share/collections`: the collections, most recently changed first.
    func shareCollections() async throws -> [ShareCollection]
    /// `POST /share/collections` `{name, set_ids?}` (empty `setIDs` omits the field).
    func createShareCollection(name: String, setIDs: [String]) async throws -> ShareCollection
    /// `PATCH /share/collections/<id>` `{name?, add?, remove?}` (a nil name and empty lists are omitted): the
    /// collection as it is now.
    func updateShareCollection(id: String, name: String?, add: [String], remove: [String]) async throws -> ShareCollection
    /// `DELETE /share/collections/<id>`: the folder goes; its links stay live. An unknown id is `.notFound`.
    func deleteShareCollection(id: String) async throws
    /// `POST /share/collections/<id>/reroll` (no body): every live link of the collection is replaced by a new link with
    /// the same files and a fresh title; the old ones are revoked. `.notFound`, `.empty` (no live links), `.unavailable`.
    func rerollShareCollection(id: String) async throws -> ShareCollectionReroll
    // Collection sets (APP-API-CONTRACT 28; keyed; only when `features.share_groups`). Defaulted below (`.unsupported`)
    // so older fakes compile. All throw `CollectionGroupError` for the server's refusals.
    /// `GET /share/groups`: the groups, most recently changed first.
    func collectionGroups() async throws -> [CollectionGroup]
    /// `POST /share/groups` `{name, collection_ids?}` (empty `collectionIDs` omits the field).
    func createCollectionGroup(name: String, collectionIDs: [String]) async throws -> CollectionGroup
    /// `PATCH /share/groups/<id>` `{name?, add?, remove?}` (a nil name and empty lists are omitted): the group as it is
    /// now.
    func updateCollectionGroup(id: String, name: String?, add: [String], remove: [String]) async throws -> CollectionGroup
    /// `DELETE /share/groups/<id>`: the group goes; its collections stay. An unknown id is `.notFound`.
    func deleteCollectionGroup(id: String) async throws
    // Chat (APP-API-CONTRACT 27; keyed; only when `features.chat`). Defaulted below (`.unsupported`) so older fakes
    // compile. The routes throw `ChatError` for the server's refusals.
    /// `GET /chat/threads`: most recently updated first.
    func chatThreads() async throws -> [ChatThread]
    /// `POST /chat/threads` `{title?}`: an empty thread (nil `title` omits the field; it is "new chat" until its first message).
    func createChatThread(title: String?) async throws -> ChatThread
    /// `GET /chat/threads/<id>`: the thread, its messages oldest first, and the library posts they reference.
    func chatThread(id: String) async throws -> ChatThreadDetail
    /// `PATCH /chat/threads/<id>` `{title}`: the thread as it is now. The caller sends a title `ChatRule.cleanTitle` accepted.
    func renameChatThread(id: String, title: String) async throws -> ChatThread
    /// `DELETE /chat/threads/<id>`: the thread and its messages.
    func deleteChatThread(id: String) async throws
    /// `POST /chat/threads/<id>/messages` `{text, post_ids?}` (empty `postIDs` omits the field): the reply as it is
    /// written, event by event (`text/event-stream`). Refusals before the stream (`busy`, `full`, `notFound`, …) finish
    /// the stream with the `ChatError` before any event; a stream that drops later finishes with the transport's error.
    func sendChatMessage(threadID: String, text: String, postIDs: [String]) -> AsyncThrowingStream<ChatEvent, Error>
    /// `GET /chat/threads/<id>/messages/<message id>/collage?offset=&limit=` (27.5): one page of the collage a reply attached.
    /// `limit` is 1...60. `ChatError.notFound` when the message has no collage, `.badRequest` for a bad offset or limit.
    func chatCollage(threadID: String, messageID: String, offset: Int, limit: Int) async throws -> ChatCollagePage
    /// `POST /chat/threads/<id>/confirm/<card id>` `{answer: "yes"|"no"}` (33.5): runs or drops the card's call, then the
    /// reply goes on as a stream like a send's: first a `confirm` event with the card's new status, then a new assistant
    /// message (no `user` event). `ChatError.confirmGone` when the card was answered, expired or replaced.
    func answerChatConfirm(threadID: String, confirmID: String, yes: Bool) -> AsyncThrowingStream<ChatEvent, Error>
    /// `GET /chat/threads/<id>/agents` (43.6): the thread's sub-agents and the last 50 messages between it and them, oldest
    /// first. `ChatError.notFound` for an unknown thread; empty lists on a server before migration 0027.
    func chatAgents(threadID: String) async throws -> ChatAgentList
    /// `POST /chat/threads/<id>/video` (45.1, only when `features.chat_video`) `{shape?, theme?, speed?, from?, to?, notify?}`
    /// (nil fields and a false `notify` are omitted): `202` with the queued render (kind `chat`). Refusals: `ChatError`
    /// (`.busy` while a reply is written, `.videoEmpty`, `.notFound`, `.off`, `.badRequest`), and `EditError.queueFull` /
    /// `EditError.off` for the render queue.
    func makeChatVideo(
        threadID: String, shape: ChatVideoShape?, theme: ChatVideoTheme?, speed: Double?, from: String?, to: String?, notify: Bool
    ) async throws -> EditRender
    // Stage, the studio tab (APP-API-CONTRACT 30.10; keyed; only when `features.stage`). Defaulted below
    // (`.unsupported`) so older fakes compile. The routes throw `StageError` for the server's refusals.
    /// `GET /stage`: the stage and its four rewards. Also retries what Twitch refused earlier.
    func stage() async throws -> StageSnapshot
    /// `PATCH /stage` with the patch's fields (numbers clamped): the stage as it is now.
    func updateStage(_ patch: StagePatch) async throws -> StageSettings
    /// `POST /stage/rotate`: a new OBS token (the old link stops working at once); the stage as it is now.
    func rotateStage() async throws -> StageSettings
    /// `POST /stage/action`: `409 error.stage.off_air` while the stage is off air, `404 error.stage.not_found` for an item
    /// that is not in the pool. The stage as it is now.
    func stageAction(_ action: StageAction) async throws -> StageSettings
    /// `GET /stage/pool?offset=&limit=` (1...100): the spotlight picker's page of the resolved pool.
    func stagePool(offset: Int, limit: Int) async throws -> StagePoolPage
    /// `GET /stage/redemptions?limit=&before=` (1...100): newest first; `before` pages back.
    func stageRedemptions(limit: Int, before: Date?) async throws -> [StageRedemption]
    /// `PATCH /stage/rewards/<action>` `{cost?, cooldown_seconds?, enabled?}` (nil fields are left out): the reward as it is
    /// now (`synced` false when Twitch refused).
    func updateStageReward(_ kind: StageRewardKind, cost: Int?, cooldownSeconds: Int?, enabled: Bool?) async throws -> StageReward
    /// `POST /stage/twitch/connect`: the Twitch authorize URL for an `ASWebAuthenticationSession` with callback scheme
    /// `cobalt-apple`. `404 error.stage.twitch_off` without `features.stage_twitch`.
    func connectStageTwitch() async throws -> URL
    /// `DELETE /stage/twitch`: the EventSub subscription, the rewards on Twitch and the connection go; the stage as it is now.
    func disconnectStageTwitch() async throws -> StageSettings
    // Hidden posts and auto-hide rules (APP-API-CONTRACT 37; keyed; only when `features.hidden`). Defaulted below
    // (`.unsupported`) so older fakes compile. The server's refusals (`error.hidden.bad_rule`, `error.hidden.too_many`,
    // `error.hidden.not_found`, `error.library.bad_request`) are `CobaltError.api(code:httpStatus:)`.
    /// `POST /library/status {ids, status}`: one request for 1...`limits.statusIds` file or post ids (chunking is the
    /// caller's job). The posts that took the status, and the ids that did not (`failed`).
    func setStatus(ids: [String], status: PostStatus) async throws -> StatusChange
    /// `GET /library?hidden=1` (with `v=3`; a server with hidden posts has galleries): only the hidden posts, newest
    /// first, with `hiddenCount`. `postCount` / `fileCount` are those of the library without them.
    func hiddenLibrary(cursor: String?, limit: Int) async throws -> LibraryPage
    /// `GET /hidden/rules`.
    func hiddenRules() async throws -> HiddenRules
    /// `POST /hidden/rules {kind, value, apply}`: the new rule (always enabled) and how many saved posts `apply` hid.
    func createHiddenRule(kind: HiddenRuleKind, value: String, apply: Bool) async throws -> (rule: HideRule, applied: Int)
    /// `POST /hidden/rules/preview {kind, value}`: what the rule would hide now; nothing changes.
    func previewHiddenRule(kind: HiddenRuleKind, value: String) async throws -> HiddenRulePreview
    /// `PATCH /hidden/rules/<id> {enabled?, value?, apply?}` (nil fields are left out).
    func updateHiddenRule(id: String, enabled: Bool?, value: String?, apply: Bool) async throws -> (rule: HideRule, applied: Int)
    /// `DELETE /hidden/rules/<id>`: the posts it hid stay hidden.
    func deleteHiddenRule(id: String) async throws
}

extension CobaltClient {
    public func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated {
        try await createStudio(link: link)
    }
    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, progress: progress)
    }
    public func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit)
    }
    public func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange {
        throw PipelineFailure.unsupported
    }
    public func createStudio(link: URL, public makePublic: Bool?, queue: Bool, title: String?) async throws -> StudioCreated {
        try await createStudio(link: link, public: makePublic)
    }
    public func openStudio(item id: String, queue: Bool) async throws -> StudioCreated {
        try await openStudio(item: id)
    }
    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?, queue: Bool, title: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, public: makePublic, progress: progress)
    }
    public func cancelQueued(session id: String) async throws -> QueueCancel { throw PipelineFailure.unsupported }
    public func cancelQueued(session id: String, job: String) async throws -> QueueCancel { throw PipelineFailure.unsupported }
    public func line() async throws -> ServerLineSnapshot { throw PipelineFailure.unsupported }
    public func setLineNotify() async throws -> Int { 0 }
    public func cancelLineNotify() async throws {}
    public func queue() async throws -> QueueSnapshot { throw PipelineFailure.unsupported }
    public func setNotify(session id: String, _ optIn: NotifyOptIn) async throws {}
    public func cancelNotify(session id: String) async throws {}
    public func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated {
        guard options.isPlain else { throw PipelineFailure.unsupported }
        return try await createStudio(link: url, public: options.makePublic, queue: options.queue, title: options.title)
    }
    public func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool) async throws -> RenderAccepted {
        throw PipelineFailure.unsupported
    }
    public func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool) async throws -> RenderAccepted {
        throw PipelineFailure.unsupported
    }
    public func makeStatus(session: String, job: String, wait: Int) async throws -> MakeStatus { throw PipelineFailure.unsupported }
    public func retryItems(session: String, items: [Int]) async throws -> StudioCreated { throw PipelineFailure.unsupported }
    public func deleteItem(_ itemID: String) async throws { throw PipelineFailure.unsupported }
    public func uploadMade(
        item itemID: String, role: GalleryRole, file: URL, contentType: String, name: String, spec: Data,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> MadeUpload {
        throw PipelineFailure.unsupported
    }
    public func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult {
        throw PipelineFailure.unsupported
    }
    public func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit, v2: v3)
    }
    /// A client that predates the route says the server cannot do it.
    public func deletePost(anchor itemID: String) async throws -> PostDeleteResult { throw PipelineFailure.unsupported }
    public func searchEmotes(query: String) async throws -> [EmoteHit] { throw PipelineFailure.unsupported }
    public func browseEmotes(query: String, sort: EmoteSort, page: Int) async throws -> EmotePage {
        throw PipelineFailure.unsupported
    }
    public func saveEmote(id: String) async throws -> SavedEmote { throw PipelineFailure.unsupported }
    public func librarySearch(query: String, limit: Int, version: Int?) async throws -> LibrarySearchResult {
        throw PipelineFailure.unsupported
    }
    public func librarySearchStatus(postKey: String) async throws -> LibrarySearchStatus { throw PipelineFailure.unsupported }
    public func libraryAbout(postKey: String) async throws -> LibraryAbout { throw PipelineFailure.unsupported }
    public func setLibraryAboutTags(postKey: String, tags: [String]?) async throws -> LibraryAbout { throw PipelineFailure.unsupported }
    public func libraryMap() async throws -> LibraryMap { throw PipelineFailure.unsupported }
    public func mcpSettings() async throws -> McpSettings { throw PipelineFailure.unsupported }
    public func setMcpMode(_ mode: McpSettings.Mode) async throws -> McpChange { throw PipelineFailure.unsupported }
    public func rotateMcpLink() async throws -> McpChange { throw PipelineFailure.unsupported }
    public func createShareSet(items: [String], title: String?) async throws -> ShareSet { throw PipelineFailure.unsupported }
    public func shareSets() async throws -> [ShareSet] { throw PipelineFailure.unsupported }
    public func revokeShareSet(id: String) async throws { throw PipelineFailure.unsupported }
    public func createShareSet(items: [String], title: String?, private isPrivate: Bool?) async throws -> ShareSet {
        guard isPrivate != true else { throw PipelineFailure.unsupported }
        return try await createShareSet(items: items, title: title)
    }
    public func updateShareSet(id: String, items: [String]?, title: ShareSetTitleChange, expect: [String]?) async throws -> ShareSet {
        throw PipelineFailure.unsupported
    }
    public func privateLinks() async throws -> PrivateLinkList { throw PipelineFailure.unsupported }
    public func enablePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink { throw PipelineFailure.unsupported }
    public func revokePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws { throw PipelineFailure.unsupported }
    public func rotatePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink { throw PipelineFailure.unsupported }
    public func rotateAllPrivateLinks() async throws -> PrivateLinkRotation { throw PipelineFailure.unsupported }
    public func setNewLinks(_ value: NewLinks) async throws -> NewLinks { throw PipelineFailure.unsupported }
    public func setCollectionPrivacy(id: String, _ change: CollectionPrivacy) async throws -> [PrivateLink] { throw PipelineFailure.unsupported }
    public func shareCollections() async throws -> [ShareCollection] { throw PipelineFailure.unsupported }
    public func createShareCollection(name: String, setIDs: [String]) async throws -> ShareCollection { throw PipelineFailure.unsupported }
    public func updateShareCollection(id: String, name: String?, add: [String], remove: [String]) async throws -> ShareCollection { throw PipelineFailure.unsupported }
    public func deleteShareCollection(id: String) async throws { throw PipelineFailure.unsupported }
    public func rerollShareCollection(id: String) async throws -> ShareCollectionReroll { throw PipelineFailure.unsupported }
    public func collectionGroups() async throws -> [CollectionGroup] { throw PipelineFailure.unsupported }
    public func createCollectionGroup(name: String, collectionIDs: [String]) async throws -> CollectionGroup { throw PipelineFailure.unsupported }
    public func updateCollectionGroup(id: String, name: String?, add: [String], remove: [String]) async throws -> CollectionGroup { throw PipelineFailure.unsupported }
    public func deleteCollectionGroup(id: String) async throws { throw PipelineFailure.unsupported }
    public func chatThreads() async throws -> [ChatThread] { throw PipelineFailure.unsupported }
    public func createChatThread(title: String?) async throws -> ChatThread { throw PipelineFailure.unsupported }
    public func chatThread(id: String) async throws -> ChatThreadDetail { throw PipelineFailure.unsupported }
    public func renameChatThread(id: String, title: String) async throws -> ChatThread { throw PipelineFailure.unsupported }
    public func deleteChatThread(id: String) async throws { throw PipelineFailure.unsupported }
    public func sendChatMessage(threadID: String, text: String, postIDs: [String]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: PipelineFailure.unsupported) }
    }
    public func chatCollage(threadID: String, messageID: String, offset: Int, limit: Int) async throws -> ChatCollagePage {
        throw PipelineFailure.unsupported
    }
    public func answerChatConfirm(threadID: String, confirmID: String, yes: Bool) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: PipelineFailure.unsupported) }
    }
    public func chatAgents(threadID: String) async throws -> ChatAgentList { throw PipelineFailure.unsupported }
    public func makeChatVideo(
        threadID: String, shape: ChatVideoShape?, theme: ChatVideoTheme?, speed: Double?, from: String?, to: String?, notify: Bool
    ) async throws -> EditRender { throw PipelineFailure.unsupported }
    public func stage() async throws -> StageSnapshot { throw PipelineFailure.unsupported }
    public func updateStage(_ patch: StagePatch) async throws -> StageSettings { throw PipelineFailure.unsupported }
    public func rotateStage() async throws -> StageSettings { throw PipelineFailure.unsupported }
    public func stageAction(_ action: StageAction) async throws -> StageSettings { throw PipelineFailure.unsupported }
    public func stagePool(offset: Int, limit: Int) async throws -> StagePoolPage { throw PipelineFailure.unsupported }
    public func stageRedemptions(limit: Int, before: Date?) async throws -> [StageRedemption] { throw PipelineFailure.unsupported }
    public func updateStageReward(_ kind: StageRewardKind, cost: Int?, cooldownSeconds: Int?, enabled: Bool?) async throws -> StageReward {
        throw PipelineFailure.unsupported
    }
    public func connectStageTwitch() async throws -> URL { throw PipelineFailure.unsupported }
    public func disconnectStageTwitch() async throws -> StageSettings { throw PipelineFailure.unsupported }
    public func setStatus(ids: [String], status: PostStatus) async throws -> StatusChange { throw PipelineFailure.unsupported }
    public func hiddenLibrary(cursor: String?, limit: Int) async throws -> LibraryPage { throw PipelineFailure.unsupported }
    public func hiddenRules() async throws -> HiddenRules { throw PipelineFailure.unsupported }
    public func createHiddenRule(kind: HiddenRuleKind, value: String, apply: Bool) async throws -> (rule: HideRule, applied: Int) {
        throw PipelineFailure.unsupported
    }
    public func previewHiddenRule(kind: HiddenRuleKind, value: String) async throws -> HiddenRulePreview { throw PipelineFailure.unsupported }
    public func updateHiddenRule(id: String, enabled: Bool?, value: String?, apply: Bool) async throws -> (rule: HideRule, applied: Int) {
        throw PipelineFailure.unsupported
    }
    public func deleteHiddenRule(id: String) async throws { throw PipelineFailure.unsupported }
    /// Likewise: a client that predates titles says the server cannot do it.
    public func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
}

extension CobaltClient {
    /// `librarySearch` with the posts in the `GET /library?v=3` shape.
    public func librarySearch(query: String, limit: Int) async throws -> LibrarySearchResult {
        try await librarySearch(query: query, limit: limit, version: 3)
    }
    /// `makeSlideshow` without a Hark opt-in.
    public func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool) async throws -> RenderAccepted {
        try await makeSlideshow(session: session, plan: plan, items: items, focused: focused, notify: false)
    }
    /// `makeGalleryImage` without a Hark opt-in.
    public func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool) async throws -> RenderAccepted {
        try await makeGalleryImage(session: session, plan: plan, focused: focused, notify: false)
    }
}

/// What `PATCH /library/items/<id>/post` answers: `{"status":"success","post":"<post key>","title":"…"|null}`.
public struct PostTitleResult: Sendable, Equatable, Decodable {
    public var post: String
    public var title: String?          // nil = the custom title is cleared

    public init(post: String, title: String?) {
        self.post = post
        self.title = title
    }
}
