import Foundation
import Synchronization

// 7TV accounts in previews (APP-API-CONTRACT 57). Every stage scenario has the routes: `.happy` (and `.stageFail`) is linked
// as capybaraharmony, five days before 7TV's session ends, with three channels: its own (every right), liacat (sets, no live
// switch) and mochi_vt (edits only). `.renditions` is linked but signed out by 7TV (`relink`). `.stageNotConnected` is not
// linked; linking works with any token that looks like one (a token with "bad" in it is refused). Writes behave like the
// routes: a channel's rights are checked, an alias already in the set is refused without `override_conflicts`, a full set
// refuses, 60 emotes a page, `q` filters by alias. Uploads (57.9) are pending on their first `GET /7tv/emotes/<id>`, done
// after; a file id with "missing", "video"/"mp4" or "huge" in it is refused like the server would. The fit (57.10): a crop, a
// size or a file id with "big" in it answers a plausible `fitted` (a 1200 x 1200 source, 48 frames); "tall" is a 1:36 picture
// that needs a crop, "busy" is refused as busy and "broken" as a fit that failed.

extension PreviewData {
    static let sevenTvUserID = "01GB2S2BCR000AHHX5S1Y9TQW2"

    /// Real-looking 7TV emote names for the preview sets.
    static let sevenTvNames = [
        "catJAM", "peepoHey", "BOOBA", "Clap", "monkaS", "ppL", "EZ", "pepeD", "catKISS", "CatTime", "catPls", "catRAVE", "catW",
        "KEKW", "Sadge", "PogU", "OMEGALUL", "widepeepoHappy", "FeelsDankMan", "pepeLaugh", "Wokege", "Aware", "Okayge",
        "modCheck", "BatChest", "xdd", "peepoClap", "NODDERS", "Stare", "Chatting",
    ]

    /// A 26-character id per name (catJAM keeps its real one).
    static func sevenTvEmoteID(_ index: Int) -> String {
        if index == 0 { return "01F6MQ33FG000FFJ97ZB8MWV52" }
        return "01F" + String(format: "%023d", index)
    }

    static func sevenTvCDN(_ id: String, _ size: String) -> URL {
        URL(string: "https://cdn.7tv.app/emote/\(id)/\(size).webp")!
    }

    /// `count` emotes: the names over and over (repeats get a number so every alias is its own). In `main` the second one
    /// is `peepoHey` renamed `liaWave`.
    static func sevenTvEmotes(count: Int, renameSecond: Bool, now: Date) -> [SevenTvSetItem] {
        let names = sevenTvNames
        return (0..<count).map { i in
            let n = i % names.count
            let name = names[n]
            let round = i / names.count
            let id = round == 0 ? sevenTvEmoteID(n) : sevenTvEmoteID(n + round * 100)
            var alias = round == 0 ? name : "\(name)\(round + 1)"
            if renameSecond && i == 1 { alias = "liaWave" }
            return SevenTvSetItem(
                emoteID: id, alias: alias, name: round == 0 ? name : alias, animated: n % 3 != 1,
                previewURL: sevenTvCDN(id, "2x"), fileURL: sevenTvCDN(id, "4x"), addedAt: now.addingTimeInterval(-Double(i) * 3_600))
        }
    }
}

/// What the preview "server" holds for `/7tv`.
final class PreviewSevenTvState: Sendable {
    struct PreviewSet {
        var info: SevenTvSetInfo
        var emotes: [SevenTvSetItem]
    }

    private struct State {
        var seeded = false
        var status = SevenTvStatus.notLinked
        /// Channel id → its sets (in no order; the answers order them).
        var sets: [String: [PreviewSet]] = [:]
        var calls: [String] = []
        var counter = 0
        /// Uploaded emotes (57.9) by id, and how often each was read: the first read says 7TV is still processing it.
        var uploads: [String: SevenTvEmoteInfo] = [:]
        var uploadReads: [String: Int] = [:]
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    /// Seeds once, on the first call, from the scenario.
    func seedIfNeeded(_ scenario: PreviewScenario, now: Date) {
        state.withLock { s in
            guard !s.seeded else { return }
            s.seeded = true
            switch scenario {
            case .stageNotConnected:
                s.status = .notLinked
            case .renditions:
                s.status = SevenTvStatus(linked: true, account: Self.account(now: now, status: .relink), channels: [])
            default:
                s.status = SevenTvStatus(linked: true, account: Self.account(now: now, status: .ok), channels: Self.channels())
            }
            s.sets = Self.sets(now: now)
        }
    }

