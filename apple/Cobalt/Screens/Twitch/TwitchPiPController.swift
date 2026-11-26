@preconcurrency import AVFoundation
import AVKit
import CobaltKit
import Foundation

/// Drives single-stream Picture-in-Picture over `AVSampleBufferDisplayLayer` on both iOS and macOS.
///
/// Key invariants:
/// - `pictureInPictureControllerIsPlaybackPaused` reports explicit `userPaused` (NEVER transient pacer `rate == 0`),
///   preventing PiP controls from flickering during sub-second live-edge buffering.
/// - `timeRangeForPlayback` returns `[−∞, +∞]` so the system renders a live stream UI with no scrub bar.
/// - `canStartPictureInPictureAutomaticallyFromInline` is enabled on iOS only while actively playing inline.
@MainActor
final class TwitchPiPController {
    private(set) var isPossible = false
    private(set) var isStarting = false
    private(set) var isActive = false
    private(set) var isStopping = false

    var onPossibleChange: ((Bool) -> Void)?
    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onDidStop: ((_ restoredUI: Bool) -> Void)?
    var onFailedToStart: ((Error) -> Void)?
    var onSetPlaying: ((Bool) -> Void)?
    var onRestoreUI: ((@escaping @MainActor (Bool) -> Void) -> Void)?

    private var controller: AVPictureInPictureController?
    private weak var attachedLayer: AVSampleBufferDisplayLayer?
    private var possibleObservation: NSKeyValueObservation?
    private let delegateProxy = PiPDelegateProxy()
    private var restoredUIForCurrentStop = false
    private var attachGeneration: UInt64 = 0

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    init() {
        delegateProxy.owner = self
    }

    deinit {
        possibleObservation?.invalidate()
    }

    /// Attaches a PiP controller to `layer` if supported and not already bound to the same layer.
    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard Self.isSupported else { return }
        guard !isActive && !isStarting else { return }
        if attachedLayer === layer, controller != nil { return }
        detach()

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: delegateProxy
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = delegateProxy
        pip.requiresLinearPlayback = true
        #if os(iOS)
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        #endif

        attachGeneration &+= 1
        let generation = attachGeneration
        attachedLayer = layer
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
            let possible = ctrl.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.attachGeneration == generation, self.controller != nil else { return }
                if self.isPossible != possible {
                    self.isPossible = possible
                    self.onPossibleChange?(possible)
                }
            }
        }
    }

    func detach() {
        attachGeneration &+= 1
        possibleObservation?.invalidate()
        possibleObservation = nil
        if let pip = controller {
            if pip.isPictureInPictureActive {
                pip.stopPictureInPicture()
            }
            pip.delegate = nil
        }
        controller = nil
        attachedLayer = nil
        isStarting = false
        isActive = false
        isStopping = false
        if isPossible {
            isPossible = false
            onPossibleChange?(false)
        }
    }

    func setAutoStartFromInline(_ enabled: Bool) {
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        #endif
    }

    func setUserPaused(_ paused: Bool) {
        let changed = delegateProxy.setUserPaused(paused)
        if changed {
            controller?.invalidatePlaybackState()
        }
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Delegate callbacks (MainActor)

    fileprivate func handleWillStart() {
        restoredUIForCurrentStop = false
        isStarting = true
        isStopping = false
        onWillStart?()
    }

    fileprivate func handleDidStart() {
        isStarting = false
        isActive = true
        isStopping = false
        onDidStart?()
    }

    fileprivate func handleFailedToStart(_ error: Error) {
        isStarting = false
        isActive = false
        isStopping = false
        onFailedToStart?(error)
    }

    fileprivate func handleWillStop() {
        isStopping = true
    }

    fileprivate func handleDidStop() {
        let restored = restoredUIForCurrentStop
        restoredUIForCurrentStop = false
        isStarting = false
        isActive = false
        isStopping = false
        onDidStop?(restored)
    }

    fileprivate func handleSetPlaying(_ playing: Bool) {
        onSetPlaying?(playing)
    }

    fileprivate func handleRestoreUI(completion: @escaping @Sendable (Bool) -> Void) {
        restoredUIForCurrentStop = true
        if let onRestoreUI {
            onRestoreUI { restored in
                completion(restored)
            }
        } else {
            completion(true)
        }
    }
}

// MARK: - NSObject delegate bridge (Sendable-safe for nonisolated AVKit delegate protocols)

private final class PiPDelegateProxy: NSObject,
    AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cachedUserPaused = false
    weak var owner: TwitchPiPController?

    private func runOnMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

    func setUserPaused(_ paused: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard cachedUserPaused != paused else { return false }
        cachedUserPaused = paused
        return true
    }

    private func isUserPaused() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedUserPaused
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        runOnMain { [weak self] in
            self?.owner?.handleWillStart()
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        runOnMain { [weak self] in
            self?.owner?.handleDidStart()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        runOnMain { [weak self] in
            self?.owner?.handleFailedToStart(error)
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        runOnMain { [weak self] in
            self?.owner?.handleWillStop()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        runOnMain { [weak self] in
            self?.owner?.handleDidStop()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let finish = completionHandler
        runOnMain { [weak self] in
            guard let owner = self?.owner else {
                finish(true)
                return
            }
            owner.handleRestoreUI { restored in
                finish(restored)
            }
        }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        runOnMain { [weak self] in
            self?.owner?.handleSetPlaying(playing)
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        isUserPaused()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
