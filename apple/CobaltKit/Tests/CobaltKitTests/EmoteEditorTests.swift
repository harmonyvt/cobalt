import Foundation
import Testing
@testable import CobaltKit

// The emote editor (APP-API-CONTRACT 71): the make body and answer, the upload body with a draft, the live limits, and the
// editor model's remake loop (debounce, `replace`, keeping the last good draft) on the preview server.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
}

struct EmoteMakeWireTests {
    @Test func theBodyLeavesOutWhatDoesNotApply() throws {
        let bare = SevenTvRoute.emoteMakeBody(EmoteMakeRequest(fileID: "f1"))
        #expect(bare.count == 2 && bare["file"] as? String == "f1" && bare["format"] as? String == "webp")

        let full = SevenTvRoute.emoteMakeBody(EmoteMakeRequest(
            fileID: "v1", crop: ImageCropRect(x: 0.1, y: 0.2, w: 0.5, h: 0.25), stretch: EmoteStretch(w: 1.5, h: 0.72), size: 256,
            format: .gif, quality: 60, fps: 20, start: 17, end: 19.4, bounce: true, frame: 3, replace: "OLD"))
        #expect(full["crop"] as? [String: Double] == ["x": 0.1, "y": 0.2, "w": 0.5, "h": 0.25])
        #expect(full["stretch"] as? [String: Double] == ["w": 1.5, "h": 0.72])
        #expect(full["size"] as? Int == 256 && full["format"] as? String == "gif" && full["quality"] as? Int == 60)
        #expect(full["fps"] as? Int == 20 && full["start"] as? Double == 17 && full["end"] as? Double == 19.4)
        #expect(full["bounce"] as? Bool == true && full["frame"] as? Double == 3 && full["replace"] as? String == "OLD")
        let wire = try #require(HTTPCobaltClient.jsonBody(full))
        #expect((try? JSONSerialization.jsonObject(with: wire)) != nil)
    }

    @Test func wholeCropIdentityStretchAndFalseBounceAreNotSent() {
        let body = SevenTvRoute.emoteMakeBody(EmoteMakeRequest(fileID: "f", crop: .whole, stretch: .identity, bounce: false, replace: ""))
        #expect(body["crop"] == nil && body["stretch"] == nil && body["bounce"] == nil && body["replace"] == nil)
    }

    @Test func rangesAreClamped() {
        let body = SevenTvRoute.emoteMakeBody(EmoteMakeRequest(
            fileID: "f", stretch: EmoteStretch(w: 9, h: 0.01), size: 5_000, quality: 400, fps: 1))
        #expect(body["stretch"] as? [String: Double] == ["w": 4, "h": 0.25])
        #expect(body["size"] as? Int == 1_000 && body["quality"] as? Int == 100 && body["fps"] as? Int == 5)
    }

    @Test func routesAreTheContracts() {
        #expect(SevenTvRoute.emoteMake == "/7tv/emotes/make")
        #expect(SevenTvRoute.draft("AbC_-123") == "/7tv/drafts/AbC%5F%2D123" || SevenTvRoute.draft("AbC_-123").hasPrefix("/7tv/drafts/"))
        #expect(SevenTvRoute.draftSave("x1").hasSuffix("/x1/save"))
    }

    @Test func aDraftUploadSendsDraftInsteadOfFile() {
        let body = SevenTvRoute.uploadBody(SevenTvUploadDraft(
            fileID: "draft:D1", name: "liaSquish", crop: ImageCropRect(x: 0, y: 0, w: 0.5, h: 0.5), size: 256, draftID: "D1"))
        #expect(body["draft"] as? String == "D1" && body["file"] == nil)
        #expect(body["crop"] == nil && body["size"] == nil, "a draft is sent as it is: no fit")
    }

    @Test func theAnswerDecodes() throws {
        let draft = try decode(EmoteDraft.self, """
        {"status":"success","draft_id":"abcdefghijklmnopqrstuv","format":"webp","content_type":"image/webp","width":512,"height":341,
         "frames":48,"duration_ms":2400,"bytes":1800000,"quality":70,"over_cap":false,"url":"/7tv/drafts/abcdefghijklmnopqrstuv",
         "expires_at":1790086400000}
        """)
        #expect(draft.draftID == "abcdefghijklmnopqrstuv" && draft.format == .webp && draft.contentType == "image/webp")
        #expect(draft.width == 512 && draft.height == 341 && draft.frames == 48 && draft.durationMs == 2400)
        #expect(draft.bytes == 1_800_000 && draft.quality == 70 && !draft.overCap && draft.isAnimated)
        #expect(draft.path == "/7tv/drafts/abcdefghijklmnopqrstuv" && draft.expiresAt == Date(timeIntervalSince1970: 1_790_086_400))
        #expect(abs(draft.fps - 20) < 0.01)
    }

