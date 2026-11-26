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

    var onViewsAdopted: (() -> Void)?

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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isAdoptingViews {
            ensureAdoptedAndLaidOut()
        }
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
            ensureAdoptedAndLaidOut()
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
        ensureAdoptedAndLaidOut()
    }

    /// Re-verifies both video views are mounted inside the PiP view hierarchy and laid out to current bounds.
    func ensureAdoptedAndLaidOut() {
        guard isAdoptingViews else { return }
        loadViewIfNeeded()
        let adopted = adoptVideoViewsIfNeeded()
        layoutVideoViews()
        if adopted {
            onViewsAdopted?()
        }
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
            ensureAdoptedAndLaidOut()
        }
    }

    @discardableResult
    private func adoptVideoViewsIfNeeded() -> Bool {
        guard let primaryView, let secondaryView else { return false }
        var didAdopt = false
        if primaryView.superview !== view {
            primaryView.removeFromSuperview()
            primaryView.translatesAutoresizingMaskIntoConstraints = true
            primaryView.autoresizingMask = []
            primaryView.isHidden = false
            primaryView.alpha = 1
            view.insertSubview(primaryView, at: 0)
            didAdopt = true
        }
        if secondaryView.superview !== view {
            secondaryView.removeFromSuperview()
            secondaryView.translatesAutoresizingMaskIntoConstraints = true
            secondaryView.autoresizingMask = []
            secondaryView.isHidden = false
            secondaryView.alpha = 1
            view.insertSubview(secondaryView, at: 1)
            didAdopt = true
        }
        if didAdopt, view.subviews.last !== insetBorderView {
            view.bringSubviewToFront(insetBorderView)
        }
        return didAdopt
    }

    private func layoutVideoViews() {
        guard let primaryView, let secondaryView else { return }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch layoutMode {
        case .focusInset:
            let roles = TwitchDualLayout.heroAndInset(focused: focusedSlot)
            let hero = roles.hero == .primary ? primaryView : secondaryView
            let inset = roles.inset == .primary ? primaryView : secondaryView

            hero.layer.cornerRadius = 0
            hero.clipsToBounds = true
            if hero.frame != bounds {
                hero.frame = bounds
            }

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
            if inset.frame != insetFrame {
                inset.frame = insetFrame
            }

            if insetBorderView.frame != insetFrame {
                insetBorderView.frame = insetFrame
            }
            insetBorderView.isHidden = false
            let desiredOrder: [UIView] = [hero, inset, insetBorderView]
            let managedOrder = view.subviews.filter { $0 === hero || $0 === inset || $0 === insetBorderView }
            if managedOrder != desiredOrder {
                view.bringSubviewToFront(hero)
                view.bringSubviewToFront(inset)
                view.bringSubviewToFront(insetBorderView)
            }

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
                let pFrame = CGRect(x: 0, y: 0, width: halfW, height: bounds.height)
                let sFrame = CGRect(x: halfW + spacing, y: 0, width: halfW, height: bounds.height)
                if primaryView.frame != pFrame { primaryView.frame = pFrame }
                if secondaryView.frame != sFrame { secondaryView.frame = sFrame }
            case .vertical:
                let halfH = (bounds.height - spacing) / 2
                let pFrame = CGRect(x: 0, y: 0, width: bounds.width, height: halfH)
                let sFrame = CGRect(x: 0, y: halfH + spacing, width: bounds.width, height: halfH)
                if primaryView.frame != pFrame { primaryView.frame = pFrame }
                if secondaryView.frame != sFrame { secondaryView.frame = sFrame }
            }
        }
    }
}

/// Manages `AVPictureInPictureController` backed by `TwitchDualPiPContentViewController` for dual-stream PiP on iOS.
@MainActor
final class TwitchDualPiPController {
    private(set) var isPossible = false
    private(set) var isStarting = false
    private(set) var isActive = false
    private(set) var isStopping = false

    var isOwningViews: Bool { isActive || isStarting }

    var onPossibleChange: ((Bool) -> Void)?
    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onDidStop: ((_ restoredUI: Bool) -> Void)?
    var onFailedToStart: ((Error) -> Void)?
    var onRestoreUI: ((@escaping @MainActor (Bool) -> Void) -> Void)?
    var onViewsAdopted: (() -> Void)?

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
        contentController.onViewsAdopted = { [weak self] in
            self?.onViewsAdopted?()
        }
    }

    deinit {
        possibleObservation?.invalidate()
    }

    /// Attaches dual-stream PiP to `sourceView` and configures the live `TwitchNativeVideoView` pair.
    /// Never swaps controller while PiP is starting or actively running.
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
        // Guard: never tear down or swap content source while PiP is starting or active.
        guard !isActive && !isStarting else { return }
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
        isStarting = false
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
        isStarting = true
        isStopping = false
        // Notify host BEFORE reparenting so in-app slot surfaces immediately stop reclaiming the video views.
        onWillStart?()
        contentController.beginAdoptingVideoViews()
    }

    fileprivate func handleDidStart() {
        isStarting = false
        isActive = true
        isStopping = false
        contentController.ensureAdoptedAndLaidOut()
        onDidStart?()
    }

    fileprivate func handleFailedToStart(_ error: Error) {
        contentController.endAdoptingVideoViews()
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

    private func runOnMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

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
}
#endif
