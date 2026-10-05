import AVFoundation
import CoreGraphics
import Foundation
import Security
import Synchronization
import Testing
@testable import CobaltKit

// Live end-to-end fixes: the keychain on a build that has none, posters for very short clips, and the
// "waking server" flicker.

// MARK: - Keychain

/// A keychain the test controls: which accounts it refuses, and with what.
final class FakeKeychainBackend: KeychainBackend, Sendable {
    enum Mode: Sendable {
        case unsigned                      // errSecMissingEntitlement for everything, default keychain included
        case defaultOnly                   // a group query is refused, the default keychain works
        case healthy                       // everything works
    }
    let mode: Mode
    /// Accounts whose writes fail with this status (any mode).
    let failing: Mutex<[String: OSStatus]> = Mutex([:])
    private let items = Mutex<[String: Data]>([:])
    private let attempts = Mutex<[String]>([])

    init(_ mode: Mode) { self.mode = mode }

    private func key(_ q: [String: Any]) -> (slot: String, group: String?)? {
        let account = q[kSecAttrAccount as String] as? String ?? ""
        let group = q[kSecAttrAccessGroup as String] as? String
        return ("\(group ?? "-")/\(account)", group)
    }

    private func refused(_ q: [String: Any]) -> OSStatus? {
        let group = q[kSecAttrAccessGroup as String] as? String
        switch mode {
        case .unsigned: return errSecMissingEntitlement
        case .defaultOnly: return group == nil ? nil : errSecMissingEntitlement
        case .healthy: return nil
        }
    }

    var groupAttempts: Int { attempts.withLock { $0.filter { $0.hasPrefix("group:") }.count } }
    var stored: [String: Data] { items.withLock { $0 } }

    func copy(_ q: [String: Any]) -> (status: OSStatus, data: Data?) {
        if let r = refused(q) { return (r, nil) }
        let k = key(q)!
        guard let data = items.withLock({ $0[k.slot] }) else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    private func failure(_ q: [String: Any]) -> OSStatus? {
        let account = q[kSecAttrAccount as String] as? String ?? ""
        return failing.withLock { $0[account] }
    }

    func add(_ item: [String: Any]) -> OSStatus {
        let k = key(item)!
        attempts.withLock { $0.append(k.group == nil ? "default" : "group:\(k.group!)") }
        if let r = refused(item) { return r }
        if let f = failure(item) { return f }
        items.withLock { $0[k.slot] = item[kSecValueData as String] as? Data }
        return errSecSuccess
    }

    func update(_ q: [String: Any], data: Data) -> OSStatus {
        attempts.withLock { $0.append(q[kSecAttrAccessGroup as String] == nil ? "default" : "group:update") }
        if let r = refused(q) { return r }
        let k = key(q)!
        guard items.withLock({ $0[k.slot] != nil }) else { return errSecItemNotFound }
        if let f = failure(q) { return f }
        items.withLock { $0[k.slot] = data }
        return errSecSuccess
    }

    func delete(_ q: [String: Any]) -> OSStatus {
        if let r = refused(q) { return r }
        let k = key(q)!
        return items.withLock { $0.removeValue(forKey: k.slot) } == nil ? errSecItemNotFound : errSecSuccess
    }
}

private let validKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let group = "ABCDE12345.com.capybaraharmony.cobalt"

@MainActor
struct KeychainFallbackTests {
    private func files() throws -> SecretFiles { SecretFiles(directory: try makeTempDirectory().appendingPathComponent("secrets")) }

    private func settings(_ keychain: Keychain) -> Settings {
        Settings(defaults: UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!, keychain: keychain)
    }

    @Test func aGroupThisBuildIsNotEntitledToFallsBackToTheDefaultKeychain() throws {
        let backend = FakeKeychainBackend(.defaultOnly)
        let k = Keychain(service: "t", accessGroup: group, backend: backend, files: nil)
        try k.set("v1", for: "api-key")
        #expect(backend.groupAttempts == 1, "the group is tried first")
        #expect(k.string(for: "api-key") == "v1")
        try k.set("v2", for: "api-key")
        #expect(k.string(for: "api-key") == "v2")
        try k.set(nil, for: "api-key")
        #expect(k.string(for: "api-key") == nil)
        #expect(backend.stored.isEmpty)
    }

