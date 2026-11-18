import Foundation
import Testing
@testable import CobaltKit

// Effects and the raised overlay limits. `key` stays the wire field (APP-API-CONTRACT 66). `hidden` is sent only as
// `true`. Limits follow the server and fall back to 1 layer / 50 clips when the keys are absent (an older server
// refuses `track`); the old ceilings 8 and 50 are what `EditValidation.check` uses when it is not given a limit.

private let story = EditCanvas(w: 1080, h: 1920, fps: 30)

private func clip() -> EditClip { EditClip(id: "cAAAAAAAA", item: PreviewEditorIDs.pier, in: 0, out: 10) }

private func overlay(hidden: Bool = false, key: EditChromaKey? = nil, background: EditOverlayBackground? = nil) -> EditOverlay {
    EditOverlay(
        id: "cO0000001", item: PreviewEditorIDs.surf, at: 1, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3),
        hidden: hidden, key: key, background: background)
}

private func timeline(_ overlay: EditOverlay, output: EditKeyedOutput? = nil) -> EditTimeline {
    EditTimeline(canvas: story, main: [clip()], overlay: [overlay], output: output)
}

struct EditEffectsMappingTests {
    @Test func aGreenscreenEffectBecomesTheKeyAndNothingElseDoes() {
        let key = EditChromaKey(color: "#00b140", similarity: 0.2, blend: 0.05, spill: 0.4)
        let effects = [EditEffect.greenscreen(key), EditEffect(kind: .person), EditEffect(kind: .removeBackground)]
        let mapped = EditEffects.chromaKey(in: effects)
        #expect(mapped?.color == "#00B140")
        #expect(mapped?.similarity == 0.2)
        #expect(mapped?.blend == 0.05)
        #expect(mapped?.spill == 0.4)
        #expect(EditEffects.chromaKey(in: [EditEffect(kind: .subject)]) == nil)
        #expect(EditEffects.list(key: mapped).map(\.kind) == [.greenscreen])
    }

    @Test func theKeyIsOnTheWireAndAbsentWhenThereIsNoEffect() throws {
        let key = EditChromaKey(color: "#00B140", similarity: 0.2, blend: 0.05, spill: 0.4)
        let with = try EditJSON.encode(timeline(overlay(key: key)))
        let text = String(decoding: with, as: UTF8.self)
        #expect(text.contains("\"key\""))
        #expect(text.contains("\"color\":\"#00B140\""))
        #expect(text.contains("\"similarity\""))
        #expect(text.contains("\"blend\""))
        #expect(text.contains("\"spill\""))
        let back = try EditJSON.decode(with)
        let stored = try #require(back.overlay.first?.key)
        #expect(stored.color == "#00B140")
        #expect(abs(stored.similarity - 0.2) < 0.001)
        #expect(abs(stored.blend - 0.05) < 0.001)
        #expect(abs(stored.spill - 0.4) < 0.001)

        let plain = String(decoding: try EditJSON.encode(timeline(overlay())), as: UTF8.self)
        #expect(!plain.contains("\"key\""))
        #expect(!plain.contains("\"background\""))
        #expect(!plain.contains("\"output\""))
    }

    @Test func backgroundAndOutputAreOmittedAtTheirDefaults() throws {
        let keyed = overlay(key: EditChromaKey(), background: .color("#0047BB"))
        var t = timeline(keyed, output: .webm)
        let text = String(decoding: try EditJSON.encode(t), as: UTF8.self)
        #expect(text.contains("\"type\":\"color\""))
        #expect(text.contains("\"color\":\"#0047BB\""))
        #expect(text.contains("\"output\":\"webm\""))
        t.output = .mp4
        t.overlay[0].background = .blur
        let defaults = String(decoding: try EditJSON.encode(EditJSON.rounded(t)), as: UTF8.self)
        #expect(!defaults.contains("\"output\""))
        #expect(!defaults.contains("\"background\""))
    }
}

struct EditHiddenSerializationTests {
    @Test func hiddenIsOmittedWhenFalseAndSentWhenTrue() throws {
        let shown = String(decoding: try EditJSON.encode(timeline(overlay(hidden: false))), as: UTF8.self)
        #expect(!shown.contains("\"hidden\""))
        let hidden = String(decoding: try EditJSON.encode(timeline(overlay(hidden: true))), as: UTF8.self)
        #expect(hidden.contains("\"hidden\":true"))
        let back = try EditJSON.decode(Data(hidden.utf8))
        #expect(back.overlay.first?.hidden == true)
    }

    @Test func aServerThatDoesNotAdvertiseHiddenIsNotSentTheKey() throws {
        let t = timeline(overlay(hidden: true))
        let stripped = EditJSON.withoutHidden(t)
        let text = String(decoding: try EditJSON.encode(stripped), as: UTF8.self)
        #expect(!text.contains("\"hidden\""))
        #expect(stripped.overlay.allSatisfy { !$0.hidden })
    }
}

struct EditLimitParsingTests {
    private func caps(_ rest: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare"\#(rest),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func advertisedLimitsAreKeptAndAbsentOnesStayAtTheOldFallback() throws {
        let raised = try caps(#","limits":{"edit_overlay_tracks":64,"edit_max_clips":200,"edit_overlay_hidden":true}"#)
        #expect(raised.limits.editOverlayTracks == 64)
        #expect(raised.limits.editMaxClips == 200)
        #expect(raised.limits.editOverlayHidden)
        let old = try caps(#","limits":{"edit_overlay_tracks":8,"edit_max_clips":50}"#)
        #expect(old.limits.editOverlayTracks == 8)
        #expect(old.limits.editMaxClips == 50)
        #expect(!old.limits.editOverlayHidden)
        let absent = try caps(#","features":{"editor":true}"#)
        #expect(absent.limits.editOverlayTracks == 1)
        #expect(absent.limits.editMaxClips == 50)
        #expect(!absent.limits.editOverlayHidden)
    }

    @Test func aFeatureFlagAlsoTurnsHiddenOn() throws {
        let flagged = try caps(#","features":{"overlay_hidden":true}"#)
        #expect(flagged.limits.editOverlayHidden)
    }

    @Test func validationFollowsTheLimitItIsGiven() {
        let sources = PreviewData.editorSources()
        let high = EditTimeline(canvas: story, main: [clip()], overlay: [
            EditOverlay(id: "cO0000001", item: PreviewEditorIDs.photo, at: 1, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3), track: 10),
        ])
        #expect(EditValidation.check(high, sources: sources).contains(.range(path: "overlay[0].track")))
        #expect(!EditValidation.check(high, sources: sources, maxOverlayTracks: 64).contains(.range(path: "overlay[0].track")))
        var many = EditTimeline(canvas: story, main: (0..<51).map { i in
            EditClip(id: "c\(String(format: "%08d", i))", item: PreviewEditorIDs.pier, in: 0, out: 0.2)
        }, overlay: [])
        #expect(EditValidation.check(many, sources: sources).contains(.tooManyClips))
        many.main = Array(many.main.prefix(50))
        #expect(!EditValidation.check(many, sources: sources, maxClips: 200).contains(.tooManyClips))
    }
}