    private static func account(now: Date, status: SevenTvUser.Status) -> SevenTvUser {
        SevenTvUser(
            id: PreviewData.sevenTvUserID, name: "capybaraharmony",
            avatarURL: URL(string: "https://cdn.7tv.app/user/01GB2S2BCR000AHHX5S1Y9TQW2/av_01HQ0000000000000000000000/3x.webp"),
            linkedAt: now.addingTimeInterval(-25 * 86_400), expiresAt: now.addingTimeInterval(5 * 86_400 + 3_600), status: status)
    }

    private static func channels() -> [SevenTvChannelInfo] {
        [
            SevenTvChannelInfo(
                id: PreviewData.sevenTvUserID, name: "capybaraharmony", you: true, activeSetID: "01HM0000000000000000MAIN01", can: .all),
            SevenTvChannelInfo(
                id: "01GC0000000000000000L1AC4T", name: "liacat", activeSetID: "01HM00000000000000L1AMA1N0",
                can: SevenTvRights(manageSets: true, createSets: true, makeLive: false)),
            SevenTvChannelInfo(
                id: "01GD0000000000000000M0CH1V", name: "mochi_vt", activeSetID: "01HM00000000000000M0CH1000",
                can: SevenTvRights(manageSets: true, createSets: false, makeLive: false)),
        ]
    }

    private static func sets(now: Date) -> [String: [PreviewSet]] {
        func make(_ id: String, _ name: String, _ capacity: Int, _ count: Int, owner: String, live: Bool, rename: Bool = false) -> PreviewSet {
            let emotes = PreviewData.sevenTvEmotes(count: count, renameSecond: rename, now: now)
            return PreviewSet(
                info: SevenTvSetInfo(id: id, name: name, capacity: capacity, count: emotes.count, ownerID: owner, live: live),
                emotes: emotes)
        }
        let me = PreviewData.sevenTvUserID
        return [
            me: [
                make("01HM0000000000000000MAIN01", "main", 500, 310, owner: me, live: true, rename: true),
                make("01HM00000000000000CHR15TM5", "christmas", 500, 92, owner: me, live: false),
                make("01HM00000000000000SUBATH0N", "subathon", 500, 45, owner: me, live: false),
            ],
            "01GC0000000000000000L1AC4T": [
                make("01HM00000000000000L1AMA1N0", "lia main", 1_000, 24, owner: "01GC0000000000000000L1AC4T", live: true),
                make("01HM00000000000000L1AC0ZY0", "lia cozy", 600, 12, owner: "01GC0000000000000000L1AC4T", live: false),
            ],
            "01GD0000000000000000M0CH1V": [
                make("01HM00000000000000M0CH1000", "mochi", 400, 18, owner: "01GD0000000000000000M0CH1V", live: true),
            ],
        ]
    }

    // MARK: reads

    func status() throws -> SevenTvStatus {
        state.withLock { $0.status }
    }

    private static func requireLinked(_ s: State) throws {
        guard s.status.linked else { throw SevenTvError.notLinked }
        if s.status.account?.status == .relink { throw SevenTvError.relink }
    }

    private static func channel(_ s: State, _ id: String) throws -> SevenTvChannelInfo {
        guard let channel = s.status.channels.first(where: { $0.id == id }) else { throw SevenTvError.notFound }
        return channel
    }

    /// The channel and index of a set.
    private static func locate(_ s: State, _ setID: String) throws -> (channel: String, index: Int) {
        for (channel, list) in s.sets {
            if let i = list.firstIndex(where: { $0.info.id == setID }) { return (channel, i) }
        }
        throw SevenTvError.notFound
    }

