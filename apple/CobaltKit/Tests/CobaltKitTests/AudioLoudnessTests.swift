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

    @Test("AudioShareGate strictly enforces ?audio=normal hard gate across mixed media and edge cases")
    func shareGateRules() throws {
        let base = try #require(URL(string: "https://share.capybaraharmony.com/g/9000000000000000001"))
        let alreadyNormal = try #require(URL(string: "https://share.capybaraharmony.com/g/9000000000000000001?audio=normal"))

        let leveled = AudioLoudnessInfo(
            integratedLufs: -7.2, truePeakDbtp: -0.2, zone: .loud, state: .ready,
            targetLufs: -14, outputLufs: -14.0, outputTruePeak: -1.5, altID: "alt01"
        )
        let loudUnleveled = AudioLoudnessInfo(integratedLufs: -6.4, truePeakDbtp: -0.1, zone: .loud, state: .measured)
        let quietUnleveled = AudioLoudnessInfo(integratedLufs: -25.0, truePeakDbtp: -4.2, zone: .quiet, state: .measured)
        let rendering = AudioLoudnessInfo(integratedLufs: -8.1, truePeakDbtp: -0.4, zone: .loud, state: .rendering)
        let failed = AudioLoudnessInfo(integratedLufs: -6.8, truePeakDbtp: -0.2, zone: .loud, state: .failed, error: "ffmpeg timeout")
        let silent = AudioLoudnessInfo(integratedLufs: -70.0, truePeakDbtp: -70.0, zone: .silent, state: .skipped)

        // 1. Mixed link with photos, WebPs, silent video, and all audible videos leveled -> unlocked
        let unlocked = AudioShareGate(items: [
            AudioGateItem(id: "v1", isVideo: true, audio: leveled),
            AudioGateItem(id: "v2", isVideo: true, audio: silent),
            AudioGateItem(id: "p1", isVideo: false, audio: nil),
            AudioGateItem(id: "w1", isVideo: false, audio: nil),
        ])
        #expect(unlocked.status == .unlocked)
        #expect(unlocked.canShareNormalAudio)
        #expect(unlocked.audibleVideoCount == 1)
        #expect(unlocked.leveledCount == 1)
        #expect(unlocked.silentVideoCount == 1)
        #expect(unlocked.nonVideoCount == 2)
        #expect(unlocked.unleveledVideoIDs.isEmpty)
        #expect(unlocked.blockedReason == nil)
        #expect(unlocked.resolveURL(base: base, useNormal: true).absoluteString == "https://share.capybaraharmony.com/g/9000000000000000001?audio=normal")
        #expect(unlocked.resolveURL(base: base, useNormal: false).absoluteString == "https://share.capybaraharmony.com/g/9000000000000000001")

        // 2. Partial leveled + loud + quiet + nil (unknown) + failed + rendering -> strictly blocked
        let blocked = AudioShareGate(items: [
            AudioGateItem(id: "v1", isVideo: true, audio: leveled),
            AudioGateItem(id: "v2", isVideo: true, audio: loudUnleveled),
            AudioGateItem(id: "v3", isVideo: true, audio: quietUnleveled),
            AudioGateItem(id: "v4", isVideo: true, audio: nil),
            AudioGateItem(id: "v5", isVideo: true, audio: rendering),
            AudioGateItem(id: "v6", isVideo: true, audio: failed),
            AudioGateItem(id: "v7", isVideo: true, audio: silent),
            AudioGateItem(id: "img", isVideo: false, audio: nil),
        ])
        #expect(blocked.status == .blocked)
        #expect(!blocked.canShareNormalAudio)
        #expect(blocked.audibleVideoCount == 6)
        #expect(blocked.leveledCount == 1)
        #expect(blocked.unleveledCount == 5)
        #expect(blocked.renderingCount == 1)
        #expect(blocked.failedCount == 1)
        #expect(blocked.loudCount == 1)
        #expect(blocked.quietCount == 1)
        #expect(blocked.unmeasuredCount == 1)
        #expect(blocked.unleveledVideoIDs == ["v2", "v3", "v4", "v5", "v6"])
        // rendering item v5 is excluded from queueableVideoIDs, failed v6 IS retryable
        #expect(blocked.queueableVideoIDs == ["v2", "v3", "v4", "v6"])
        #expect(blocked.blockedReason == "5 of 6 videos aren't leveled yet")
        // Hard gate: MUST NEVER append ?audio=normal, and MUST strip it if already present
        #expect(blocked.resolveURL(base: base, useNormal: true).absoluteString == base.absoluteString)
        #expect(blocked.resolveURL(base: alreadyNormal, useNormal: true).absoluteString == base.absoluteString)

        // 3. Only images & silent videos -> notApplicable (and never appends ?audio=normal)
        let noAudible = AudioShareGate(items: [
            AudioGateItem(id: "p1", isVideo: false, audio: nil),
            AudioGateItem(id: "v-silent", isVideo: true, audio: silent),
        ])
        #expect(noAudible.status == .notApplicable)
        #expect(!noAudible.canShareNormalAudio)
        #expect(noAudible.audibleVideoCount == 0)
        #expect(noAudible.blockedReason == nil)
        #expect(noAudible.resolveURL(base: base, useNormal: true).absoluteString == base.absoluteString)

        // 4. All remaining videos actively leveling via inFlight -> leveling reason
        let inFlight = AudioShareGate(
            items: [
                AudioGateItem(id: "v1", isVideo: true, audio: leveled),
                AudioGateItem(id: "v2", isVideo: true, audio: loudUnleveled),
            ],
            inFlight: ["v2"]
        )
        #expect(inFlight.status == .blocked)
        #expect(inFlight.isLeveling)
        #expect(inFlight.queueableVideoIDs.isEmpty)
        #expect(inFlight.blockedReason == "leveling 1 of 2 videos…")

        // 5. All unleveled videos failed -> retry hint
        let allFailed = AudioShareGate(items: [
            AudioGateItem(id: "v1", isVideo: true, audio: leveled),
            AudioGateItem(id: "v2", isVideo: true, audio: failed),
        ])
        #expect(allFailed.blockedReason == "1 video failed leveling · retry to unlock")
    }

    @Test("ShareSetItem decodes optional audio summary and forShareSet skips private/hidden items")
    func shareSetItemAudioDecodingAndGate() throws {
        let json = """
        {
          "id": "9000000000000000099",
          "url": "https://share.capybaraharmony.com/g/9000000000000000099",
          "title": "loudness test",
          "created_at": 1700000000000,
          "items": [
            {
              "id": "vidReady",
              "url": "https://media.capybaraharmony.com/VidReady01.mp4",
              "content_type": "video/mp4",
              "audio": {
                "integrated_lufs": -7.5,
                "true_peak_dbtp": -0.2,
                "zone": "loud",
                "state": "ready",
                "target_lufs": -14,
                "output_lufs": -14.0,
                "output_true_peak": -1.5,
                "alt_id": "altReady01",
                "alt_url": "https://media.capybaraharmony.com/AltReady01.mp4"
              }
            },
            {
              "id": "vidPrivate",
              "url": null,
              "content_type": "video/mp4"
            },
            {
              "id": "vidHidden",
              "url": "https://media.capybaraharmony.com/VidHidden1.mp4",
              "content_type": "video/mp4",
              "hidden": true
            },
            {
              "id": "imgPhoto",
              "url": "https://media.capybaraharmony.com/Photo00001.jpg",
              "content_type": "image/jpeg"
            }
          ]
        }
        """
        let set = try CobaltJSON.decoder().decode(ShareSet.self, from: Data(json.utf8))
        #expect(set.items[0].audio?.isLeveled == true)
        #expect(set.items[0].audio?.altID == "altReady01")
        #expect(set.items[3].audio == nil)

        // Private & hidden un-leveled videos are excluded from the live page, so gate unlocks!
        let gate = AudioShareGate.forShareSet(set)
        #expect(gate.status == .unlocked)
        #expect(gate.audibleVideoCount == 1)
        #expect(gate.nonVideoCount == 1)
    }

    @Test("AudioLevelStore.levelItems deduplicates, skips leveled/silent, and queues remaining videos")
    @MainActor
    func bulkLevelItems() async throws {
        let model = AppModel.preview(.happy)
        let leveled = AudioLoudnessInfo(integratedLufs: -8.0, zone: .loud, state: .ready, targetLufs: -14, outputLufs: -14.0, altID: "alt1")
        let silent = AudioLoudnessInfo(integratedLufs: -72.0, zone: .silent, state: .skipped)
        let loud = AudioLoudnessInfo(integratedLufs: -6.5, zone: .loud, state: .measured)
        let lookup: [String: AudioLoudnessInfo] = [
            "done-1": leveled,
            "silent-1": silent,
            "need-1": loud,
            "need-2": loud,
        ]

        let result = await model.audioLeveling.levelItems(
            ids: ["done-1", "silent-1", "need-1", "need-1", "need-2"],
            target: .lufs14,
            audioLookup: { lookup[$0] }
        )
        #expect(result.queued == ["need-1", "need-2"])
        #expect(result.skipped == ["done-1", "silent-1"])
        #expect(result.failed.isEmpty)
        #expect(model.audioLeveling.activeBulkIDs.contains("need-1"))
        #expect(model.audioLeveling.activeBulkIDs.contains("need-2"))
        #expect(model.audioLeveling.optimisticAudio(for: "need-1", fallback: loud)?.isRendering == true)

        // Re-submitting the same IDs while active skips them cleanly
        let second = await model.audioLeveling.levelItems(
            ids: ["need-1", "need-2"],
            audioLookup: { lookup[$0] }
        )
        #expect(second.queued.isEmpty)
        #expect(second.skipped == ["need-1", "need-2"])

        model.audioLeveling.reset()
        #expect(!model.audioLeveling.isBulkLeveling)
    }

    @Test("QueueSnapshot decodes audio leveling entries cleanly")
    func queueSnapshotDecodesAudioJobs() throws {
        let json = """
        {
          "status": "success",
          "line": { "running": null, "waiting": [] },
          "search": null,
          "posters": null,
          "edits": [],
          "audio": [
            {
              "item_id": "itemA",
              "title": "loud_clip.mp4",
              "state": "rendering",
              "target_lufs": -14,
              "input_lufs": -6.2,
              "output_lufs": null,
              "error": null,
              "updated_at": 1700000100000
            },
            {
              "item_id": "itemB",
              "title": "done_clip.mp4",
              "state": "ready",
              "target_lufs": -14,
              "input_lufs": -7.4,
              "output_lufs": -14.1,
              "error": null,
              "updated_at": 1700000090000
            },
            {
              "item_id": "itemC",
              "title": "bad_clip.mp4",
              "state": "failed",
              "target_lufs": -16,
              "input_lufs": null,
              "output_lufs": null,
              "error": "ffmpeg failed",
              "updated_at": 1700000080000
            }
          ]
        }
        """
        let snap = try CobaltJSON.decoder().decode(QueueSnapshot.self, from: Data(json.utf8))
        let audio = try #require(snap.audio)
        #expect(audio.count == 3)
        #expect(audio[0].itemID == "itemA")
        #expect(audio[0].isActive == true)
        #expect(audio[0].targetLufs == -14)
        #expect(audio[1].state == .ready)
        #expect(audio[1].outputLufs == -14.1)
        #expect(audio[2].state == .failed)
        #expect(audio[2].error == "ffmpeg failed")
    }

    @Test("Audio leveling appears in UnifiedQueue and ActivityModel immediately when queued")
    @MainActor
    func unifiedQueueAndActivitySurfaceAudioLeveling() async throws {
        let model = AppModel.preview(.happy)
        let loud = AudioLoudnessInfo(integratedLufs: -6.5, zone: .loud, state: .measured)
        let result = await model.audioLeveling.levelItems(
            ids: ["clip-1", "clip-2"],
            target: .lufs14,
            audioLookup: { _ in loud }
        )
        #expect(result.queued == ["clip-1", "clip-2"])

        let nowSection = model.unifiedQueue.sections.first { $0.section == .now }
        let audioItems = nowSection?.items.filter {
            if case .audioLevel = $0.kind { return true }
            return false
        } ?? []
        #expect(audioItems.count == 2)
        #expect(model.unifiedQueue.summary.running >= 2)
        #expect(model.unifiedQueue.badgeCount >= 2)
        #expect(model.activity.activeCount >= 2)
        #expect(model.activity.items.contains { $0.kind == .audioLevel && $0.id == "audio:clip-1" })

        // Reconciling ready status from server moves items out of running into finished
        let future = Date().addingTimeInterval(10)
        model.audioLeveling.reconcileFromServer([
            QueueSnapshot.AudioLevelJob(
                itemID: "clip-1", title: "clip-1", state: .ready,
                targetLufs: -14, outputLufs: -14.0, updatedAt: future
            ),
            QueueSnapshot.AudioLevelJob(
                itemID: "clip-2", title: "clip-2", state: .failed,
                targetLufs: -14, error: "timeout", updatedAt: future
            ),
        ])
        #expect(model.unifiedQueue.summary.running == 0)
        #expect(model.unifiedQueue.summary.failed == 1)
        #expect(model.unifiedQueue.summary.finished >= 1)
        #expect(model.activity.activeCount == 0)
        #expect(model.activity.attentionCount == 1)

        model.audioLeveling.reset()
    }

    @Test("AudioLevelLiveManager groups bulk leveling into one Live Activity and reports completion")
    @MainActor
    func audioLevelLiveActivityGroupsBatchAndFinishes() async {
        var clockNow = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = FakeAudioLevelLiveAdapter(clock: { clockNow })
        let manager = AudioLevelLiveManager(adapter: adapter, now: { clockNow })

        // Start a 3-clip bulk batch -> ONE Live Activity requested
        let j1 = QueueSnapshot.AudioLevelJob(itemID: "a1", title: "clip1.mp4", state: .rendering, targetLufs: -14, updatedAt: clockNow)
        let j2 = QueueSnapshot.AudioLevelJob(itemID: "a2", title: "clip2.mp4", state: .rendering, targetLufs: -14, updatedAt: clockNow)
        let j3 = QueueSnapshot.AudioLevelJob(itemID: "a3", title: "clip3.mp4", state: .rendering, targetLufs: -14, updatedAt: clockNow)
        await manager.observe([j1, j2, j3])

        #expect(adapter.requests.count == 1)
        let handle = adapter.handles[0]
        #expect(handle.attributes.kind == "audio")
        #expect(handle.attributes.id == "audio-level")
        #expect(handle.state.phase == .working)
        #expect(handle.state.headline == "leveling audio · 0 of 3")
        #expect(handle.state.compact == "0/3")
        #expect(handle.state.fraction == 0)

        // 1 of 3 finishes -> updates same activity, does not spawn a second one
        clockNow = clockNow.addingTimeInterval(5)
        let j1Done = QueueSnapshot.AudioLevelJob(itemID: "a1", title: "clip1.mp4", state: .ready, targetLufs: -14, outputLufs: -14.0, updatedAt: clockNow)
        await manager.observe([j1Done, j2, j3])
        #expect(adapter.requests.count == 1)
        #expect(handle.state.headline == "leveling audio · 1 of 3")
        #expect(handle.state.compact == "1/3")
        #expect(abs((handle.state.fraction ?? 0) - (1.0 / 3.0)) < 0.01)

        // Remaining 2 settle: 1 ready, 1 failed -> ends activity cleanly with mixed summary
        clockNow = clockNow.addingTimeInterval(5)
        let j2Done = QueueSnapshot.AudioLevelJob(itemID: "a2", title: "clip2.mp4", state: .ready, targetLufs: -14, outputLufs: -14.1, updatedAt: clockNow)
        let j3Fail = QueueSnapshot.AudioLevelJob(itemID: "a3", title: "clip3.mp4", state: .failed, targetLufs: -14, error: "ffmpeg error", updatedAt: clockNow)
        await manager.observe([j1Done, j2Done, j3Fail])
        #expect(handle.isEnded)
        #expect(handle.end?.state.phase == .done)
        #expect(handle.end?.state.headline == "2 leveled · 1 failed")
        #expect(handle.end?.state.compact == "2/3")

        // Single-clip run afterwards starts a fresh activity and ends with output LUFS
        clockNow = clockNow.addingTimeInterval(10)
        let solo = QueueSnapshot.AudioLevelJob(itemID: "s1", title: "solo.mp4", state: .rendering, targetLufs: -16, updatedAt: clockNow)
        await manager.observe([solo])
        #expect(adapter.requests.count == 2)
        let soloHandle = adapter.handles[1]
        #expect(soloHandle.state.headline == "leveling solo.mp4")
        #expect(soloHandle.state.detail == "-16 LUFS")

        clockNow = clockNow.addingTimeInterval(4)
        let soloDone = QueueSnapshot.AudioLevelJob(itemID: "s1", title: "solo.mp4", state: .ready, targetLufs: -16, outputLufs: -16.0, updatedAt: clockNow)
        await manager.observe([soloDone])
        #expect(soloHandle.isEnded)
        #expect(soloHandle.end?.state.phase == .done)
        #expect(soloHandle.end?.state.headline == "audio leveled")
        #expect(soloHandle.end?.state.result == "-16.0 LUFS")
    }
}

@MainActor
private final class FakeAudioLevelLiveAdapter: AudioLevelLiveAdapter {
    var isAvailable = true
    var handles: [FakeLiveHandle] = []
    var requests: [JobLiveJob] = []
    let clock: @MainActor () -> Date

    init(clock: @escaping @MainActor () -> Date) {
        self.clock = clock
    }

    var activities: [any JobActivityHandle] { handles }

    func request(_ job: JobLiveJob, staleDate: Date, push: Bool) throws -> any JobActivityHandle {
        requests.append(job)
        let h = FakeLiveHandle(job: job, staleDate: staleDate, clock: clock)
        handles.append(h)
        return h
    }
}

