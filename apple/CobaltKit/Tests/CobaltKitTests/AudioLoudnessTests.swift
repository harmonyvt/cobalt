import Foundation
import Testing
@testable import CobaltKit

@Suite("AudioLoudness")
struct AudioLoudnessTests {
    @Test("Classifier matches backend rules including peak-clip edge case")
    func classifierRules() {
        let loud = AudioLoudnessClassifier.classify(lufs: -6.2, truePeak: -0.1)
        #expect(loud.zone == .loud)
        #expect(loud.autoLevel == true)

        // -11.2 LUFS flips on true peak > -0.3 dBTP alone
        let hotClip = AudioLoudnessClassifier.classify(lufs: -11.2, truePeak: -0.1)
        #expect(hotClip.zone == .loud)
        #expect(hotClip.autoLevel == true)

        let hotClean = AudioLoudnessClassifier.classify(lufs: -11.2, truePeak: -1.0)
        #expect(hotClean.zone == .balanced)
        #expect(hotClean.autoLevel == false)

        let quiet = AudioLoudnessClassifier.classify(lufs: -28.4, truePeak: -14.2)
        #expect(quiet.zone == .quiet)
        #expect(quiet.autoLevel == true)

        let balanced = AudioLoudnessClassifier.classify(lufs: -15.1, truePeak: -1.8)
        #expect(balanced.zone == .balanced)
        #expect(balanced.autoLevel == false)

        let silent = AudioLoudnessClassifier.classify(lufs: -70.0, truePeak: -70.0)
        #expect(silent.zone == .silent)
        #expect(silent.autoLevel == false)
    }

    @Test("AudioShareURL appends, strips, and resolves ?audio=normal cleanly")
    func shareURLHelper() throws {
        let slug = try #require(URL(string: "https://capy.link/abc123def"))
        let normal = AudioShareURL.withNormalAudio(slug)
        #expect(normal.absoluteString == "https://capy.link/abc123def?audio=normal")
        #expect(AudioShareURL.hasNormalAudio(normal))

        let stripped = AudioShareURL.withoutNormalAudio(normal)
        #expect(stripped.absoluteString == "https://capy.link/abc123def")
        #expect(!AudioShareURL.hasNormalAudio(stripped))

        // Private link and gallery link
        let priv = try #require(URL(string: "https://capy.link/p/secretKey123/1.mp4"))
        #expect(AudioShareURL.withNormalAudio(priv).absoluteString == "https://capy.link/p/secretKey123/1.mp4?audio=normal")

        let gallery = try #require(URL(string: "https://capy.link/g/gal99?v=2"))
        let galleryNorm = AudioShareURL.withNormalAudio(gallery)
        #expect(AudioShareURL.hasNormalAudio(galleryNorm))
        #expect(galleryNorm.absoluteString.contains("v=2"))
        #expect(AudioShareURL.withoutNormalAudio(galleryNorm).absoluteString == "https://capy.link/g/gal99?v=2")

        // Resolve only appends ?audio=normal when alt is ready AND useLeveled == true
        let ready = AudioLoudnessInfo(integratedLufs: -6.2, truePeakDbtp: -0.1, zone: .loud, state: .ready, targetLufs: -14, outputLufs: -14.0, outputTruePeak: -1.5, altID: "alt123")
        #expect(AudioShareURL.resolve(base: slug, audio: ready, useLeveled: true).absoluteString == "https://capy.link/abc123def?audio=normal")
        #expect(AudioShareURL.resolve(base: slug, audio: ready, useLeveled: false).absoluteString == "https://capy.link/abc123def")

        let measuredOnly = AudioLoudnessInfo(integratedLufs: -6.2, truePeakDbtp: -0.1, zone: .loud, state: .measured)
        #expect(AudioShareURL.resolve(base: slug, audio: measuredOnly, useLeveled: true).absoluteString == "https://capy.link/abc123def")
    }