    @Test func anEntitledGroupIsUsedWhenItWorks() throws {
        let backend = FakeKeychainBackend(.healthy)
        let k = Keychain(service: "t", accessGroup: group, backend: backend, files: nil)
        try k.set("v1", for: "api-key")
        #expect(backend.stored.keys.contains { $0.hasPrefix(group) })
        #expect(k.string(for: "api-key") == "v1")
    }

    @Test func aBuildWithNoKeychainAtAllStoresTheKeyInItsOwnContainer() throws {
        let dir = try files()
        let backend = FakeKeychainBackend(.unsigned)
        let s = settings(Keychain(service: "t", accessGroup: nil, backend: backend, files: dir))
        try s.setAPIKey(pasted: validKey)
        #expect(s.hasAPIKey && s.apiKey() == validKey)
        // a second process of the same build (a fresh Keychain on the same container) finds it
        let again = settings(Keychain(service: "t", accessGroup: nil, backend: FakeKeychainBackend(.unsigned), files: dir))
        #expect(again.apiKey() == validKey)
        again.clearAPIKey()
        #expect(!again.hasAPIKey && again.apiKey() == nil)
        #expect(s.apiKey() == nil, "cleared in the shared container")
    }

    @Test func aKeyTheDeviceWillNotStoreIsNeverCalledInvalid() throws {
        let s = settings(Keychain(service: "t", accessGroup: nil, backend: FakeKeychainBackend(.unsigned), files: nil))
        do {
            try s.setAPIKey(pasted: validKey)
            Issue.record("expected the save to fail")
        } catch {
            #expect(error == .couldNotSave)
        }
        #expect(!s.hasAPIKey)
        do { try s.setAPIKey(pasted: "hello"); Issue.record("expected a refusal") } catch { #expect(error == .notAKey) }
        do { try s.setAPIKey(pasted: String(validKey.dropLast())); Issue.record("expected a refusal") } catch { #expect(error == .notAKey) }
    }

    @Test func aKeychainThatFailsForAnotherReasonIsAlsoACouldNotSaveAndNeverWritesAFile() throws {
        let dir = try files()
        let backend = FakeKeychainBackend(.healthy)
        backend.failing.withLock { $0["api-key"] = errSecInteractionNotAllowed }
        let s = settings(Keychain(service: "t", accessGroup: nil, backend: backend, files: dir))
        #expect(throws: KeyInputError.couldNotSave) { try s.setAPIKey(pasted: validKey) }
        #expect(!FileManager.default.fileExists(atPath: dir.directory.path), "a working keychain never spills to disk")
    }

    @Test func aFailedSaveLeavesThePreviousKeyAndServerBindingAlone() throws {
        let backend = FakeKeychainBackend(.healthy)
        let k = Keychain(service: "t", accessGroup: nil, backend: backend, files: nil)
        let s = settings(k)
        try s.setAPIKey(pasted: validKey)
        let other = "11111111-2222-4333-8444-555555555555"
        backend.failing.withLock { $0["api-key-host"] = errSecInteractionNotAllowed }   // the second write fails
        #expect(throws: KeyInputError.couldNotSave) { try s.setAPIKey(pasted: other) }
        #expect(s.apiKey() == validKey, "the first write was put back")
        #expect(s.hasAPIKey)
    }

    @Test func aWorkingKeychainClearsWhatTheFileFallbackLeftBehind() throws {
        let dir = try files()
        let unsigned = Keychain(service: "t", accessGroup: nil, backend: FakeKeychainBackend(.unsigned), files: dir)
        try unsigned.set("old", for: "api-key")
        #expect(unsigned.string(for: "api-key") == "old")
        let signed = Keychain(service: "t", accessGroup: nil, backend: FakeKeychainBackend(.healthy), files: dir)
        try signed.set("new", for: "api-key")
        #expect(signed.string(for: "api-key") == "new")
        try signed.set(nil, for: "api-key")
        #expect(signed.string(for: "api-key") == nil, "no stale file answers after the keychain forgot it")
    }
}

// MARK: - Posters and frames for very short clips

private enum Clip {
    static func make(_ name: String, seconds: Double, fps: Int = 30, fragmented: Bool = false, rotated: Bool = false,
                     width: Int = 96, height: Int = 160) async throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("\(name).mp4")
        try await TestVideo.make(at: url, seconds: seconds, width: width, height: height, fps: fps,
                                 fragmented: fragmented, rotated: rotated)
        return url
    }

    /// 1.2 s at 30 fps (the gif-converted mp4 from the live run), plain and fragmented, and one frame.
    static func variants() async throws -> [(String, URL)] {
        [("1.2 s", try await make("short", seconds: 1.2)),
         ("1.2 s fragmented", try await make("short-frag", seconds: 1.2, fragmented: true)),
         ("one frame", try await make("one", seconds: 0.034)),
         ("one frame fragmented", try await make("one-frag", seconds: 0.034, fragmented: true))]
    }
}

struct ShortClipPosterTests {
    let tools = SystemMediaTools()

