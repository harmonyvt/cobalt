import Foundation
import Observation

/// Uploading one library picture as a new 7TV emote (APP-API-CONTRACT 57.9), for the "upload to 7tv" sheet: the name
/// (prefilled from the post's title), private and zero-width, an optional set to add it to, then `POST /7tv/emotes` and
/// `GET /7tv/emotes/<id>` every `pollEvery` seconds until 7TV has processed it (`pending: false`), at most `maxPolls` times.
///
/// Phases: `editing` → `uploading` → `processing` → `done` (with `emote` once read; `timedOut` when 7TV took longer than the
/// polling). A refused upload is `failed` and can be tried again (back to `editing` with `edit()`). A refused add to the set
/// does not fail the upload: `result.addError` says why.
@MainActor @Observable
public final class SevenTvUploadModel: Identifiable {
    public enum Phase: Equatable, Sendable {
        case editing
        case uploading
        case processing
        case done
        case failed(SevenTvError)
    }

    public let fileID: String
    public let bytes: Int64?
    public var name: String
    public var isPrivate = false
    public var zeroWidth = false
    /// Put the new emote in a set too.
    public var addToSet = false
    public private(set) var channelID: String?
    public var setID: String?

    public private(set) var phase: Phase = .editing
    public private(set) var result: SevenTvUploadResult?
    /// The last `GET /7tv/emotes/<id>` answer.
    public private(set) var emote: SevenTvEmoteInfo?
    /// Polling ended with 7TV still processing (the page link still works).
    public private(set) var timedOut = false

    /// Seconds between status reads, and how many reads before giving up (5 s × 24 = 2 minutes).
    @ObservationIgnored public var pollEvery: Double = 5
    @ObservationIgnored public var maxPolls = 24

    @ObservationIgnored private let store: SevenTvStore
    @ObservationIgnored private var token = 0

    init(fileID: String, bytes: Int64?, title: String?, store: SevenTvStore) {
        self.fileID = fileID
        self.bytes = bytes
        self.name = SevenTvEmoteRule.suggestName(from: title)
        self.store = store
    }

    // MARK: reading

    /// The name as it will be sent (spaces around it dropped).
    public var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nameIsValid: Bool { SevenTvEmoteRule.isValidName(cleanName) }
    public var isTooBig: Bool { SevenTvEmoteRule.isTooBig(bytes) }

    /// The channels whose sets the account may change.
    public var channels: [SevenTvChannelInfo] { store.channels.filter { $0.can.manageSets } }
    public var channel: SevenTvChannelInfo? { channelID.flatMap { id in channels.first { $0.id == id } } }
    /// The picked channel's sets (live first).
    public var sets: [SevenTvSetRow] { channelID.map { store.sets(of: $0) } ?? [] }
    public var setsState: SevenTvStore.State { channelID.map { store.setsState(of: $0) } ?? .idle }
    public var pickedSet: SevenTvSetRow? { setID.flatMap { id in sets.first { $0.id == id } } }

    /// Everything the button needs: a valid name, a file 7TV takes, a set when "add to a set" is on.
    public var canUpload: Bool {
        guard nameIsValid, !isTooBig, store.canUpload else { return false }
        switch phase {
        case .editing, .failed: break
        default: return false
        }
        return !addToSet || pickedSet != nil
    }

    /// The set the emote went into, by name, when the answer said it was added.
    public var addedSetName: String? {
        guard let added = result?.added else { return nil }
        if let row = sets.first(where: { $0.id == added.setID }) { return row.name }
        if let channelID, let row = store.sets(of: channelID).first(where: { $0.id == added.setID }) { return row.name }
        return nil
    }

    // MARK: the set

    /// Starts "add to a set" on the first channel (the account's own) when none is picked yet.
    public func prepareSets() async {
        guard channelID == nil else { return }
        let editable = channels
        let selected = store.selectedChannel?.id
        guard let first = editable.first(where: { $0.id == selected }) ?? editable.first else { return }
        await pickChannel(first.id)
    }

    /// A channel's sets (read when not yet), and its live set picked (else its first).
    public func pickChannel(_ id: String) async {
        channelID = id
        setID = nil
        if store.setsState(of: id) != .loaded { await store.loadSets(channelID: id) }
        guard channelID == id, setID == nil else { return }
        let list = store.sets(of: id)
        setID = (list.first { $0.live } ?? list.first)?.id
    }

    // MARK: uploading

    /// `POST /7tv/emotes`, then the polling. Never throws: `phase` says what came of it.
    public func upload() async {
        guard canUpload else { return }
        token += 1
        let mine = token
        let draft = SevenTvUploadDraft(
            fileID: fileID, name: cleanName, zeroWidth: zeroWidth, isPrivate: isPrivate, setID: addToSet ? setID : nil)
        phase = .uploading
        timedOut = false
        emote = nil
        let answer: SevenTvUploadResult
        do {
            answer = try await store.setClient().uploadSevenTvEmote(draft)
        } catch {
            guard mine == token else { return }
            let refusal = SevenTvError.from(error)
            store.note(refusal)
            phase = .failed(refusal)
            return
        }
        guard mine == token else { return }
        result = answer
        if let added = answer.added, let channelID {
            store.bump(setID: added.setID, channelID: channelID, by: 1)
        }
        if let refusal = answer.addError { store.note(refusal) }
        phase = .processing
        await poll(answer, mine: mine)
    }

    /// Reads the emote until 7TV says it is done (at once when the upload already said so). A read that fails is tried
    /// again on the next tick; a dead link stops it.
    private func poll(_ answer: SevenTvUploadResult, mine: Int) async {
        for i in 0..<max(1, maxPolls) {
            if answer.pending || i > 0 {
                do { try await store.sleep(seconds: pollEvery) } catch { return }
            }
            guard mine == token else { return }
            do {
                let info = try await store.setClient().sevenTvEmote(id: answer.emoteID)
                guard mine == token else { return }
                emote = info
                if !info.pending {
                    phase = .done
                    return
                }
            } catch {
                guard mine == token else { return }
                let refusal = SevenTvError.from(error)
                if refusal.needsLink || refusal == .off {
                    store.note(refusal)
                    break
                }
            }
        }
        guard mine == token else { return }
        timedOut = true
        phase = .done
    }

    /// Back to the form after a refusal.
    public func edit() {
        guard case .failed = phase else { return }
        phase = .editing
    }

    /// The sheet closed: nothing more is read (the upload itself, once sent, stands).
    public func stop() {
        token += 1
    }
}

extension SevenTvStore {
    /// An account that can upload: linked, and 7TV has not signed it out.
    public var canUpload: Bool { isLinked && account?.status == .ok }

    /// The "upload to 7tv" sheet's model for one library file.
    public func uploader(fileID: String, bytes: Int64?, title: String?) -> SevenTvUploadModel {
        SevenTvUploadModel(fileID: fileID, bytes: bytes, title: title, store: self)
    }
}
