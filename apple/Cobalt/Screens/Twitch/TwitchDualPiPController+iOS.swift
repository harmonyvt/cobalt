#if os(iOS)
@preconcurrency import AVFoundation
import AVKit
import CobaltKit
import UIKit

// Dual-Stream Picture-in-Picture on iOS (Wave 2).
//
// Uses `AVPictureInPictureVideoCallViewController` + `AVPictureInPictureController.ContentSource(
// activeVideoCallSourceView:contentViewController:)` so BOTH live `AVSampleBufferDisplayLayer`-backed
// `TwitchNativeVideoView`s render inside one system PiP window with zero pixel-buffer compositing,
// zero extra hardware decode, and ZERO `voip` background mode (App Review Guideline 2.5.4).
//
// Invariants:
// - Single-stream PiP (`TwitchPiPController`) and dual-stream PiP (`TwitchDualPiPController`) are
//   switched ONLY while PiP is inactive.
// - While PiP is inactive, this controller NEVER steals `primaryView` / `secondaryView` away from
//   the in-app `TwitchDualStage`. It adopts them in `willStart` and yields them back in `didStop`.

/// `AVPictureInPictureVideoCallViewController` that lays out both live `TwitchNativeVideoView`s
/// in either 16:9 Focus + Inset (default) or 50/50 split.
@MainActor
final class TwitchDualPiPContentViewController: AVPictureInPictureVideoCallViewController {
    private weak var primaryView: TwitchNativeVideoView?
    private weak var secondaryView: TwitchNativeVideoView?
    private var focusedSlot: TwitchDualSlot = .primary
    private var layoutMode: TwitchDualStageMode = .focusInset
    private var isAdoptingViews = false

    private let insetBorderView: UIView = {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.layer.cornerRadius = 10
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1.5
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.32).cgColor
        v.isHidden = true
        return v
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.addSubview(insetBorderView)
        preferredContentSize = CGSize(width: 1920, height: 1080)
    }

    func configure(
        primaryView: TwitchNativeVideoView,
        secondaryView: TwitchNativeVideoView,
        focusedSlot: TwitchDualSlot,
        layoutMode: TwitchDualStageMode
    ) {
        self.primaryView = primaryView
        self.secondaryView = secondaryView
        self.focusedSlot = focusedSlot
        self.layoutMode = layoutMode
        preferredContentSize = CGSize(width: 1920, height: 1080)
        if isAdoptingViews {
            adoptVideoViewsIfNeeded()
            layoutVideoViews()
        }
    }

    func updateLayout(focusedSlot: TwitchDualSlot, layoutMode: TwitchDualStageMode) {
        guard self.focusedSlot != focusedSlot || self.layoutMode != layoutMode else { return }
        self.focusedSlot = focusedSlot
        self.layoutMode = layoutMode
        if isAdoptingViews {
            layoutVideoViews()
        }
    }

    /// Moves both `TwitchNativeVideoView`s into the PiP view hierarchy right as PiP starts.
    func beginAdoptingVideoViews() {
        isAdoptingViews = true
        loadViewIfNeeded()
        adoptVideoViewsIfNeeded()
        layoutVideoViews()
    }

    /// Releases both `TwitchNativeVideoView`s once PiP has stopped so the in-app stage can re-adopt them cleanly.
    func endAdoptingVideoViews() {
        isAdoptingViews = false
        if primaryView?.superview === view {
            primaryView?.layer.cornerRadius = 0
            primaryView?.clipsToBounds = false
            primaryView?.removeFromSuperview()
        }
        if secondaryView?.superview === view {
            secondaryView?.layer.cornerRadius = 0
            secondaryView?.clipsToBounds = false
            secondaryView?.removeFromSuperview()
        }
        insetBorderView.isHidden = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if isAdoptingViews {
            layoutVideoViews()
        }
    }

    private func adoptVideoViewsIfNeeded() {
        guard let primaryView, let secondaryView else { return }
        if primaryView.superview !== view {
            primaryView.removeFromSuperview()
            primaryView.autoresizingMask = []
            view.insertSubview(primaryView, at: 0)
        }
        if secondaryView.superview !== view {
            secondaryView.removeFromSuperview()
            secondaryView.autoresizingMask = []
            view.insertSubview(secondaryView, at: 1)
        }
        view.bringSubviewToFront(insetBorderView)
    }

    private func layoutVideoViews() {
        guard let primaryView, let secondaryView else { return }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        switch layoutMode {
        case .focusInset:
            let roles = TwitchDualLayout.heroAndInset(focused: focusedSlot)
            let hero = roles.hero == .primary ? primaryView : secondaryView
            let inset = roles.inset == .primary ? primaryView : secondaryView

            hero.layer.cornerRadius = 0
            hero.clipsToBounds = true
            hero.frame = bounds

            let margin: CGFloat = max(8, (bounds.width * 0.03).rounded())
            let insetSize = TwitchDualLayout.insetSize(
                for: bounds.size,
                widthFraction: 0.34,
                minWidth: min(96, bounds.width * 0.42),
                maxWidth: bounds.width * 0.44
            )
            let insetFrame = CGRect(
                x: bounds.maxX - insetSize.width - margin,
                y: bounds.maxY - insetSize.height - margin,
                width: insetSize.width,
                height: insetSize.height
            )
            inset.layer.cornerRadius = 10
            inset.layer.cornerCurve = .continuous
            inset.clipsToBounds = true
            inset.frame = insetFrame

            view.bringSubviewToFront(hero)
            view.bringSubviewToFront(inset)
            insetBorderView.frame = insetFrame
            insetBorderView.isHidden = false
            view.bringSubviewToFront(insetBorderView)

        case .split5050:
            insetBorderView.isHidden = true
            primaryView.layer.cornerRadius = 0
            secondaryView.layer.cornerRadius = 0
            primaryView.clipsToBounds = true
            secondaryView.clipsToBounds = true

            let spacing: CGFloat = 2
            switch TwitchDualLayout.splitAxis(for: bounds.size) {
            case .horizontal:
                let halfW = (bounds.width - spacing) / 2
                primaryView.frame = CGRect(x: 0, y: 0, width: halfW, height: bounds.height)
                secondaryView.frame = CGRect(x: halfW + spacing, y: 0, width: halfW, height: bounds.height)
            case .vertical:
                let halfH = (bounds.height - spacing) / 2
                primaryView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: halfH)
                secondaryView.frame = CGRect(x: 0, y: halfH + spacing, width: bounds.width, height: halfH)
            }
        }
    }
}