    @Test func aShortClipGetsAPoster() async throws {
        for (name, url) in try await Clip.variants() {
            let out = try makeTempDirectory().appendingPathComponent("poster.jpg")
            let made = await tools.poster(for: url, isImage: false, to: out)
            #expect(made && FileManager.default.fileExists(atPath: out.path), "\(name): no poster")
        }
    }

    @Test func aShortClipGetsAFilmstripEvenWhenTheStatedDurationIsLonger() async throws {
        for (name, url) in try await Clip.variants() {
            var seen = Set<Int>()
            // the server said 5 s; the file has 1.2 s (or one frame): asking past the end must not fail
            for try await frame in tools.frames(of: .local(url), duration: 5, count: 9) { seen.insert(frame.index) }
            #expect(!seen.isEmpty, "\(name): no frames")
        }
        // the honest duration gives all nine of a clip that has the frames for them
        var all = 0
        for try await _ in tools.frames(of: .local(try await Clip.make("nine", seconds: 1.2)), duration: 1.2, count: 9) { all += 1 }
        #expect(all == 9)
    }

    @Test func aTrulyOneFrameClipHasNoFlipbookButItsPosterStillExists() async throws {
        let url = try await Clip.make("single", seconds: 0.034)
        let frames = await tools.previewFrames(of: url, animatedImage: false, count: 12, maxEdge: 160)
        #expect(!frames.isEmpty)                                       // something to show, whether one or twelve copies
        let info = await tools.probe(file: url)
        #expect(info != nil)
    }

    @Test func aShortClipsFlipbookHasEnoughFramesToFlip() async throws {
        let url = try await Clip.make("flip", seconds: 1.2)
        let frames = await tools.previewFrames(of: url, animatedImage: false, count: 12, maxEdge: 160)
        #expect(frames.count >= 2)
        #expect(frames.allSatisfy { max($0.width, $0.height) <= 160 })
    }

    // The front-to-back read, used when the generator gets nothing: exercised directly.

    @Test func theSequentialReaderGivesEveryTimeAFrameAndTheFirstFrameBeforeTheStart() async throws {
        for (name, url) in try await Clip.variants() {
            let asset = try await SystemMediaTools.openAsset(url)
            let times = [0, 0.2, 0.5, 0.9, 5.0]                        // the last is past the end: the last frame
            let images = await SystemMediaTools.sequentialImages(of: asset, at: times, maxEdge: 360)
            #expect(images.count == times.count && images.allSatisfy { $0 != nil }, "\(name): \(images.map { $0 != nil })")
        }
    }

