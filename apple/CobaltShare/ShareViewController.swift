import CobaltKit
import Foundation
import SwiftUI
import Synchronization
import UIKit

/// The share extension's principal class. It loads what the host app shared, builds the
/// `ShareModel` (CobaltKit reads the input and starts the pipeline), hosts `ShareRootView`, and
/// completes the request when the model says the sheet is done.
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private var model: ShareModel?
    /// `complete` ran (the request is done) or a close is already under way: nothing left to save.
    private var closed = false
    /// Sizes the presented sheet to the content (no empty space under the card).
    private lazy var fitter = SheetFitter(anchor: self)
    private let openedAt = Date()
    /// Card or sheet, and where the island is (CONTRACT-SHARE-QUICK.md section 2a).
    private let stage = ShareStage(overlay: false)
    /// The quick card asked for the full-screen overlay; decided at init from the setting.
    private var wantsOverlay = false

    // MARK: - Presentation

    /// As early as possible: the host reads the principal controller's presentation style when it
    /// presents it. The quick card asks for `.overFullScreen` (clear, so the app you were in shows
    /// under the blur); the full-sheet setting keeps the system sheet.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        configurePresentation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePresentation()
    }

    private func configurePresentation() {
        wantsOverlay = !Settings.shared().shareFullSheet
        stage.overlay = wantsOverlay
        if wantsOverlay {
            modalPresentationStyle = .overFullScreen
            modalTransitionStyle = .crossDissolve
        }
    }

    /// The host honoured the overlay unless the extension still ended up in a sheet: then the compact
    /// sheet card is used (the fallback, logged).
    private func checkPresentation() {
        guard wantsOverlay, stage.overlay else { return }
        let sheet = sheetPresentationController ?? (presentationController as? UISheetPresentationController)
        let style = presentationController.map { "\($0.presentationStyle.rawValue) \(type(of: $0))" } ?? "none"
        Telemetry.log(.info, .share, "share presentation", data: ["overlay": .bool(sheet == nil), "style": .string(style)])
        #if DEBUG
        ShareDebug.log("presentation style=\(style) sheet=\(sheet != nil) frame=\(view.window?.frame ?? .zero) view=\(view.frame)")
        #endif
        if sheet != nil {
            stage.overlay = false
            model?.quickHoldSeconds = 0.6            // the sheet card's own beat (`ShareCore.quickHold`): no morph to wait for
            fitter.attach()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        stage.safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        stage.safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Telemetry.start(process: .share)
        Telemetry.log(.info, .share, "share opened", data: Telemetry.memoryData())
        CobaltFont.register()
        Task { await load() }
    }

    private func load() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let openApp: @MainActor (URL) async -> Bool = { [weak self] url in await self?.openHostApp(url) ?? false }
        let complete: @MainActor () -> Void = { [weak self] in self?.finish() }
        #if DEBUG
        let debugModel = await ShareDebug.model(inputItems: items, openApp: openApp, complete: complete)
        let model: ShareModel
        if let debugModel { model = debugModel } else { model = await ShareModel.live(inputItems: items, openApp: openApp, complete: complete) }
        ShareDebug.probeLiveActivity()
        #else
        let model = await ShareModel.live(inputItems: items, openApp: openApp, complete: complete)
        #endif
        // The overlay hands off when its island morph is over (it calls `finishQuickHold()`); until it
        // does, the hold only has a ceiling. Set before the server can answer.
        if stage.overlay { model.quickHoldSeconds = QuickOverlay.holdCeiling }
        self.model = model
        watchModality(model)
        watchQuick(model)

        let host = UIHostingController(rootView: ShareStageView(model: model, stage: stage, onFit: { [weak self] height in
            guard let self, !self.stage.overlay else { return }
            self.fitter.update(contentHeight: height)
        }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkPresentation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkPresentation()
        stage.safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        stage.safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        if !stage.overlay { fitter.attach() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !stage.overlay { fitter.attach() }
    }

    private func finish() {
        #if DEBUG
        ShareDebug.log("complete after \(String(format: "%.2f", Date().timeIntervalSince(openedAt))) s quick=\(String(describing: model?.quick))")
        #endif
        Telemetry.log(.info, .share, "share completed", data: Telemetry.memoryData())
        Telemetry.flush()
        closed = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Card or sheet

    /// The quick card sits in a small, undimmed sheet with no grabber (the app underneath stays in view);
    /// the full sheet is the usual dimmed one. Follows `model.quick` as the card hands off or expands.
    private func watchQuick(_ model: ShareModel) {
        fitter.compact = model.quick.showsCard
        #if DEBUG
        ShareDebug.log("quick \(String(describing: model.quick)) at \(String(format: "%.2f", Date().timeIntervalSince(openedAt))) s")
        #endif
        withObservationTracking {
            _ = model.quick
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.watchQuick(model)
            }
        }
    }

    // MARK: - Swiping the sheet away

    /// While a save or a webp is on the server for this sheet it cannot be swiped down: that would
    /// skip `close()`, which is what leaves the job and tells the owner (the notify bridge, or the
    /// "still making your webp" notification). The attempt is routed to `close()` instead.
    private func watchModality(_ model: ShareModel) {
        applyModality(for: model)
        withObservationTracking {
            _ = model.canContinueInBackground
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.watchModality(model)
            }
        }
    }

    private func applyModality(for model: ShareModel) {
        isModalInPresentation = model.canContinueInBackground
        if presentationController?.delegate == nil { presentationController?.delegate = self }
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        closeSheet()
    }

    /// Dismissed some other way (the host closed it): do what the close button would have done.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { closeSheet() }
    }

    private func closeSheet() {
        guard !closed, let model else { return }
        Telemetry.log(.info, .share, "share close requested")
        closed = true
        // The opt-in is a network call and the process goes soon after the sheet does: ask the
        // system to keep it until `close()` has finished (`ProcessInfo.performExpiringActivity` is
        // the extension-safe form of a background task).
        let done = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "cobalt share close") { expired in
            if expired { done.signal() } else { done.wait() }
        }
        Task {
            _ = await model.close()
            done.signal()
        }
    }

    /// Opening the host's app from a share extension is not an official API: walk the responder
    /// chain to the `UIApplication` and ask it to open the URL. Returns whether the system said it
    /// did; when it does nothing (or says no) the model posts a notification instead.
    private func openHostApp(_ url: URL) async -> Bool {
        // `-[UIApplication openURL:options:completionHandler:]`, the one `open(_:)` that exists on
        // iOS 18+. Objective-C types in the signature (NSURL, NSDictionary), so the call is ABI-exact.
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                return await withCheckedContinuation { continuation in
                    let once = ResumeOnce(continuation)
                    typealias Open = @convention(c) (
                        AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
                    ) -> Void
                    let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                    open(current, selector, url as NSURL, [:] as NSDictionary) { ok in once.resume(ok) }
                    // a completion that never comes counts as "did nothing"
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        once.resume(false)
                    }
                }
            }
            responder = current.next
        }
        return false
    }
}

/// Resumes a continuation exactly once, from whichever thread gets there first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Bool) {
        let taken = continuation.withLock { c -> CheckedContinuation<Bool, Never>? in
            defer { c = nil }
            return c
        }
        taken?.resume(returning: value)
    }
}
