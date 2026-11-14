import Foundation
import Observation

/// 7TV accounts (APP-API-CONTRACT 57): the linked account, the channels it can edit and each channel's sets, for the studio
/// tab's 7TV card. `openSet(_:channelID:)` gives the set screen its own model (`SevenTvSetModel`), whose edits come back here
/// so the card's counts stay right.
///
/// - `load()` reads `GET /7tv`; a server without the routes is `.failed(.off)` (the card hides itself).
/// - `link(token:)` never throws: what came of it is `linkOutcome` (the card says it once, then calls `acknowledge`). The
///   bookmarklet's `cobalt-apple://7tv-link` arrives through `AppModel.openSevenTvLink`.
/// - Any call 7TV answers with a dead session puts the account in `relink` (the amber line); `not_linked` forgets it.
///
/// Reads the app model's current client on every call; `reset()` (a new server) forgets everything.
@MainActor @Observable
public final class SevenTvStore {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(SevenTvError)
    }

    /// What came of a link (the sheet's button or the bookmarklet). Observe `id` to say it once.
    public struct LinkOutcome: Equatable, Sendable, Identifiable {
        public enum Result: Equatable, Sendable {
            /// Linked as this 7TV name.
            case linked(String)
            case failed(SevenTvError)
        }

        public let id: Int
        public let result: Result
    }

    public private(set) var status: SevenTvStatus?
    public private(set) var state: State = .idle
    /// The channel whose sets the card shows (nil: the first, the account's own).
    public var selectedChannelID: String?
    /// Each channel's sets once read, by channel id.
    public private(set) var channelSets: [String: SevenTvChannelSets] = [:]
    public private(set) var setsState: [String: State] = [:]
    /// A link is being checked with 7TV.
    public private(set) var linking = false
    public private(set) var linkOutcome: LinkOutcome?
    /// The last outcome the card has said (`acknowledge`).
    public private(set) var acknowledgedOutcome = 0
    /// What capystore uploaded to 7TV (`GET /7tv/uploads`, newest first; `SevenTvStore+Uploads.swift`).
    public internal(set) var uploads: [SevenTvUploadedEmote] = []
    public internal(set) var uploadsState: State = .idle
    /// `GET /7tv/emotes/<id>` of each upload read so far, by emote id (whether 7TV is still processing it, its picture).
    public internal(set) var uploadInfo: [String: SevenTvEmoteInfo] = [:]
    /// Uploads 7TV answered 404 for.
    public internal(set) var goneUploads: Set<String> = []

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`: an answer from the old server arriving later is dropped.
    @ObservationIgnored var generation = 0
    @ObservationIgnored private var outcomeCounter = 0

    init(context: PipelineContext) {
        self.ctx = context
    }

    private var client: (any SevenTvClient)? { ctx.client as? any SevenTvClient }

    private func requireClient() throws -> any SevenTvClient {
        guard let client else { throw SevenTvError.off }
        return client
    }

    /// Now, on the context's clock (the preview's clock in previews).
    public func now() -> Date { ctx.clock.now() }

    // MARK: what the card reads

    public var isLinked: Bool { status?.linked == true }
    public var account: SevenTvUser? { status?.account }
    public var channels: [SevenTvChannelInfo] { status?.channels ?? [] }

    /// The picked channel, else the first (the account's own).
    public var selectedChannel: SevenTvChannelInfo? {
        if let id = selectedChannelID, let channel = channels.first(where: { $0.id == id }) { return channel }
        return channels.first
    }

    public func channel(_ id: String) -> SevenTvChannelInfo? { channels.first { $0.id == id } }

    public func sets(of channelID: String) -> [SevenTvSetRow] { channelSets[channelID]?.sets ?? [] }

    public func setsState(of channelID: String) -> State { setsState[channelID] ?? .idle }

    /// The outcome the card has not said yet.
    public var unsaidOutcome: LinkOutcome? {
        guard let linkOutcome, linkOutcome.id > acknowledgedOutcome else { return nil }
        return linkOutcome
    }

    public func acknowledge(_ outcome: LinkOutcome) {
        acknowledgedOutcome = max(acknowledgedOutcome, outcome.id)
    }

    // MARK: loading

    /// `GET /7tv`, then the picked channel's sets. A load already running is not doubled; a failure keeps what was loaded.
    public func load() async {
        guard state != .loading else { return }
        let started = generation
        state = .loading
        do {
            let answer = try await requireClient().sevenTvStatus()
            guard started == generation else { return }
            adopt(answer)
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(SevenTvError.from(error))
            return
        }
        if let channel = selectedChannel { await loadSets(channelID: channel.id) }
    }

    /// `GET /7tv/channels/<id>/sets`.
    public func loadSets(channelID: String) async {
        guard setsState[channelID] != .loading else { return }
        let started = generation
        setsState[channelID] = .loading
        do {
            let answer = try await requireClient().sevenTvSets(channelID: channelID)
            guard started == generation else { return }
            channelSets[channelID] = SevenTvChannelSets(
                channelID: channelID, activeSetID: answer.activeSetID, sets: SevenTvChannelSets.ordered(answer.sets))
            setsState[channelID] = .loaded
        } catch {
            guard started == generation else { return }
            let refusal = SevenTvError.from(error)
            note(refusal)
            setsState[channelID] = .failed(refusal)
        }
    }

    /// Picks a channel chip and reads its sets (again).
    public func select(channelID: String) async {
        selectedChannelID = channelID
        await loadSets(channelID: channelID)
    }

    private func adopt(_ answer: SevenTvStatus) {
        status = answer
        let ids = Set(answer.channels.map(\.id))
        channelSets = channelSets.filter { ids.contains($0.key) }
        setsState = setsState.filter { ids.contains($0.key) }
        if let id = selectedChannelID, !ids.contains(id) { selectedChannelID = nil }
    }

    /// A refusal that says the link is gone shows on the card at once.
    func note(_ refusal: SevenTvError) {
        switch refusal {
        case .relink:
            guard var current = status, current.linked else { return }
            current.account?.status = .relink
            current.channels = []
            status = current
            channelSets = [:]
            setsState = [:]
        case .notLinked:
            status = .notLinked
            channelSets = [:]
            setsState = [:]
            forgetUploads()
        default:
            break
        }
    }

    // MARK: linking

    /// `POST /7tv/link`. A token that cannot be one is refused here, without a request. Never throws: `linkOutcome` says it.
    @discardableResult
    public func link(token raw: String) async -> LinkOutcome.Result {
        let token = SevenTvLink.clean(raw)
        guard SevenTvLink.looksLikeToken(token) else { return finishLink(.failed(.tokenInvalid)) }
        guard !linking else { return .failed(.other) }
        let started = generation
        linking = true
        defer { if started == generation { linking = false } }
        do {
            let answer = try await requireClient().linkSevenTv(token: token)
            guard started == generation else { return .failed(.other) }
            adopt(answer)
            state = .loaded
            selectedChannelID = nil
            if let channel = selectedChannel {
                Task { await self.loadSets(channelID: channel.id) }
            }
            return finishLink(.linked(answer.account?.name ?? ""))
        } catch {
            guard started == generation else { return .failed(.other) }
            return finishLink(.failed(SevenTvError.from(error)))
        }
    }

    private func finishLink(_ result: LinkOutcome.Result) -> LinkOutcome.Result {
        outcomeCounter += 1
        linkOutcome = LinkOutcome(id: outcomeCounter, result: result)
        return result
    }

    /// `DELETE /7tv`. 7TV's own session stays until it ends or the owner logs out on 7tv.app.
    public func unlink() async throws {
        let started = generation
        let answer = try await requireClient().unlinkSevenTv()
        guard started == generation else { return }
        adopt(answer.linked ? .notLinked : answer)
        channelSets = [:]
        setsState = [:]
        selectedChannelID = nil
        forgetUploads()
    }

    // MARK: sets

    /// `POST /7tv/channels/<id>/live`: the set goes live (nil clears it); the list moves it first.
    public func makeLive(channelID: String, setID: String?) async throws {
        let started = generation
        do {
            let answer = try await requireClient().makeSevenTvSetLive(channelID: channelID, setID: setID)
            guard started == generation else { return }
            applyLive(channelID: channelID, activeSetID: setID == nil ? nil : (answer.activeSetID ?? setID))
        } catch {
            note(SevenTvError.from(error))
            throw error
        }
    }

    private func applyLive(channelID: String, activeSetID: String?) {
        if var list = channelSets[channelID] {
            list.activeSetID = activeSetID
            list.sets = SevenTvChannelSets.ordered(list.sets.map { s in
                var s = s
                s.live = s.id == activeSetID
                return s
            })
            channelSets[channelID] = list
        }
        if var current = status, let i = current.channels.firstIndex(where: { $0.id == channelID }) {
            current.channels[i].activeSetID = activeSetID
            status = current
        }
    }

    /// `POST /7tv/sets`: a new, empty set in this channel. The name must pass `SevenTvRule.cleanSetName`.
    @discardableResult
    public func createSet(channelID: String, name raw: String) async throws -> SevenTvSetInfo {
        guard let name = SevenTvRule.cleanSetName(raw) else { throw SevenTvError.rejected(nil) }
        let started = generation
        do {
            let set = try await requireClient().createSevenTvSet(ownerID: channelID, name: name)
            if started == generation { adopt(set: set, channelID: channelID) }
            return set
        } catch {
            note(SevenTvError.from(error))
            throw error
        }
    }

    /// A set as a write answered it: its row in the channel's list is replaced (or added).
    func adopt(set: SevenTvSetInfo, channelID: String) {
        var list = channelSets[channelID] ?? SevenTvChannelSets(channelID: channelID, activeSetID: nil, sets: [])
        var summary = set.summary
        summary.live = set.live || list.activeSetID == set.id
        if let i = list.sets.firstIndex(where: { $0.id == set.id }) {
            list.sets[i] = summary
        } else {
            list.sets.append(summary)
        }
        list.sets = SevenTvChannelSets.ordered(list.sets)
        channelSets[channelID] = list
    }

    /// The count of a set the set screen changed from elsewhere (a copy into another set).
    func bump(setID: String, channelID: String, by delta: Int) {
        guard var list = channelSets[channelID], let i = list.sets.firstIndex(where: { $0.id == setID }) else { return }
        list.sets[i].count = max(0, list.sets[i].count + delta)
        channelSets[channelID] = list
    }

    /// The set screen's model for one set of one channel.
    public func openSet(_ setID: String, channelID: String) -> SevenTvSetModel {
        SevenTvSetModel(setID: setID, channelID: channelID, store: self)
    }

    /// The client, for the set screen's model.
    func setClient() throws -> any SevenTvClient { try requireClient() }

    /// A pause on the context's clock (the upload's polling; virtual in tests and previews).
    func sleep(seconds: Double) async throws { try await ctx.clock.sleep(seconds: seconds) }

    // MARK: server change

    /// A new server: nothing from the old one is kept.
    func reset() {
        generation += 1
        status = nil
        state = .idle
        selectedChannelID = nil
        channelSets = [:]
        setsState = [:]
        linking = false
        forgetUploads()
    }

    func forgetUploads() {
        uploads = []
        uploadsState = .idle
        uploadInfo = [:]
        goneUploads = []
    }
}
