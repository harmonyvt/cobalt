import Foundation
import Testing
@testable import CobaltKit

// Every emote the 7TV account owns (APP-API-CONTRACT 57.14): `GET /7tv/owned`'s shape (nulls, milliseconds), its route, the kept
// answer when the network is gone, the store's list (loaded, watched while 7TV processes one, refreshed after an upload, cleared on
// unlink, reset and a refusal), and "add to a set…": which channels and sets it offers, the call it makes (the search's add, no
// alias), what it does with a full set, a private emote, a processing one and a name clash.

private let ownedKey = "2d6b9e10-5c3a-4f7e-8a21-9b0c4d7e1f35"

/// The exact shape of 57.14: a processing emote with no pictures, one from the library, one made on 7tv.app (no file, no time).
private let wireOwned = """
{"status":"success","owner_id":"01GB2S2BCR000AHHX5S1Y9TQW2","total":3,"emotes":[
 {"emote_id":"01HV0000000000000000000001","name":"liaSpin","animated":true,"private":false,"zero_width":false,"pending":true,
  "preview_url":null,"file_url":null,"page_url":"https://7tv.app/emotes/01HV0000000000000000000001","file_id":"PrEvIeWitem000013",
  "created_at":1790000120000},
 {"emote_id":"01HV0000000000000000000002","name":"coffeeLoop","animated":true,"private":true,"zero_width":false,"pending":false,
  "preview_url":"https://cdn.7tv.app/emote/01HV0000000000000000000002/2x.webp",
  "file_url":"https://cdn.7tv.app/emote/01HV0000000000000000000002/4x.webp",
  "page_url":"https://7tv.app/emotes/01HV0000000000000000000002","file_id":"PrEvIeWitem000008","created_at":1789000000000},
 {"emote_id":"01HV00000000000000000000A4","name":"ghostHat","animated":false,"private":false,"zero_width":true,"pending":false,
  "preview_url":"https://cdn.7tv.app/emote/01HV00000000000000000000A4/2x.webp","file_url":null,
  "page_url":"https://7tv.app/emotes/01HV00000000000000000000A4","file_id":null,"created_at":null},
 {"name":"no id, dropped"}]}
"""

private func decodeOwned(_ json: String) throws -> SevenTvOwnedList {
    try CobaltJSON.decoder().decode(SevenTvOwnedList.self, from: Data(json.utf8))
}

// MARK: - the shape

struct SevenTvOwnedShapeTests {
    @Test func theAnswerDecodesWithItsNulls() throws {
        let list = try decodeOwned(wireOwned)
        #expect(list.ownerID == "01GB2S2BCR000AHHX5S1Y9TQW2" && list.total == 3)
        #expect(list.emotes.map(\.name) == ["liaSpin", "coffeeLoop", "ghostHat"], "server order kept; a row without an id is dropped")

        let spin = list.emotes[0]
        #expect(spin.pending && spin.animated && !spin.isPrivate && !spin.zeroWidth)
        #expect(spin.previewURL == nil && spin.fileURL == nil, "a processing emote has no pictures yet")
        #expect(spin.fileID == "PrEvIeWitem000013" && spin.fromLibrary)
        #expect(spin.createdAt == Date(timeIntervalSince1970: 1_790_000_120), "created_at is milliseconds")
        #expect(spin.pageURL.absoluteString == "https://7tv.app/emotes/01HV0000000000000000000001")

        let loop = list.emotes[1]
        #expect(loop.isPrivate && !loop.pending && loop.previewURL?.host() == "cdn.7tv.app" && loop.fileURL?.lastPathComponent == "4x.webp")

        let ghost = list.emotes[2]
        #expect(ghost.zeroWidth && !ghost.animated && ghost.fileID == nil && !ghost.fromLibrary)
        #expect(ghost.fileURL == nil && ghost.previewURL != nil && ghost.createdAt == nil)
    }