    func sets(channelID: String) throws -> SevenTvChannelSets {
        try state.withLock { s in
            try Self.requireLinked(s)
            let channel = try Self.channel(s, channelID)
            let rows = (s.sets[channelID] ?? []).map { p in
                SevenTvSetRow(id: p.info.id, name: p.info.name, capacity: p.info.capacity, count: p.emotes.count,
                              live: p.info.id == channel.activeSetID)
            }
            return SevenTvChannelSets(channelID: channelID, activeSetID: channel.activeSetID, sets: SevenTvChannelSets.ordered(rows))
        }
    }

    func page(setID: String, query: String?, page: Int) throws -> SevenTvSetPage {
        try state.withLock { s in
            try Self.requireLinked(s)
            let (channelID, i) = try Self.locate(s, setID)
            let set = s.sets[channelID]![i]
            let live = s.status.channels.first { $0.id == channelID }?.activeSetID == setID
            var info = set.info
            info.count = set.emotes.count
            info.live = live
            let q = query.flatMap(SevenTvRule.cleanFilter)
            let list = q.map { q in set.emotes.filter { $0.alias.localizedCaseInsensitiveContains(q) } } ?? set.emotes
            let size = SevenTvRule.pageSize
            let start = min(list.count, (max(1, page) - 1) * size)
            let end = min(list.count, start + size)
            return SevenTvSetPage(set: info, page: max(1, page), hasMore: end < list.count, emotes: Array(list[start..<end]))
        }
    }

    // MARK: writes

    func link(token: String, now: Date) throws -> SevenTvStatus {
        try state.withLock { s in
            guard SevenTvLink.looksLikeToken(token), !token.lowercased().contains("bad") else { throw SevenTvError.tokenInvalid }
            s.status = SevenTvStatus(linked: true, account: Self.account(now: now, status: .ok), channels: Self.channels())
            s.status.account?.linkedAt = now
            s.status.account?.expiresAt = now.addingTimeInterval(30 * 86_400)
            return s.status
        }
    }

    func unlink() -> SevenTvStatus {
        state.withLock { s in
            s.status = .notLinked
            return s.status
        }
    }

    func createSet(ownerID: String, name: String) throws -> SevenTvSetInfo {
        try state.withLock { s in
            try Self.requireLinked(s)
            let channel = try Self.channel(s, ownerID)
            guard channel.can.createSets else { throw SevenTvError.forbidden("you do not have permission to create emote sets") }
            guard let clean = SevenTvRule.cleanSetName(name) else { throw SevenTvError.rejected("that name won't work") }
            s.counter += 1
            let info = SevenTvSetInfo(
                id: "01HN" + String(format: "%022d", s.counter), name: clean, capacity: 500, count: 0, ownerID: ownerID, live: false)
            s.sets[ownerID, default: []].append(PreviewSet(info: info, emotes: []))
            return info
        }
    }

    func renameSet(id: String, name: String) throws -> SevenTvSetInfo {
        try state.withLock { s in
            try Self.requireLinked(s)
            let (channelID, i) = try Self.locate(s, id)
            guard try Self.channel(s, channelID).can.manageSets else {
                throw SevenTvError.forbidden("you do not have permission to manage this emote set")
            }
            guard let clean = SevenTvRule.cleanSetName(name) else { throw SevenTvError.rejected("that name won't work") }
            s.sets[channelID]![i].info.name = clean
            var info = s.sets[channelID]![i].info
            info.count = s.sets[channelID]![i].emotes.count
            info.live = s.status.channels.first { $0.id == channelID }?.activeSetID == id
            return info
        }
    }

