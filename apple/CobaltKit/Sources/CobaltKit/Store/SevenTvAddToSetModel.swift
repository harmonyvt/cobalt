import Foundation
import Observation

/// "add to a set…" (APP-API-CONTRACT 57.14): one 7TV emote the account owns, put into any set of any channel the account may
/// edit. Behind the 7tv tab's "your emotes on 7tv" rows and the upload sheet's result.
///
/// - `channels`: the channels whose sets the account can manage (`can.manageSets`; the others are left out). A private emote
///   only goes into sets its uploader owns (57.9), so it is offered the account's own channel alone.
/// - `sets`: the picked channel's sets, read when not yet (`store.loadSets`).
/// - `add(to:)` is the same call as the search's "add": `SevenTvSetModel.addChecking` (`POST /7tv/sets/<id>/emotes`, no alias,
///   so the emote keeps its own name). A name the set already has is `Outcome.clash`: the clash sheet resolves it on
///   `setModel(for:)` (another name, rename the one there, or replace it), the same model, so the set's grid and counts follow.
///   The clash is looked at again with the set's first page loaded when the answer did not say who holds the name, and an
///   emote that is the one already there is "already in", not a clash.
/// - A set the emote is in (added here, put there by the upload, or found in the loaded set) is marked and not added twice.
///   A full set is not offered. A pending emote (7TV is still processing it) can be added at once.
@MainActor @Observable
public final class SevenTvAddToSetModel: Identifiable {
    public enum Outcome: Sendable, Equatable {
        /// Added under `alias` (its own name).
        case added(alias: String, setName: String, channelName: String)
        /// The set already had this very emote.
        case alreadyIn(setName: String)
        /// Another emote holds the name: the clash sheet's turn.
        case clash(SevenTvNameClash)
        case failed(SevenTvError)
    }

    public let id = UUID()
    public let emote: EmoteHit
    /// 7TV is still processing it.
    public let pending: Bool
    /// A private emote: own channel only.
    public let isPrivate: Bool
    public private(set) var channelID: String?
    /// The sets this emote went into through this picker, by set id, with the name it got.
    public private(set) var addedAs: [String: String] = [:]
    /// Sets it is known to be in before the picker opened (the upload put it there).
    public private(set) var knownIn: Set<String>
    public private(set) var busy: Set<String> = []

    @ObservationIgnored private let store: SevenTvStore
    @ObservationIgnored private let provider: (@MainActor (String, String) -> SevenTvSetModel)?
    private var models: [String: SevenTvSetModel] = [:]

    init(
        emote: EmoteHit, isPrivate: Bool, pending: Bool, alreadyIn: [String] = [], store: SevenTvStore,
        setModel: (@MainActor (String, String) -> SevenTvSetModel)? = nil
    ) {
        self.emote = emote
        self.isPrivate = isPrivate
        self.pending = pending
        self.knownIn = Set(alreadyIn)
        self.store = store
        self.provider = setModel
    }

    // MARK: reading

    /// The channels offered: where the account may add to sets (and, for a private emote, only its own).
    public var channels: [SevenTvChannelInfo] { Self.editable(store.channels, privateOnly: isPrivate) }

    /// The channels whose sets the account may change (`can.manageSets`); a private emote only its own.
    public static func editable(_ channels: [SevenTvChannelInfo], privateOnly: Bool = false) -> [SevenTvChannelInfo] {
        channels.filter { $0.can.manageSets && (!privateOnly || $0.you) }
    }

    public var channel: SevenTvChannelInfo? { channelID.flatMap { id in channels.first { $0.id == id } } }
    public var sets: [SevenTvSetRow] { channelID.map { store.sets(of: $0) } ?? [] }
    public var setsState: SevenTvStore.State { channelID.map { store.setsState(of: $0) } ?? .idle }

    /// The set has no room left.
    public func isFull(_ row: SevenTvSetRow) -> Bool {
        guard let capacity = row.capacity else { return false }
        return row.count >= capacity
    }

    /// The emote is in the set: added here, put there by the upload, or in the set as far as it is loaded.
    public func contains(_ row: SevenTvSetRow) -> Bool {
        addedAs[row.id] != nil || knownIn.contains(row.id) || models[row.id]?.memberIDs.contains(emote.id) == true
    }