    @Test func totalCanBeMoreThanTheRowsAndIsNeverLess() throws {
        let past = try decodeOwned(
            #"{"status":"success","owner_id":"x","total":612,"emotes":[{"emote_id":"01HV0000000000000000000001","name":"a"}]}"#)
        #expect(past.total == 612 && past.emotes.count == 1)
        let missing = try decodeOwned(#"{"status":"success","emotes":[{"emote_id":"01HV0000000000000000000001","name":"a"}]}"#)
        #expect(missing.total == 1 && missing.ownerID == nil)
        let low = try decodeOwned(#"{"status":"success","total":0,"emotes":[{"emote_id":"01HV0000000000000000000001","name":"a"}]}"#)
        #expect(low.total == 1)
        let empty = try decodeOwned(#"{"status":"success","owner_id":"x","total":0,"emotes":[]}"#)
        #expect(empty.total == 0 && empty.emotes.isEmpty)
    }

    @Test func anEmoteBecomesASearchHitForTheAddPath() throws {
        let list = try decodeOwned(wireOwned)
        let pending = list.emotes[0].asHit
        #expect(pending.id == "01HV0000000000000000000001" && pending.name == "liaSpin" && pending.animated)
        #expect(pending.previewURL == SevenTvEmoteRule.cdnURL("01HV0000000000000000000001", size: "2x"), "no picture yet: the CDN's name")
        #expect(list.emotes[1].asHit.previewURL == list.emotes[1].previewURL)
    }

    @Test func theRouteIsOneMorePath() {
        #expect(SevenTvRoute.owned == "/7tv/owned")
    }
}

// MARK: - the route

struct SevenTvOwnedHTTPTests {
    @Test func ownedIsAKeyedGetWithoutABody() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/7tv/owned" ? .json(wireOwned) : .init(status: 404)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { ownedKey })
        let list = try await client.sevenTvOwned()
        let req = try #require(server.requests.first)
        #expect(req.method == "GET" && req.path == "/7tv/owned" && req.query.isEmpty && req.body.isEmpty)
        #expect(req.headers["authorization"] == "Api-Key \(ownedKey)")
        #expect(server.requests.count == 1)
        #expect(list.emotes.count == 3 && list.total == 3)
    }

    @Test func aRefusalIsASevenTvError() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.seventv.relink"}}"#, status: 409)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { ownedKey })
        await #expect(throws: SevenTvError.relink) { try await client.sevenTvOwned() }
    }

    @Test func theLastListStandsInWhenTheNetworkIsGone() async throws {
        let host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owned-answers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let up = Flag()
        StubProtocol.install(host: host) { req in
            guard up.isOn else { throw URLError(.notConnectedToInternet) }
            guard req.url?.path == "/7tv/owned" else { return (404, [:], Data()) }
            return (200, [:], Data(wireOwned.utf8))
        }
        var client = HTTPCobaltClient(
            baseURL: URL(string: "https://\(host)")!, apiKey: { ownedKey }, session: StubProtocol.session())
        client.answers = SevenTvAnswerCache(directory: dir)
        #expect(try await client.sevenTvOwned().emotes.count == 3)
        up.set(false)
        let offline = try await client.sevenTvOwned()
        #expect(offline.emotes.map(\.name) == ["liaSpin", "coffeeLoop", "ghostHat"], "the kept answer, like the sets and the status")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool { lock.withLock { on } }
    func set(_ value: Bool) { lock.withLock { on = value } }
}

// MARK: - the store

@MainActor
struct SevenTvOwnedStoreTests {
    private func linkedApp(_ scenario: PreviewScenario = .happy) async -> AppModel {
        let app = AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
        await app.sevenTv.load()
        return app
    }

    private func names(_ app: AppModel) -> [String] { app.sevenTv.owned.map(\.name) }

    @Test func theListLoadsNewestFirstWithBothKindsOfEmote() async throws {
        let app = await linkedApp()
        #expect(app.sevenTv.ownedState == .idle && app.sevenTv.owned.isEmpty)
        await app.sevenTv.loadOwned()
        #expect(app.sevenTv.ownedState == .loaded)
        #expect(names(app) == ["liaSpin", "coffeeSteam", "coffeeLoop", "Clap", "peepoSpin", "catBonk", "ghostHat"])
        #expect(app.sevenTv.ownedTotal == 7)
        let spin = try #require(app.sevenTv.ownedEmote("01HV0000000000000000000001"))
        let loop = try #require(app.sevenTv.ownedEmote("01HV0000000000000000000002"))
        #expect(spin.fileID == "PrEvIeWitem000013" && loop.fileID == "PrEvIeWitem000008", "the two seeded uploads keep their library file")
        #expect(app.sevenTv.owned.filter { $0.fileID == nil }.map(\.name) == ["coffeeSteam", "Clap", "peepoSpin", "catBonk", "ghostHat"])
        #expect(app.sevenTv.owned.filter(\.pending).map(\.name).sorted() == ["coffeeSteam", "liaSpin"])
        #expect(app.sevenTv.ownedEmote("01HV00000000000000000000A3")?.isPrivate == true)
        #expect(app.sevenTv.ownedEmote("01HV00000000000000000000A4")?.zeroWidth == true)
    }

    @Test func aProcessingEmoteIsWatchedUntilItIsDone() async throws {
        let app = await linkedApp()
        await app.sevenTv.loadOwned()
        #expect(app.sevenTv.hasPendingOwned)
        // an upload is done once its own state is read (the upload list's watch does that beside this one); one made on
        // 7tv.app turns done on the next read of the list
        await app.sevenTv.loadUploads()
        await app.sevenTv.readUploadStates()
        await app.sevenTv.watchOwned(every: 0.01, rounds: 5)
        #expect(!app.sevenTv.hasPendingOwned, "the next reads say it is done")
        let steam = try #require(app.sevenTv.ownedEmote("01HV00000000000000000000A1"))
        #expect(steam.previewURL != nil && !steam.pending)
        let preview = try #require(app.ctx.client as? PreviewClient)
        let reads = preview.sevenTvState.calls.filter { $0 == "GET owned" }.count
        #expect(reads >= 2 && reads <= 6)
    }

    @Test func anUploadJoinsTheListAtOnceAndTheListIsReadAgain() async throws {
        let app = await linkedApp()
        await app.sevenTv.loadOwned()
        let before = app.sevenTv.owned.count
        let model = app.sevenTv.uploader(fileID: "PrEvIeWitem000003", bytes: 100_000, title: "dog dance")
        model.pollEvery = 0.01
        await model.upload()
        #expect(model.phase == .done)
        for _ in 0..<100 where app.sevenTv.ownedState == .loading { try await Task.sleep(for: .milliseconds(10)) }
        let made = try #require(app.sevenTv.owned.first)
        #expect(made.name == "dogDance" && made.fileID == "PrEvIeWitem000003" && app.sevenTv.owned.count == before + 1)
        #expect(app.sevenTv.owned.filter { $0.emoteID == made.emoteID }.count == 1, "the server's list has it too, once")
        let preview = try #require(app.ctx.client as? PreviewClient)
        #expect(preview.sevenTvState.calls.filter { $0 == "GET owned" }.count >= 2, "the list was read again after the upload")
    }

    @Test func unlinkingAndAServerChangeClearTheList() async throws {
        let app = await linkedApp()
        await app.sevenTv.loadOwned()
        #expect(!app.sevenTv.owned.isEmpty)
        try await app.sevenTv.unlink()
        #expect(app.sevenTv.owned.isEmpty && app.sevenTv.ownedTotal == 0 && app.sevenTv.ownedState == .idle)

        let other = await linkedApp()
        await other.sevenTv.loadOwned()
        #expect(!other.sevenTv.owned.isEmpty)
        other.sevenTv.reset()
        #expect(other.sevenTv.owned.isEmpty && other.sevenTv.ownedTotal == 0 && other.sevenTv.ownedState == .idle)
    }

    @Test func aRefusalKeepsWhatWasReadAndAnUnlinkedAccountForgetsIt() async throws {
        let failing = await linkedApp(.stageFail)
        await failing.sevenTv.loadOwned()
        #expect(failing.sevenTv.ownedState == .failed(.unavailable) && failing.sevenTv.owned.isEmpty)

        let off = await linkedApp(.stageNotConnected)
        await off.sevenTv.loadOwned()
        #expect(off.sevenTv.ownedState == .failed(.notLinked) && off.sevenTv.owned.isEmpty)

        let unsupported = AppModel.makePreview(.emptyOrbit, timeScale: 0.01, clock: SystemClock())
        await unsupported.sevenTv.loadOwned()
        #expect(unsupported.sevenTv.ownedState == .failed(.off))
    }
}

// MARK: - add to a set

@MainActor
struct SevenTvAddToSetTests {
    private func linkedApp() async -> AppModel {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        await app.sevenTv.load()
        await app.sevenTv.loadOwned()
        return app
    }

    private func pickerFor(_ app: AppModel, _ name: String) throws -> SevenTvAddToSetModel {
        let emote = try #require(app.sevenTv.owned.first { $0.name == name })
        return app.sevenTv.addToSetPicker(for: emote)
    }

    private func row(_ picker: SevenTvAddToSetModel, _ name: String) throws -> SevenTvSetRow {
        try #require(picker.sets.first { $0.name == name })
    }

    @Test func itOffersEveryChannelThatCanChangeSetsAndTheirSets() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "peepoSpin")
        #expect(picker.channels.map(\.name) == ["capybaraharmony", "liacat", "mochi_vt"])
        await picker.prepare()
        #expect(picker.channel?.you == true && picker.sets.map(\.name) == ["main", "christmas", "subathon"], "live first, then by name")
        await picker.pickChannel(try #require(picker.channels.first { $0.name == "mochi_vt" }).id)
        #expect(picker.sets.map(\.name) == ["mochi", "mochi tiny"])
        #expect(app.sevenTv.channels.first { $0.name == "mochi_vt" }?.can.createSets == false, "adding needs manage_sets, not create_sets")
    }

    @Test func aChannelWithoutTheRightIsLeftOut() throws {
        // the wire's own channels (57.5): the own channel here lost `manage_sets`, liacat can edit, a third can only make sets live
        let channels = [
            SevenTvChannelInfo(id: "own", name: "me", you: true, can: SevenTvRights(manageSets: false, createSets: true, makeLive: true)),
            SevenTvChannelInfo(id: "lia", name: "liacat", can: SevenTvRights(manageSets: true, createSets: false, makeLive: false)),
            SevenTvChannelInfo(id: "live", name: "liveonly", can: SevenTvRights(manageSets: false, createSets: false, makeLive: true)),
        ]
        #expect(SevenTvAddToSetModel.editable(channels).map(\.name) == ["liacat"], "adding needs `manage_sets` alone")
        #expect(SevenTvAddToSetModel.editable(channels, privateOnly: true).isEmpty, "a private emote is for the own channel, which cannot be edited")
    }

    @Test func addingIsTheSearchsAddCallAndKeepsTheEmotesOwnName() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "peepoSpin")
        await picker.prepare()
        let christmas = try row(picker, "christmas")
        let preview = try #require(app.ctx.client as? PreviewClient)
        let outcome = await picker.add(to: christmas)
        #expect(outcome == .added(alias: "peepoSpin", setName: "christmas", channelName: "capybaraharmony"))
        #expect(
            preview.sevenTvState.calls.filter { $0.hasPrefix("POST emote") } == ["POST emote 01HV00000000000000000000A2"],
            "one POST /7tv/sets/<id>/emotes for the emote, nothing else is written")
        #expect(!preview.sevenTvState.calls.contains { $0.hasPrefix("GET set \(christmas.id)") }, "the set was not read to add to it")
        // the set has it, first, under its own name, and the count moved
        #expect(try row(picker, "christmas").count == christmas.count + 1)
        let check = app.sevenTv.openSet(christmas.id, channelID: try #require(picker.channelID))
        await check.load()
        #expect(check.all.first?.emoteID == "01HV00000000000000000000A2" && check.all.first?.alias == "peepoSpin")
        // and it is marked, and asked once
        let marked = try row(picker, "christmas")
        #expect(picker.contains(marked) && picker.alias(in: marked) == "peepoSpin")
        #expect(await picker.add(to: marked) == .alreadyIn(setName: "christmas"))
        #expect(preview.sevenTvState.calls.filter { $0.hasPrefix("POST emote") }.count == 1)
    }

