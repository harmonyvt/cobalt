import Foundation

// "your uploads" of the 7tv tab (APP-API-CONTRACT 57.9, mockup `7tv-tab/` upload screen): the emotes capystore uploaded
// (`GET /7tv/uploads`), each one's state from `GET /7tv/emotes/<id>` (read for the newest few, and again every 5 s while 7TV is
// still processing one), and the library files already on 7TV (the upload grid's "on 7tv" mark). An upload made from the
// sheet joins the list at once (`noteUploaded`), so the mark and the row show before the list is read again.

extension SevenTvStore {
    /// How many of the newest uploads have their state read (and are watched while processing).
    public nonisolated static let watchedUploads = 12

    /// The library file ids already uploaded to 7TV.
    public var uploadedFileIDs: Set<String> { Set(uploads.map(\.fileID).filter { !$0.isEmpty }) }

    /// The newest upload of a library file, if it was uploaded.
    public func upload(forFile fileID: String) -> SevenTvUploadedEmote? {
        uploads.first { $0.fileID == fileID }
    }

    /// Where an upload stands.
    public func state(of upload: SevenTvUploadedEmote) -> SevenTvUploadState {
        if goneUploads.contains(upload.emoteID) { return .gone }
        guard let info = uploadInfo[upload.emoteID] else { return .unknown }
        return info.pending ? .processing : .ready
    }

    /// `GET /7tv/uploads`. A read already running is not doubled; a failure keeps the list that was read.
    public func loadUploads() async {
        guard uploadsState != .loading else { return }
        let started = generation
        uploadsState = .loading
        do {
            let list = try await setClient().sevenTvUploads()
            guard started == generation else { return }
            // an upload this device just made and the list does not have yet stays on top
            let known = Set(list.map(\.emoteID))
            let newest = list.compactMap(\.createdAt).max()
            let fresh = uploads.filter { row in
                guard !known.contains(row.emoteID) else { return false }
                guard let at = row.createdAt, let newest else { return true }
                return at > newest
            }
            uploads = SevenTvUploadList.ordered(fresh + list)
            uploadsState = .loaded
        } catch {
            guard started == generation else { return }
            let refusal = SevenTvError.from(error)
            note(refusal)
            uploadsState = .failed(refusal)
        }
    }

    /// Reads the state of the newest uploads not read yet, and of those 7TV is still processing. A dead link stops it.
    public func readUploadStates(limit: Int = SevenTvStore.watchedUploads) async {
        let started = generation
        let due = uploads.prefix(limit).filter { row in
            !goneUploads.contains(row.emoteID) && (uploadInfo[row.emoteID]?.pending ?? true)
        }
        for row in due {
            guard !Task.isCancelled, started == generation else { return }
            do {
                let info = try await setClient().sevenTvEmote(id: row.emoteID)
                guard started == generation else { return }
                uploadInfo[row.emoteID] = info
            } catch {
                guard started == generation else { return }
                let refusal = SevenTvError.from(error)
                if refusal == .notFound {
                    goneUploads.insert(row.emoteID)
                } else if refusal.needsLink || refusal == .off {
                    note(refusal)
                    return
                }
            }
        }
    }

    /// The newest uploads' states, then again every `every` seconds while 7TV is processing any of them (at most `rounds`
    /// times). Ends when the task is cancelled (the upload screen went away).
    public func watchUploads(every: Double = 5, rounds: Int = 24) async {
        await readUploadStates()
        var round = 0
        while round < rounds, !Task.isCancelled, hasProcessingUploads {
            round += 1
            do { try await sleep(seconds: every) } catch { return }
            guard !Task.isCancelled else { return }
            await readUploadStates()
        }
    }

    /// One of the watched uploads is still processing.
    public var hasProcessingUploads: Bool {
        uploads.prefix(Self.watchedUploads).contains { state(of: $0) == .processing }
    }

    /// An upload the sheet just made (`POST /7tv/emotes`): on top of the list at once.
    func noteUploaded(_ result: SevenTvUploadResult, fileID: String) {
        let row = SevenTvUploadedEmote(
            fileID: result.fileID.isEmpty ? fileID : result.fileID, emoteID: result.emoteID, name: result.name, createdAt: now(),
            setID: result.added?.setID)
        uploads.removeAll { $0.emoteID == row.emoteID }
        uploads.insert(row, at: 0)
        if uploads.count > 100 { uploads.removeLast(uploads.count - 100) }
    }

    /// An emote's state as the sheet's polling read it.
    func noteEmote(_ info: SevenTvEmoteInfo) {
        guard uploads.contains(where: { $0.emoteID == info.emoteID }) else { return }
        uploadInfo[info.emoteID] = info
    }
}