    /// The name it has in the set, when this picker put it there.
    public func alias(in row: SevenTvSetRow) -> String? { addedAs[row.id] }

    public func isBusy(_ row: SevenTvSetRow) -> Bool { busy.contains(row.id) }

    // MARK: channels

    /// Picks the channel the tab has open when it can be edited (else the first one that can) and reads its sets.
    public func prepare() async {
        guard channelID == nil else { return }
        let editable = channels
        let selected = store.selectedChannel?.id
        guard let first = editable.first(where: { $0.id == selected }) ?? editable.first else { return }
        await pickChannel(first.id)
    }

    /// A channel's sets, read when not yet.
    public func pickChannel(_ id: String) async {
        channelID = id
        if store.setsState(of: id) != .loaded { await store.loadSets(channelID: id) }
    }

    /// Reads the picked channel's sets again (after a failure).
    public func reloadSets() async {
        guard let channelID else { return }
        await store.loadSets(channelID: channelID)
    }

    // MARK: adding

    /// The set's model: the tab's shared one when it gave a provider, else the store's own. Cached for this picker.
    public func setModel(for row: SevenTvSetRow, channelID: String? = nil) -> SevenTvSetModel? {
        guard let channelID = channelID ?? self.channelID else { return nil }
        if let made = models[row.id], made.channelID == channelID { return made }
        let made = provider?(row.id, channelID) ?? store.openSet(row.id, channelID: channelID)
        models[row.id] = made
        return made
    }

    /// `POST /7tv/sets/<id>/emotes {emote_id}` into this set. Never throws: the outcome says what came of it. A set that is
    /// full, or that has the emote, asks nothing.
    public func add(to row: SevenTvSetRow) async -> Outcome {
        guard let channel, let target = setModel(for: row) else { return .failed(.other) }
        if contains(row) { return .alreadyIn(setName: row.name) }
        guard !isFull(row) else { return .failed(.rejected(nil)) }
        guard !busy.contains(row.id) else { return .failed(.other) }
        busy.insert(row.id)
        defer { busy.remove(row.id) }
        do {
            if let clash = try await target.addChecking(emote, alias: nil) {
                return await settle(clash, in: target, row: row)
            }
            addedAs[row.id] = emote.name
            return .added(alias: emote.name, setName: row.name, channelName: channel.name)
        } catch {
            return .failed(SevenTvError.from(error))
        }
    }

    /// A clash whose holder is unknown looks at the set's first page; the emote already being there is not a clash.
    private func settle(_ clash: SevenTvNameClash, in target: SevenTvSetModel, row: SevenTvSetRow) async -> Outcome {
        var found = clash
        if found.existing == nil, target.state != .loaded {
            await target.load()
            if let local = target.localClash(adding: emote, alias: clash.alias) {
                found = local
            }
        }
        if found.existingEmoteID == emote.id {
            addedAs[row.id] = found.alias
            return .alreadyIn(setName: row.name)
        }
        return .clash(found)
    }
}

extension SevenTvStore {
    /// "add to a set…" for an emote the account owns (57.14). `setModel`: the tab's shared set models, so an open set's grid
    /// shows the add; nil uses a model of its own.
    public func addToSetPicker(
        emote: EmoteHit, isPrivate: Bool = false, pending: Bool = false, alreadyIn: [String] = [],
        setModel: (@MainActor (String, String) -> SevenTvSetModel)? = nil
    ) -> SevenTvAddToSetModel {
        SevenTvAddToSetModel(
            emote: emote, isPrivate: isPrivate, pending: pending, alreadyIn: alreadyIn, store: self, setModel: setModel)
    }

    /// "add to a set…" on a row of "your emotes on 7tv". A set the upload put it in is marked from the start.
    public func addToSetPicker(
        for owned: SevenTvOwnedEmote, setModel: (@MainActor (String, String) -> SevenTvSetModel)? = nil
    ) -> SevenTvAddToSetModel {
        let uploadedInto = uploads.first { $0.emoteID == owned.emoteID }?.setID
        return addToSetPicker(
            emote: owned.asHit, isPrivate: owned.isPrivate, pending: owned.pending, alreadyIn: uploadedInto.map { [$0] } ?? [],
            setModel: setModel)
    }
}