    @Test("Decodes LibraryFile with audio loudness payload and capabilities feature flag")
    func wireDecoding() throws {
        let json = """
        {
          "id": "file001",
          "kind": "private",
          "source": "studio",
          "name": "clip.mp4",
          "url": "https://media.capybaraharmony.com/abc1234567.mp4",
          "content_type": "video/mp4",
          "bytes": 1048576,
          "width": 1920,
          "height": 1080,
          "duration": 12.5,
          "created_at": 1700000000000,
          "deletable": true,
          "visibility": "public",
          "visibility_toggle": true,
          "audio": {
            "integrated_lufs": -6.2,
            "true_peak_dbtp": -0.1,
            "lra_lu": 4.8,
            "zone": "loud",
            "state": "ready",
            "target_lufs": -14,
            "output_lufs": -14.0,
            "output_true_peak": -1.5,
            "alt_id": "alt0000000000001",
            "alt_url": "https://media.capybaraharmony.com/alt1234567.mp4",
            "error": null,
            "measured_at": 1700000001000,
            "leveled_at": 1700000005000
          }
        }
        """
        let file = try CobaltJSON.decoder().decode(LibraryFile.self, from: Data(json.utf8))
        let audio = try #require(file.audio)
        #expect(audio.integratedLufs == -6.2)
        #expect(audio.truePeakDbtp == -0.1)
        #expect(audio.lraLu == 4.8)
        #expect(audio.zone == .loud)
        #expect(audio.state == .ready)
        #expect(audio.targetLufs == -14)
        #expect(audio.outputLufs == -14.0)
        #expect(audio.outputTruePeak == -1.5)
        #expect(audio.altID == "alt0000000000001")
        #expect(audio.altURL?.absoluteString == "https://media.capybaraharmony.com/alt1234567.mp4")
        #expect(audio.isLeveled)
        #expect(!audio.needsRelevel(for: .lufs14))
        #expect(audio.needsRelevel(for: .lufs16))

        let settingsJSON = """
        {
          "status": "success",
          "mode": "auto",
          "target_lufs": -16,
          "default_link": "normal",
          "updated_at": 1700000010000,
          "counts": {
            "total_videos": 40,
            "measured": 30,
            "leveled": 12,
            "needs_level": 5,
            "rendering": 1,
            "failed": 2
          }
        }
        """
        let settings = try CobaltJSON.decoder().decode(AudioLevelSettings.self, from: Data(settingsJSON.utf8))
        #expect(settings.mode == .auto)
        #expect(settings.target == .lufs16)
        #expect(settings.defaultLink == .normal)
        #expect(settings.counts.totalVideos == 40)
        #expect(settings.counts.unmeasured == 10)
        #expect(settings.counts.leveled == 12)
        #expect(settings.counts.needsLevel == 5)

        let capsJSON = """
        {
          "server": "cobalt-cloudflare",
          "features": { "library": true, "audio_leveling": true }
        }
        """
        let caps = try #require(HTTPCobaltClient.parseForkCapabilities(Data(capsJSON.utf8)))
        #expect(caps.audioLeveling == true)
    }

    @Test("AudioLevelStore loads, updates, levels, removes, and backfills via PreviewClient")
    @MainActor
    func storeLifecycle() async throws {
        let model = AppModel.preview(.happy)
        #expect(model.capabilities.audioLeveling)

        await model.audioLeveling.load(force: true)
        #expect(model.audioLeveling.loaded)
        #expect(model.audioLeveling.settings.mode == .auto)
        #expect(model.audioLeveling.settings.target == .lufs14)

        await model.audioLeveling.update(.init(mode: .measure, target: .lufs16, defaultLink: .normal))
        #expect(model.audioLeveling.settings.mode == .measure)
        #expect(model.audioLeveling.settings.target == .lufs16)
        #expect(model.audioLeveling.settings.defaultLink == .normal)

        let queued = try await model.audioLeveling.levelItem(id: "preview-item-1", target: .lufs16)
        #expect(queued.queued)
        #expect(queued.target == .lufs16)

        let removed = try await model.audioLeveling.removeLevel(id: "preview-item-1")
        #expect(removed.removed)

        let backfill = try await model.audioLeveling.backfill(limit: 5)
        #expect(backfill.mode == .measure)
        #expect(backfill.target == .lufs16)
    }

    @Test("AudioRulerScale clamps cleanly to 0...1")
    func rulerScale() {
        #expect(AudioRulerScale.fraction(for: -32) == 0.0)
        #expect(AudioRulerScale.fraction(for: 0) == 1.0)
        #expect(AudioRulerScale.fraction(for: -16) == 0.5)
        #expect(AudioRulerScale.fraction(for: -99) == 0.0)
        #expect(AudioRulerScale.fraction(for: 5) == 1.0)
    }
}