    func add(setID: String, emoteID: String, alias: String?, overrideConflicts: Bool, now: Date) throws -> SevenTvEmoteChange {
        try state.withLock { s in
            try Self.requireLinked(s)
            let (channelID, i) = try Self.locate(s, setID)
            guard try Self.channel(s, channelID).can.manageSets else {
                throw SevenTvError.forbidden("you do not have permission to manage this emote set")
            }
            let names = PreviewData.sevenTvNames
            let known = (0..<names.count).first { PreviewData.sevenTvEmoteID($0) == emoteID }
            let own = known.map { names[$0] } ?? s.uploads[emoteID]?.name ?? "emote"
            let name = alias ?? own
            guard SevenTvRule.cleanAlias(name) != nil else { throw SevenTvError.rejected("that name won't work") }
            var set = s.sets[channelID]![i]
            if let clash = set.emotes.firstIndex(where: { $0.alias == name }) {
                guard overrideConflicts else { throw SevenTvError.rejected("an emote named \(name) is already in this set") }
                set.emotes.remove(at: clash)
            }
            if let capacity = set.info.capacity, set.emotes.count >= capacity {
                throw SevenTvError.rejected("this set is full")
            }
            set.emotes.insert(
                SevenTvSetItem(
                    emoteID: emoteID, alias: name, name: own, animated: true, previewURL: PreviewData.sevenTvCDN(emoteID, "2x"),
                    fileURL: PreviewData.sevenTvCDN(emoteID, "4x"), addedAt: now),
                at: 0)
            s.sets[channelID]![i] = set
            return SevenTvEmoteChange(setID: setID, emoteID: emoteID, alias: name)
        }
    }

    func rename(setID: String, emoteID: String, alias: String, from: String?) throws -> SevenTvEmoteChange {
        try state.withLock { s in
            try Self.requireLinked(s)
            let (channelID, i) = try Self.locate(s, setID)
            guard try Self.channel(s, channelID).can.manageSets else {
                throw SevenTvError.forbidden("you do not have permission to manage this emote set")
            }
            guard SevenTvRule.cleanAlias(alias) != nil else { throw SevenTvError.rejected("that name won't work") }
            var set = s.sets[channelID]![i]
            guard let e = set.emotes.firstIndex(where: { $0.emoteID == emoteID && (from == nil || $0.alias == from) }) else {
                throw SevenTvError.notFound
            }
            if set.emotes.contains(where: { $0.alias == alias }) {
                throw SevenTvError.rejected("an emote named \(alias) is already in this set")
            }
            set.emotes[e].alias = alias
            set.emotes[e].renamed = alias != set.emotes[e].name
            s.sets[channelID]![i] = set
            return SevenTvEmoteChange(setID: setID, emoteID: emoteID, alias: alias)
        }
    }

    func remove(setID: String, emoteID: String, alias: String?) throws -> SevenTvEmoteChange {
        try state.withLock { s in
            try Self.requireLinked(s)
            let (channelID, i) = try Self.locate(s, setID)
            guard try Self.channel(s, channelID).can.manageSets else {
                throw SevenTvError.forbidden("you do not have permission to manage this emote set")
            }
            guard let e = s.sets[channelID]![i].emotes.firstIndex(where: { $0.emoteID == emoteID && (alias == nil || $0.alias == alias) })
            else { throw SevenTvError.notFound }
            s.sets[channelID]![i].emotes.remove(at: e)
            return SevenTvEmoteChange(setID: setID, emoteID: emoteID, alias: nil, removed: true)
        }
    }

