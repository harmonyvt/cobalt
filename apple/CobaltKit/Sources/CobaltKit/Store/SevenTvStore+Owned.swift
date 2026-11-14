import Foundation

// "your emotes on 7tv" (APP-API-CONTRACT 57.14): `GET /7tv/owned`, read when the upload part of the 7tv tab shows and again after
// an upload. An emote 7TV is still processing is watched like the upload list's (every 5 s, at most 24 times). An upload made
// from the sheet joins the list at once (`noteUploaded`), so it shows before the server's list has it.

extension SevenTvStore {
    /// An owned emote by id.
    public func ownedEmote(_ emoteID: String) -> SevenTvOwnedEmote? { owned.first { $0.emoteID == emoteID } }

    /// 7TV is still processing at least one emote of the list.
    public var hasPendingOwned: Bool { owned.contains { $0.pending } }

    /// `GET /7tv/owned`. A read already running is not doubled; a failure keeps the list that was read.
    public func loadOwned() async {
        guard ownedState != .loading else { return }
        let started = generation
        ownedState = .loading
        do {
            let answer = try await setClient().sevenTvOwned()
            guard started == generation else { return }
            // an upload this device just made that the answer does not have yet stays on top
            let known = Set(answer.emotes.map(\.emoteID))
            let newest = answer.emotes.compactMap(\.createdAt).max()
            let fresh = owned.filter { row in
                guard !known.contains(row.emoteID) else { return false }
                guard let at = row.createdAt, let newest else { return true }
                return at > newest
            }
            owned = fresh + answer.emotes
            ownedTotal = max(answer.total + fresh.count, owned.count)
            ownedState = .loaded
        } catch {
            guard started == generation else { return }
            let refusal = SevenTvError.from(error)
            note(refusal)
            ownedState = .failed(refusal)
        }
    }

    /// Reads the list again every `every` seconds while 7TV is processing any emote (at most `rounds` times). Ends when the
    /// task is cancelled (the upload screen went away).
    public func watchOwned(every: Double = 5, rounds: Int = 24) async {
        var round = 0
        while round < rounds, !Task.isCancelled, hasPendingOwned {
            round += 1
            do { try await sleep(seconds: every) } catch { return }
            guard !Task.isCancelled else { return }
            await loadOwned()
        }
    }

    /// An upload the sheet just made: on top of "your emotes on 7tv" at once, then the list is read again.
    func noteOwnedUploaded(_ result: SevenTvUploadResult, fileID: String) {
        let row = SevenTvOwnedEmote(
            emoteID: result.emoteID, name: result.name, pending: result.pending,
            fileID: result.fileID.isEmpty ? fileID : result.fileID, createdAt: now())
        owned.removeAll { $0.emoteID == row.emoteID }
        owned.insert(row, at: 0)
        ownedTotal = max(ownedTotal + 1, owned.count)
        Task { [weak self] in await self?.loadOwned() }
    }
}