    @Test func theSequentialReaderFollowsTheClipInTime() async throws {
        let url = try await Clip.make("ramp", seconds: 1.2)
        let asset = try await SystemMediaTools.openAsset(url)
        let images = await SystemMediaTools.sequentialImages(of: asset, at: [0.0, 0.6, 1.15], maxEdge: 360)
        let reds = try images.map { TestImages.meanColor(try #require($0)).r }
        #expect(reds[0] < reds[1] && reds[1] < reds[2], "the clip goes from blue to red: \(reds)")
    }

    @Test func theSequentialReaderAppliesTheTrackOrientation() async throws {
        // 160 wide by 96 high, turned a quarter: it shows upright as 96 wide by 160 high
        let url = try await Clip.make("turned", seconds: 0.5, rotated: true, width: 160, height: 96)
        let asset = try await SystemMediaTools.openAsset(url)
        let image = try #require(await SystemMediaTools.sequentialImages(of: asset, at: [0], maxEdge: 360).first ?? nil)
        #expect(image.height > image.width, "\(image.width)x\(image.height)")
        #expect(SystemMediaTools.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)) == .right)
        #expect(SystemMediaTools.orientation(of: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) == .left)
        #expect(SystemMediaTools.orientation(of: .identity) == .up)
    }

    @Test func playableDurationIsTheShortestHonestLength() async throws {
        let url = try await Clip.make("len", seconds: 1.2)
        let asset = try await SystemMediaTools.openAsset(url)
        let honest = await SystemMediaTools.playableDuration(of: asset, hint: nil)
        #expect(abs(honest - 1.2) < 0.1)
        #expect(await SystemMediaTools.playableDuration(of: asset, hint: 5) == honest, "a longer claim never wins")
        #expect(await SystemMediaTools.playableDuration(of: asset, hint: 0.5) == 0.5, "a shorter one may")
    }
}

// MARK: - "waking server" is sticky

private func wakingSession(_ id: String, _ status: SessionStatus, waking: Bool?, step: SaveStep? = .fetching) -> StudioSession {
    StudioSession(
        id: id, status: status, link: nil, service: nil, title: status == .ready ? "x" : nil,
        duration: status == .ready ? 14.77 : nil, width: status == .ready ? 720 : nil, height: status == .ready ? 1280 : nil,
        bytes: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_600_000),
        errorCode: nil, renders: [], step: status == .saving ? step : nil, stepBytes: nil, stepTotal: nil, waking: waking)
}

@MainActor
struct WakingStickyTests {
    @Test func onceWakingAPollThatSaysNotWakingDoesNotFlipItBack() async throws {
        let h = Harness(.happy)
        let polls = Log<Int>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.sessionHook = { id, _ in
            let n = polls.add(1)
            switch n {
            case 1: return wakingSession(id, .saving, waking: false)
            case 2, 3: return wakingSession(id, .saving, waking: true)
            case 4, 5: return wakingSession(id, .saving, waking: false)     // the flicker
            case 6: return wakingSession(id, .saving, waking: nil)
            case 7: return wakingSession(id, .saving, waking: false, step: .storing)
            default: return wakingSession(id, .ready, waking: nil)
            }
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.drive(until: { h.isTerminalOrReady() }, maxVirtualSeconds: 1_000)
        #expect(h.pipeline.state == .ready)

        let fetching = h.pipeline.stateLog.compactMap { state -> Bool? in
            if case .fetching(_, let waking) = state { return waking } else { return nil }
        }
        let firstWaking = try #require(fetching.firstIndex(of: true), "never showed waking: \(fetching)")
        #expect(fetching[firstWaking...].allSatisfy { $0 }, "waking flickered back: \(fetching)")
    }

    @Test func theStickinessEndsWhenTheStepChangesAndIsPerRun() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        p.setState(.fetching(since: since, waking: true))
        p.setState(.fetching(since: since, waking: false))
        #expect(p.state == .fetching(since: since, waking: true))

        p.setState(.saving(bytes: nil, total: nil, since: since))        // the step changed
        p.setState(.fetching(since: since, waking: false))
        #expect(p.state == .fetching(since: since, waking: false), "a new fetch starts honest")

        p.setState(.fetching(since: since, waking: true))
        let next = since.addingTimeInterval(60)                           // another run
        p.setState(.fetching(since: next, waking: false))
        #expect(p.state == .fetching(since: next, waking: false))
    }
}
