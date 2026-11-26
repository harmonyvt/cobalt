import AVFoundation
import Foundation

/// A caller's claim on the app-wide audio session.
///
/// `.playback` claims strictly dominate `.ambient` claims so browsing muted feeds, trimmers, or peeks never
/// demotes or deactivates an active Twitch stream, Picture-in-Picture session, or unmuted video.
public enum AudioSessionClaimKind: Sendable, Equatable {
    /// Muted auto-play loops, trimmers, and peeks. Mixes with external audio and is a no-op while any `.playback` claim lives.
    case ambient
    /// Unmuted foreground/background playback (Twitch native engine, PiP, unmuted videos, AirPlay `AVPlayer`).
    case playback(allowsPiP: Bool = false)

    public var isPlayback: Bool {
        if case .playback = self { return true }
        return false
    }
}

/// The effective audio session state applied to the underlying platform backend.
public enum AudioSessionMode: Sendable, Equatable {
    case inactive
    case ambient
    case playback
}

/// Audio session lifecycle events broadcast by `AudioSessionCoordinator` to registered engines.
public enum AudioSessionEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeOldDeviceUnavailable
    case mediaServicesReset
}

/// Platform abstraction over `AVAudioSession` so `AudioSessionCoordinator` arbitration and interruption
/// handling are deterministically unit-testable on macOS as well as iOS.
public protocol AudioSessionBackend: Sendable {
    func setAmbientCategory()
    func setPlaybackCategoryAndActivate()
    func deactivateToAmbient(notifyOthers: Bool)
}

private struct SystemAudioSessionBackend: AudioSessionBackend {
    func setAmbientCategory() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .ambient {
            try? session.setCategory(.ambient, mode: .default)
        }
        #endif
    }

    func setPlaybackCategoryAndActivate() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        #endif
    }

    func deactivateToAmbient(notifyOthers: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default)
        try? session.setActive(false, options: notifyOthers ? .notifyOthersOnDeactivation : [])
        #endif
    }
}

/// Single app-wide refcounted owner of `AVAudioSession` configuration, activation, and interruption broadcasts.
///
/// All session IPC calls run on one private serial queue (never the main thread and never `SampleBufferPipeline.queue`):
/// `setActive` waits on the media server, and serializing claims prevents out-of-order deactivation races.
public final class AudioSessionCoordinator: @unchecked Sendable {
    public static let shared = AudioSessionCoordinator()

