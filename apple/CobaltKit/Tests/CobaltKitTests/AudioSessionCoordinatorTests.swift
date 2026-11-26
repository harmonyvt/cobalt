import Foundation
import Testing
@testable import CobaltKit

/// Unit tests for `AudioSessionCoordinator` claim arbitration, refcounting, and interruption/route/reset broadcasts.
@Suite struct AudioSessionCoordinatorTests {
    private final class SpyBackend: AudioSessionBackend, @unchecked Sendable {
        enum Call: Equatable, Sendable {
            case setAmbient
            case setPlaybackAndActivate
            case deactivateToAmbient(notifyOthers: Bool)
        }

        private let lock = NSLock()
        private var recorded: [Call] = []

        func setAmbientCategory() {
            lock.lock()
            recorded.append(.setAmbient)
            lock.unlock()
        }

        func setPlaybackCategoryAndActivate() {
            lock.lock()
            recorded.append(.setPlaybackAndActivate)
            lock.unlock()
        }

        func deactivateToAmbient(notifyOthers: Bool) {
            lock.lock()
            recorded.append(.deactivateToAmbient(notifyOthers: notifyOthers))
            lock.unlock()
        }

        func calls() -> [Call] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AudioSessionEvent] = []

        func append(_ event: AudioSessionEvent) {
            lock.lock()
            list.append(event)
            lock.unlock()
        }

        func snapshot() -> [AudioSessionEvent] {
            lock.lock()
            defer { lock.unlock() }
            return list
        }
    }

    @Test func playbackDominatesAmbientAndEnsureAmbientNeverDemotesPlayback() {
        let backend = SpyBackend()
        let coord = AudioSessionCoordinator(backend: backend, observeSystemNotifications: false)

        coord.ensureAmbient()
        coord.flush()
        #expect(coord.currentMode() == .ambient)
        #expect(backend.calls() == [.setAmbient])

        // Twitch playback starts.
        coord.claim("twitch.native", kind: .playback(allowsPiP: true))
        coord.flush()
        #expect(coord.currentMode() == .playback)
        #expect(coord.hasActivePlaybackClaim())
        #expect(backend.calls() == [.setAmbient, .setPlaybackAndActivate])

        // Muted feed, trimmer, or peek calls ensureAmbient() or claims .ambient: must NOT demote .playback!
        coord.ensureAmbient()
        coord.claim("home.feed", kind: .ambient)
        coord.claim("trimmer", kind: .ambient)
        coord.release("trimmer")
        coord.flush()

        #expect(coord.currentMode() == .playback)
        #expect(coord.activePlaybackClaimCount() == 1)
        #expect(backend.calls() == [.setAmbient, .setPlaybackAndActivate])
    }

    @Test func refcountsMultiplePlaybackClaimsAndDeactivatesOnlyWhenLastDrops() {
        let backend = SpyBackend()
        let coord = AudioSessionCoordinator(backend: backend, observeSystemNotifications: false)

        coord.claim("twitch.native", kind: .playback(allowsPiP: true))
        coord.claim("twitch.pip", kind: .playback(allowsPiP: true))
        coord.claim("focus.video", kind: .playback(allowsPiP: false))
        coord.flush()

        #expect(coord.activePlaybackClaimCount() == 3)
        // Category + activation only needed once while transitioning into .playback.
        #expect(backend.calls() == [.setPlaybackAndActivate])

        // Dropping individual playback claims must NOT deactivate the session.
        coord.release("focus.video")
        coord.flush()
        #expect(coord.activePlaybackClaimCount() == 2)
        #expect(coord.currentMode() == .playback)
        #expect(backend.calls() == [.setPlaybackAndActivate])

        coord.release("twitch.native")
        coord.flush()
        #expect(coord.activePlaybackClaimCount() == 1)
        #expect(coord.currentMode() == .playback)
        #expect(backend.calls() == [.setPlaybackAndActivate])

        // Dropping the final playback claim deactivates and notifies other apps.
        coord.release("twitch.pip")
        coord.flush()
        #expect(coord.activePlaybackClaimCount() == 0)
        #expect(coord.currentMode() == .inactive)
        #expect(backend.calls() == [.setPlaybackAndActivate, .deactivateToAmbient(notifyOthers: true)])
    }

    @Test func droppingLastPlaybackClaimWithAmbientClaimActiveTransitionsToAmbient() {
        let backend = SpyBackend()
        let coord = AudioSessionCoordinator(backend: backend, observeSystemNotifications: false)

        coord.claim("home.feed", kind: .ambient)
        coord.claim("twitch.native", kind: .playback(allowsPiP: true))
        coord.release("twitch.native")
        coord.flush()

        #expect(coord.currentMode() == .ambient)
        #expect(!coord.hasActivePlaybackClaim())
        #expect(backend.calls() == [.setAmbient, .setPlaybackAndActivate, .deactivateToAmbient(notifyOthers: true)])
    }

    @Test func interruptionEndedReactivatesOnlyWhenShouldResumeAndPlaybackClaimActive() {
        let backend = SpyBackend()
        let coord = AudioSessionCoordinator(backend: backend, observeSystemNotifications: false)
        let events = EventBox()

        coord.addObserver(id: "engine") { events.append($0) }
        coord.claim("twitch.native", kind: .playback(allowsPiP: true))
        coord.flush()

        coord.dispatchInterruptionBegan()
        coord.dispatchInterruptionEnded(shouldResume: false)
        coord.flush()

        #expect(backend.calls() == [.setPlaybackAndActivate])
        #expect(events.snapshot() == [.interruptionBegan, .interruptionEnded(shouldResume: false)])

        coord.dispatchInterruptionBegan()
        coord.dispatchInterruptionEnded(shouldResume: true)
        coord.flush()

        #expect(backend.calls() == [.setPlaybackAndActivate, .setPlaybackAndActivate])
        #expect(events.snapshot() == [
            .interruptionBegan,
            .interruptionEnded(shouldResume: false),
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
        ])
    }

    @Test func routeChangeAndMediaServicesResetBroadcastAndReassertSession() {
        let backend = SpyBackend()
        let coord = AudioSessionCoordinator(backend: backend, observeSystemNotifications: false)
        let events = EventBox()

        coord.addObserver(id: "engine") { events.append($0) }
        coord.claim("twitch.native", kind: .playback(allowsPiP: true))
        coord.dispatchRouteOldDeviceUnavailable()
        coord.dispatchMediaServicesReset()
        coord.flush()

        #expect(events.snapshot() == [.routeOldDeviceUnavailable, .mediaServicesReset])
        #expect(backend.calls() == [.setPlaybackAndActivate, .setPlaybackAndActivate])
    }
}