    /// `POST /7tv/emotes`: the file must be a picture 7TV takes (preview file ids naming a video are refused), the name must
    /// pass 7TV's rule. With a set the emote is added there; a refused add is `add_error`, the upload still stands.
    func upload(_ draft: SevenTvUploadDraft, now: Date) throws -> SevenTvUploadResult {
        let emoteID = try state.withLock { s in
            try Self.requireLinked(s)
            guard !draft.fileID.isEmpty else { throw SevenTvError.fileNotFound }
            let lower = draft.fileID.lowercased()
            if lower.contains("missing") { throw SevenTvError.fileNotFound }
            if lower.contains("mp4") || lower.contains("video") { throw SevenTvError.fileType }
            if lower.contains("huge") { throw SevenTvError.tooBig }
            if lower.contains("busy") { throw SevenTvError.busy }
            if lower.contains("broken") { throw SevenTvError.fitFailed("could not decode the picture") }
            if lower.contains("tall") {
                let shape = SevenTvEmoteRule.croppedSize(width: 100, height: 3_600, crop: draft.crop)
                if let shape, !SevenTvEmoteRule.shapeFits(width: Double(shape.width), height: Double(shape.height)) {
                    throw SevenTvError.tooLarge
                }
            }
            guard SevenTvEmoteRule.isValidName(draft.name) else { throw SevenTvError.rejected("invalid emote name") }
            s.counter += 1
            let id = "01HU" + String(format: "%022d", s.counter)
            s.uploads[id] = SevenTvEmoteInfo(
                emoteID: id, name: draft.name, ownerID: PreviewData.sevenTvUserID, pending: true, animated: true,
                isPrivate: draft.isPrivate, zeroWidth: draft.zeroWidth, previewURL: PreviewData.sevenTvCDN(PreviewData.sevenTvEmoteID(0), "2x"),
                fileURL: PreviewData.sevenTvCDN(PreviewData.sevenTvEmoteID(0), "4x"))
            return id
        }
        var result = SevenTvUploadResult(
            emoteID: emoteID, name: draft.name, fileID: draft.fileID, pending: true, fitted: Self.fitted(draft))
        if let setID = draft.setID {
            do {
                let change = try add(setID: setID, emoteID: emoteID, alias: draft.alias, overrideConflicts: false, now: now)
                result.added = SevenTvUploadPlacement(setID: setID, alias: change.alias)
            } catch {
                result.addError = SevenTvError.from(error)
            }
        }
        return result
    }

    /// What the fit would send (57.10): nil unless the draft has a crop or a size or the file id says "big". The crop is taken
    /// out of a 1200 x 1200 source ("tall": 100 x 3600), scaled to a longest side of `size` (512 by default, never larger).
    static func fitted(_ draft: SevenTvUploadDraft) -> SevenTvFitResult? {
        let lower = draft.fileID.lowercased()
        guard draft.crop != nil || draft.size != nil || lower.contains("big") || lower.contains("tall") else { return nil }
        let source = lower.contains("tall") ? (width: 100, height: 3_600) : (width: 1_200, height: 1_200)
        guard let box = SevenTvEmoteRule.croppedSize(width: source.width, height: source.height, crop: draft.crop) else { return nil }
        let longest = max(box.width, box.height)
        let target = min(SevenTvEmoteRule.clampSize(draft.size) ?? 512, longest)
        let scale = Double(target) / Double(longest)
        let width = max(1, Int((Double(box.width) * scale).rounded()))
        let height = max(1, Int((Double(box.height) * scale).rounded()))
        let frames = 48
        let bytes = Int64(width * height * frames / 12)
        return SevenTvFitResult(width: width, height: height, frames: frames, bytes: bytes, quality: 82)
    }

    /// `GET /7tv/emotes/<id>`: an upload is pending on its first read, done after; the preview sets' emotes are done.
    func emote(id: String) throws -> SevenTvEmoteInfo {
        try state.withLock { s in
            try Self.requireLinked(s)
            if var info = s.uploads[id] {
                let reads = s.uploadReads[id, default: 0]
                s.uploadReads[id] = reads + 1
                info.pending = reads == 0
                return info
            }
            let names = PreviewData.sevenTvNames
            guard let n = (0..<names.count).first(where: { PreviewData.sevenTvEmoteID($0) == id }) else { throw SevenTvError.notFound }
            return SevenTvEmoteInfo(
                emoteID: id, name: names[n], ownerID: PreviewData.sevenTvUserID, animated: n % 3 != 1,
                previewURL: PreviewData.sevenTvCDN(id, "2x"), fileURL: PreviewData.sevenTvCDN(id, "4x"))
        }
    }