/// Manages `AVPictureInPictureController` backed by `TwitchDualPiPContentViewController` for dual-stream PiP on iOS.
@MainActor
final class TwitchDualPiPController {
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var isStopping = false

    var onPossibleChange: ((Bool) -> Void)?
    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onDidStop: ((_ restoredUI: Bool) -> Void)?
    var onFailedToStart: ((Error) -> Void)?
    var onRestoreUI: ((@escaping @MainActor (Bool) -> Void) -> Void)?

    private var controller: AVPictureInPictureController?
    private let contentController = TwitchDualPiPContentViewController()
    private weak var attachedSourceView: UIView?
    private var possibleObservation: NSKeyValueObservation?
    private let delegateProxy = DualPiPDelegateProxy()
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

    /// Attaches dual-stream PiP to `sourceView` and configures the live `TwitchNativeVideoView` pair.
    /// Never swaps controller while PiP is actively running.
    func attach(
        sourceView: UIView,
        primaryView: TwitchNativeVideoView,
        secondaryView: TwitchNativeVideoView,
        focusedSlot: TwitchDualSlot,
        layoutMode: TwitchDualStageMode
    ) {
        guard Self.isSupported else { return }
        contentController.configure(
            primaryView: primaryView,
            secondaryView: secondaryView,
            focusedSlot: focusedSlot,
            layoutMode: layoutMode
        )
        // Guard: never tear down or swap content source while PiP is active.
        guard !isActive else { return }
        if attachedSourceView === sourceView, controller != nil { return }
        detach()

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentController
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = delegateProxy
        pip.canStartPictureInPictureAutomaticallyFromInline = false

        attachGeneration &+= 1
        let generation = attachGeneration
        attachedSourceView = sourceView
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

    func updateLayout(focusedSlot: TwitchDualSlot, layoutMode: TwitchDualStageMode) {
        contentController.updateLayout(focusedSlot: focusedSlot, layoutMode: layoutMode)
    }

    func setAutoStartFromInline(_ enabled: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
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
        contentController.endAdoptingVideoViews()
        controller = nil
        attachedSourceView = nil
        isActive = false
        isStopping = false
        if isPossible {
            isPossible = false
            onPossibleChange?(false)
        }
    }

    // MARK: - Delegate callbacks (MainActor)

    fileprivate func handleWillStart() {
        restoredUIForCurrentStop = false
        isStopping = false
        contentController.beginAdoptingVideoViews()
        onWillStart?()
    }

    fileprivate func handleDidStart() {
        isActive = true
        isStopping = false
        onDidStart?()
    }

    fileprivate func handleFailedToStart(_ error: Error) {
        contentController.endAdoptingVideoViews()
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
        isActive = false
        isStopping = false
        contentController.endAdoptingVideoViews()
        onDidStop?(restored)
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

private final class DualPiPDelegateProxy: NSObject, AVPictureInPictureControllerDelegate, @unchecked Sendable {
    weak var owner: TwitchDualPiPController?

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.owner?.handleWillStart()
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.owner?.handleDidStart()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.owner?.handleFailedToStart(error)
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.owner?.handleWillStop()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.owner?.handleDidStop()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let finish = completionHandler
        Task { @MainActor [weak self] in
            guard let owner = self?.owner else {
                finish(true)
                return
            }
            owner.handleRestoreUI { restored in
                finish(restored)
            }
        }
    }
}
#endif