    @Test func aStillAndAnOverCapDraftDecode() throws {
        let png = try decode(EmoteDraft.self, """
        {"draft_id":"d","format":"png","width":128.0,"height":128,"frames":1,"duration_ms":0,"bytes":9000,"quality":null,"over_cap":true}
        """)
        #expect(png.format == .png && !png.isAnimated && png.quality == nil && png.overCap && png.width == 128)
        #expect(png.contentType == "image/png" && png.path == "/7tv/drafts/d")
    }

    @Test func theSavedAnswerAndTheNewRefusalsDecode() throws {
        let saved = try decode(EmoteDraftSaved.self, #"{"status":"success","item_id":"i1","file_id":"f1"}"#)
        #expect(saved.itemID == "i1" && saved.fileID == "f1")
        #expect(SevenTvError(code: "error.seventv.draft_not_found") == .draftNotFound)
        #expect(SevenTvError(code: "error.seventv.bad", message: "start") == .bad("start"))
    }
}

struct EmoteRuleTests {
    @Test func shapeLimitsAreOneToThirtyTwoAndThreeToOne() {
        #expect(EmoteLimits.shapeFits(width: 3, height: 1) && EmoteLimits.shapeFits(width: 1, height: 32))
        #expect(!EmoteLimits.shapeFits(width: 3.2, height: 1) && !EmoteLimits.shapeFits(width: 1, height: 33))
        #expect(!EmoteLimits.shapeFits(width: 0, height: 10))
    }

    @Test func theShapeIsCheckedOnTheStretchedCrop() throws {
        let px = try #require(EmoteLimits.stretchedPixels(
            width: 720, height: 360, crop: ImageCropRect(x: 0, y: 0, w: 1, h: 0.5), stretch: EmoteStretch(w: 2, h: 1)))
        #expect(px.width == 1440 && px.height == 180)
        #expect(!EmoteLimits.shapeFits(width: px.width, height: px.height), "8:1 is outside 3:1")
        #expect(EmoteLimits.ratioLabel(width: 720, height: 480) == "3:2")
        #expect(EmoteLimits.ratioLabel(width: 512, height: 256) == "2:1")
    }

    @Test func theOutputNeverGrowsPastTheCrop() {
        let big = EmoteLimits.outputPixels(stretched: (720, 480), size: 512)
        #expect(big.width == 512 && big.height == 341)
        let small = EmoteLimits.outputPixels(stretched: (100, 50), size: 512)
        #expect(small.width == 100 && small.height == 50)
    }

    @Test func sourcesByKind() {
        func source(_ type: String, duration: Double? = nil, bytes: Int64? = nil) -> EmoteSource {
            EmoteSource(fileID: "f", title: "t", contentType: type, duration: duration, bytes: bytes)
        }
        #expect(source("video/mp4").kind == .video && source("video/mp4").hasFrames)
        #expect(source("image/webp").kind == .animated && source("image/gif").kind == .animated)
        #expect(source("image/png").kind == .still && !source("image/png").hasFrames)
        #expect(!source("image/avif").isSupported && !source("image/heic").isSupported)
        #expect(!source("video/mp4", bytes: EmoteSource.maxVideoBytes + 1).isSupported)
        #expect(EmoteSource(fileID: "f", title: nil, fileName: "dance.mp4").isVideo)
    }

    @Test func framesAreEstimatedForAMoment() {
        #expect(EmoteLimits.estimatedFrames(seconds: 2.4, fps: 20, bounce: false) == 48)
        #expect(EmoteLimits.estimatedFrames(seconds: 2.4, fps: 20, bounce: true) == 94)
    }
}

@MainActor
@Suite(.serialized)
struct EmoteEditorModelTests {
    private func editor(
        file: String = "pic.png", type: String = "image/png", width: Int? = 720, height: Int? = 540, delay: Double = 0.05
    ) -> EmoteEditorModel {
        let client = PreviewClient(scenario: .happy, timeScale: 0.01)
        let source = EmoteSource(fileID: file, title: "lia squish", contentType: type, width: width, height: height)
        return EmoteEditorModel(source: source, client: client, delay: delay)
    }