    func makeLive(channelID: String, setID: String?) throws -> SevenTvLiveChange {
        try state.withLock { s in
            try Self.requireLinked(s)
            let channel = try Self.channel(s, channelID)
            guard channel.can.makeLive else { throw SevenTvError.forbidden("you do not have permission to change the active emote set") }
            if let setID {
                guard (s.sets[channelID] ?? []).contains(where: { $0.info.id == setID }) else { throw SevenTvError.notFound }
            }
            if let c = s.status.channels.firstIndex(where: { $0.id == channelID }) { s.status.channels[c].activeSetID = setID }
            return SevenTvLiveChange(channelID: channelID, activeSetID: setID)
        }
    }
}

extension PreviewClient: SevenTvClient {
    /// Every stage scenario has the routes; the others are a server without them.
    private func sevenTvReady(_ call: String) async throws {
        sevenTvState.record(call)
        try await clock.sleep(seconds: 0.2 * timeScale)
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        sevenTvState.seedIfNeeded(scenario, now: clock.now())
    }

    public func sevenTvStatus() async throws -> SevenTvStatus {
        try await sevenTvReady("GET")
        return try sevenTvState.status()
    }

    public func linkSevenTv(token: String) async throws -> SevenTvStatus {
        try await sevenTvReady("POST link")
        return try sevenTvState.link(token: token, now: clock.now())
    }

    public func unlinkSevenTv() async throws -> SevenTvStatus {
        try await sevenTvReady("DELETE")
        return sevenTvState.unlink()
    }

    public func sevenTvSets(channelID: String) async throws -> SevenTvChannelSets {
        try await sevenTvReady("GET sets \(channelID)")
        return try sevenTvState.sets(channelID: channelID)
    }

    public func sevenTvSet(id: String, query: String?, page: Int) async throws -> SevenTvSetPage {
        try await sevenTvReady("GET set \(id) \(page)")
        return try sevenTvState.page(setID: id, query: query, page: page)
    }

    public func createSevenTvSet(ownerID: String, name: String) async throws -> SevenTvSetInfo {
        try await sevenTvReady("POST set")
        return try sevenTvState.createSet(ownerID: ownerID, name: name)
    }

    public func renameSevenTvSet(id: String, name: String) async throws -> SevenTvSetInfo {
        try await sevenTvReady("PATCH set \(id)")
        return try sevenTvState.renameSet(id: id, name: name)
    }

    public func addSevenTvEmote(setID: String, emoteID: String, alias: String?, overrideConflicts: Bool) async throws -> SevenTvEmoteChange {
        try await sevenTvReady("POST emote \(emoteID)")
        return try sevenTvState.add(setID: setID, emoteID: emoteID, alias: alias, overrideConflicts: overrideConflicts, now: clock.now())
    }

    public func renameSevenTvEmote(setID: String, emoteID: String, alias: String, from: String?) async throws -> SevenTvEmoteChange {
        try await sevenTvReady("PATCH emote \(emoteID)")
        return try sevenTvState.rename(setID: setID, emoteID: emoteID, alias: alias, from: from)
    }

    public func removeSevenTvEmote(setID: String, emoteID: String, alias: String?) async throws -> SevenTvEmoteChange {
        try await sevenTvReady("DELETE emote \(emoteID)")
        return try sevenTvState.remove(setID: setID, emoteID: emoteID, alias: alias)
    }

    public func makeSevenTvSetLive(channelID: String, setID: String?) async throws -> SevenTvLiveChange {
        try await sevenTvReady("POST live \(channelID)")
        return try sevenTvState.makeLive(channelID: channelID, setID: setID)
    }

    public func uploadSevenTvEmote(_ draft: SevenTvUploadDraft) async throws -> SevenTvUploadResult {
        try await sevenTvReady("POST upload \(draft.fileID)")
        try await clock.sleep(seconds: 1.0 * timeScale)
        return try sevenTvState.upload(draft, now: clock.now())
    }

    public func sevenTvEmote(id: String) async throws -> SevenTvEmoteInfo {
        try await sevenTvReady("GET emote \(id)")
        return try sevenTvState.emote(id: id)
    }
}