    @Test func itStaysOpenForMoreSetsAcrossChannels() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "peepoSpin")
        await picker.prepare()
        let subathon = try row(picker, "subathon")
        guard case .added = await picker.add(to: subathon) else { Issue.record("not added"); return }
        await picker.pickChannel(try #require(picker.channels.first { $0.name == "liacat" }).id)
        let cozy = try row(picker, "lia cozy")
        let outcome = await picker.add(to: cozy)
        #expect(outcome == .added(alias: "peepoSpin", setName: "lia cozy", channelName: "liacat"))
        let preview = try #require(app.ctx.client as? PreviewClient)
        #expect(preview.sevenTvState.calls.filter { $0.hasPrefix("POST emote") }.count == 2)
        #expect(picker.addedAs.count == 2)
    }

    @Test func aFullSetIsNotAddedTo() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "peepoSpin")
        await picker.pickChannel(try #require(picker.channels.first { $0.name == "mochi_vt" }).id)
        let tiny = try row(picker, "mochi tiny")
        let roomy = try row(picker, "mochi")
        #expect(picker.isFull(tiny) && !picker.isFull(roomy))
        let preview = try #require(app.ctx.client as? PreviewClient)
        let outcome = await picker.add(to: tiny)
        guard case .failed = outcome else { Issue.record("a full set took it: \(outcome)"); return }
        #expect(!preview.sevenTvState.calls.contains { $0.hasPrefix("POST emote") }, "no request for a set with no room")
    }

    @Test func aPrivateEmoteOnlyGoesToTheOwnChannel() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "catBonk")
        #expect(picker.isPrivate && picker.channels.map(\.name) == ["capybaraharmony"])
    }

    @Test func aProcessingEmoteCanBeAddedAlready() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "coffeeSteam")
        #expect(picker.pending)
        await picker.prepare()
        let subathon = try row(picker, "subathon")
        let outcome = await picker.add(to: subathon)
        #expect(outcome == .added(alias: "coffeeSteam", setName: "subathon", channelName: "capybaraharmony"))
    }

    @Test func aTakenNameOpensTheClashAndEachWayOutPutsTheEmoteIn() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "Clap")
        await picker.prepare()
        let main = try row(picker, "main")
        let preview = try #require(app.ctx.client as? PreviewClient)
        guard case .clash(let clash) = await picker.add(to: main) else { Issue.record("no clash"); return }
        #expect(clash.alias == "Clap" && clash.setID == main.id && clash.setName == "main")
        #expect(clash.incoming.id == "01HV00000000000000000000A5" && clash.existing?.emoteID == PreviewData.sevenTvEmoteID(3),
                "the holder is read from the set's first page so the sheet can show it")
        #expect(clash.canRenameExisting)
        #expect(!picker.contains(main))

        // another name, through the same set model the clash sheet uses
        let target = try #require(picker.setModel(for: main))
        #expect(try await target.resolve(clash, .addAs("ClapMine")) == nil)
        #expect(picker.contains(main), "the set has it now, so the picker marks it")
        #expect(target.all.first?.alias == "ClapMine" && target.all.first?.emoteID == "01HV00000000000000000000A5")
        #expect(preview.sevenTvState.calls.filter { $0 == "POST emote 01HV00000000000000000000A5" }.count == 2, "the first try, then the name")
    }

    @Test func replacingAndRenamingTheOldOneWorkFromTheSameClash() async throws {
        let app = await linkedApp()
        let picker = try pickerFor(app, "Clap")
        await picker.prepare()
        let main = try row(picker, "main")
        guard case .clash(let clash) = await picker.add(to: main) else { Issue.record("no clash"); return }
        let target = try #require(picker.setModel(for: main))
        let before = target.all.count
        #expect(try await target.resolve(clash, .replace) == nil)
        #expect(target.all.first?.emoteID == "01HV00000000000000000000A5" && target.all.count == before, "the old Clap left, the new one is in")

        // a second picker for the same emote: the set has it already, so there is nothing to clash with
        let again = try pickerFor(app, "Clap")
        await again.prepare()
        let mainAgain = try row(again, "main")
        guard case .alreadyIn = await again.add(to: mainAgain) else { Issue.record("should know it is in"); return }
    }

    @Test func theSameEmoteAlreadyUnderThatNameIsNotAClash() async throws {
        let app = await linkedApp()
        let catJam = EmoteHit(
            id: PreviewData.sevenTvEmoteID(0), name: "catJAM", animated: true,
            previewURL: SevenTvEmoteRule.cdnURL(PreviewData.sevenTvEmoteID(0), size: "2x"),
            fileURL: SevenTvEmoteRule.cdnURL(PreviewData.sevenTvEmoteID(0), size: "4x"))
        let picker = app.sevenTv.addToSetPicker(emote: catJam)
        await picker.prepare()
        let main = try row(picker, "main")
        #expect(await picker.add(to: main) == .alreadyIn(setName: "main"))
        #expect(picker.contains(main))
    }

    @Test func aSetTheUploadPutItInIsMarkedFromTheStart() async throws {
        let app = await linkedApp()
        let model = app.sevenTv.uploader(fileID: "PrEvIeWitem000003", bytes: 100_000, title: "dog dance")
        model.pollEvery = 0.01
        model.addToSet = true
        await model.prepareSets()
        await model.upload()
        let picker = try #require(model.addToSetPicker())
        #expect(picker.emote.name == "dogDance")
        await picker.prepare()
        let main = try row(picker, "main")
        let christmas = try row(picker, "christmas")
        #expect(picker.contains(main) && !picker.contains(christmas))
        #expect(await picker.add(to: main) == .alreadyIn(setName: "main"))
        guard case .added = await picker.add(to: christmas) else { Issue.record("not added"); return }
        #expect(app.sevenTv.uploads.first?.emoteID == picker.emote.id)
    }

    @Test func noPickerBeforeTheUploadAnswered() async throws {
        let app = await linkedApp()
        #expect(app.sevenTv.uploader(fileID: "PrEvIeWitem000003", bytes: nil, title: "x").addToSetPicker() == nil)
    }

    @Test func theTabsSharedSetModelSeesTheAdd() async throws {
        let app = await linkedApp()
        let owned = try #require(app.sevenTv.owned.first { $0.name == "peepoSpin" })
        let own = try #require(app.sevenTv.selectedChannel)
        let christmas = try #require(app.sevenTv.sets(of: own.id).first { $0.name == "christmas" })
        let shared = app.sevenTv.openSet(christmas.id, channelID: own.id)
        await shared.load()
        let before = shared.all.count
        let picker = app.sevenTv.addToSetPicker(for: owned) { _, _ in shared }
        await picker.prepare()
        let target = try row(picker, "christmas")
        guard case .added = await picker.add(to: target) else { Issue.record("not added"); return }
        #expect(shared.all.count == before + 1 && shared.all.first?.alias == "peepoSpin", "an open grid shows it without a reload")
        #expect(shared.memberIDs.contains(owned.emoteID))
    }
}