    private let queue = DispatchQueue(label: "com.capybaraharmony.cobalt.audio-session", qos: .userInitiated)
    private let backend: any AudioSessionBackend
    private var claims: [String: AudioSessionClaimKind] = [:]
    private var appliedMode: AudioSessionMode = .inactive
    private var observers: [String: @Sendable (AudioSessionEvent) -> Void] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    public init(
        backend: (any AudioSessionBackend)? = nil,
        observeSystemNotifications: Bool? = nil
    ) {
        self.backend = backend ?? SystemAudioSessionBackend()
        let shouldObserve = observeSystemNotifications ?? (backend == nil)
        if shouldObserve {
            registerSystemNotifications()
        }
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Claims

    /// Fire-and-forget ambient hint (used by muted auto-play feeds and trimmers).
    /// Strictly a no-op while any `.playback` claim is active.
    public func ensureAmbient() {
        queue.async { [self] in
            guard !hasPlaybackClaimOnQueue else { return }
            if appliedMode != .ambient {
                backend.setAmbientCategory()
                appliedMode = .ambient
            }
        }
    }

    /// Acquires or updates a named claim on the audio session.
    public func claim(_ id: String, kind: AudioSessionClaimKind) {
        queue.async { [self] in
            claims[id] = kind
            reconcileOnQueue(forcePlaybackReactivation: false)
        }
    }

    /// Releases a named claim. Deactivates the audio session (with `.notifyOthersOnDeactivation`) only when
    /// the last `.playback` claim drops.
    public func release(_ id: String) {
        queue.async { [self] in
            guard claims.removeValue(forKey: id) != nil else { return }
            reconcileOnQueue(forcePlaybackReactivation: false)
        }
    }

    /// Re-asserts `.playback` + `setActive(true)` if any `.playback` claim is currently active (e.g. after interruption).
    public func reactivateIfNeeded() {
        queue.async { [self] in
            guard hasPlaybackClaimOnQueue else { return }
            backend.setPlaybackCategoryAndActivate()
            appliedMode = .playback
        }
    }

    // MARK: - Observers

    public func addObserver(id: String, handler: @escaping @Sendable (AudioSessionEvent) -> Void) {
        queue.async { [self] in
            observers[id] = handler
        }
    }

    public func removeObserver(id: String) {
        queue.async { [self] in
            observers.removeValue(forKey: id)
        }
    }

    // MARK: - Event dispatch (system notifications + deterministic test hooks)

    public func dispatchInterruptionBegan() {
        queue.async { [self] in
            broadcastOnQueue(.interruptionBegan)
        }
    }

    public func dispatchInterruptionEnded(shouldResume: Bool) {
        queue.async { [self] in
            if shouldResume && hasPlaybackClaimOnQueue {
                backend.setPlaybackCategoryAndActivate()
                appliedMode = .playback
            }
            broadcastOnQueue(.interruptionEnded(shouldResume: shouldResume))
        }
    }

    public func dispatchRouteOldDeviceUnavailable() {
        queue.async { [self] in
            broadcastOnQueue(.routeOldDeviceUnavailable)
        }
    }

    public func dispatchMediaServicesReset() {
        queue.async { [self] in
            if hasPlaybackClaimOnQueue {
                backend.setPlaybackCategoryAndActivate()
                appliedMode = .playback
            } else if appliedMode == .ambient {
                backend.setAmbientCategory()
            }
            broadcastOnQueue(.mediaServicesReset)
        }
    }

    // MARK: - Inspection & testing

    public func hasActivePlaybackClaim() -> Bool {
        queue.sync { hasPlaybackClaimOnQueue }
    }

    public func activePlaybackClaimCount() -> Int {
        queue.sync { claims.values.filter(\.isPlayback).count }
    }

    public func currentMode() -> AudioSessionMode {
        queue.sync { appliedMode }
    }

    /// Waits for all queued claim/release/event operations to complete.
    public func flush() {
        queue.sync {}
    }

    // MARK: - Queue-confined internals

    private var hasPlaybackClaimOnQueue: Bool {
        claims.values.contains(where: \.isPlayback)
    }

    private func reconcileOnQueue(forcePlaybackReactivation: Bool) {
        if hasPlaybackClaimOnQueue {
            if appliedMode != .playback || forcePlaybackReactivation {
                backend.setPlaybackCategoryAndActivate()
                appliedMode = .playback
            }
            return
        }

        if appliedMode == .playback {
            backend.deactivateToAmbient(notifyOthers: true)
            appliedMode = claims.isEmpty ? .inactive : .ambient
        } else if !claims.isEmpty && appliedMode != .ambient {
            backend.setAmbientCategory()
            appliedMode = .ambient
        }
    }

    private func broadcastOnQueue(_ event: AudioSessionEvent) {
        let current = Array(observers.values)
        for handler in current {
            handler(event)
        }
    }

    private func registerSystemNotifications() {
        #if os(iOS)
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        let interruption = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                self?.dispatchInterruptionBegan()
            case .ended:
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                self?.dispatchInterruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                break
            }
        }

        let routeChange = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            guard let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
            if reason == .oldDeviceUnavailable {
                self?.dispatchRouteOldDeviceUnavailable()
            }
        }

        let mediaReset = nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.dispatchMediaServicesReset()
        }

        notificationTokens = [interruption, routeChange, mediaReset]
        #endif
    }
}