    private func wait(_ what: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if what() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    @Test func theFirstDraftIsMadeAtOnceAndTheFileIsRead() async throws {
        let model = editor()
        model.start()
        try await wait { model.draftData != nil }
        let draft = try #require(model.draft)
        #expect(model.isCurrent && model.canUseDraft && model.error == nil && !model.remaking)
        #expect(draft.width == 512 && draft.height == 384)
        #expect(model.checks.map(\.kind) == [.shape, .pixels, .frames, .bytes] && model.checks.allSatisfy { $0.tone == .ok })
    }

    @Test func changesInARowMakeOneDraftThatReplacesTheLast() async throws {
        let model = editor()
        model.start()
        try await wait { model.draft != nil && model.draftData != nil }
        let first = try #require(model.draft?.draftID)
        let made = PreviewEmoteDrafts.shared.issued
        model.setStretchW(1.2)
        model.setStretchW(1.3)
        model.setStretchH(0.8)
        #expect(!model.isCurrent, "the preview moves at once; the draft is of the old settings")
        try await wait { model.draft?.draftID != first && model.draftData != nil }
        #expect(PreviewEmoteDrafts.shared.issued == made + 1, "0.4 s after the last change, one make")
        #expect(PreviewEmoteDrafts.shared.entry(first) == nil, "`replace` dropped the previous draft")
        #expect(model.isCurrent)
    }

    @Test func aRefusalStaysInlineAndTheLastGoodDraftStays() async throws {
        let model = editor(file: "busy-pic.png")
        model.start()
        try await wait { model.error != nil }
        #expect(model.error == .busy && model.draft == nil && !model.remaking)

        let good = editor()
        good.start()
        try await wait { good.draftData != nil }
        let kept = good.draft
        // the stretched crop would be 12:1: nothing is sent, the tick says so, the draft stays
        good.setStretchW(4)
        good.setStretchH(1)
        good.edit { $0.crop = ImageCropRect(x: 0, y: 0, w: 1, h: 0.4) }
        #expect(good.blocker == .shape && good.checks.first?.tone == .bad)
        try await Task.sleep(for: .milliseconds(200))
        #expect(good.draft == kept && !good.canUseDraft)
    }

    @Test func linkedSquashMovesBothWaysAndPresetsSet() {
        let model = editor()
        model.linked = true
        model.setStretchW(2)
        #expect(model.settings.stretch.w == 2 && model.settings.stretch.h == 2)
        model.linked = false
        model.apply(.squish)
        #expect(model.settings.stretch == EmoteStretch(w: 1, h: 0.72))
        model.apply(.tall)
        #expect(model.settings.stretch == EmoteStretch(w: 0.72, h: 1))
        model.apply(.wide)
        let wide = model.stretchedPixels
        #expect(abs((wide?.width ?? 0) / (wide?.height ?? 1) - 3) < 0.01, "wide 3:1")
        model.apply(.reset)
        #expect(model.settings.stretch.isNone)
    }

    @Test func aVideoSendsItsMomentAndAPngTheStill() {
        let model = editor(file: "video-clip", type: "video/mp4", width: 720, height: 720)
        model.setMoment(start: 17, end: 19.4)
        model.edit { $0.fps = 25; $0.bounce = true }
        let r = model.request()
        #expect(r.start == 17 && r.end == 19.4 && r.fps == 25 && r.bounce && r.frame == nil)
        model.edit { $0.format = .png }
        let still = model.request(replace: "D")
        #expect(still.frame == 17 && still.fps == nil && !still.bounce && still.replace == "D")
        #expect(model.tabs.contains(.frames))
        #expect(!editor().tabs.contains(.frames))
    }

    @Test func fixedQualityIsSentAutoIsNot() {
        let model = editor()
        #expect(model.request().quality == nil)
        model.edit { $0.autoQuality = false; $0.quality = 55 }
        #expect(model.request().quality == 55)
    }

    @Test func undoAndRedoStepThroughSettledSettings() async throws {
        let model = editor()
        model.start()
        try await wait { model.draftData != nil }
        model.edit { $0.format = .gif }
        try await wait { model.isCurrent && model.draft?.format == .gif }
        #expect(model.canUndo)
        model.undo()
        #expect(model.settings.format == .webp && model.canRedo)
        try await wait { model.isCurrent && model.draft?.format == .webp }
        model.redo()
        #expect(model.settings.format == .gif)
    }

    @Test func savingNeedsACurrentDraft() async throws {
        let model = editor()
        await #expect(throws: SevenTvError.self) { try await model.saveToLibrary() }
        model.start()
        try await wait { model.draftData != nil }
        let saved = try await model.saveToLibrary()
        #expect(!saved.itemID.isEmpty)
    }
}
