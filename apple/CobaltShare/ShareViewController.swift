import CobaltKit
import Foundation
import SwiftUI
import Synchronization
import UIKit

/// The share extension's principal class (CONTRACT-SHARE-QUICK.md section 9, CONTRACT-GALLERY.md 1.12).
///
/// By default it shows nothing that waits: `InstantShare.start` reads the shared link and asks the server what it is
/// (`ShareGalleryFlow`). One video or photo is queued as `POST /studio` with a URLSession upload, a quiet "saving to
/// cobalt" notification is posted when the owner already allowed them, and the request completes at once. Only four things
/// ever show a view:
///  - the compact gallery sheet, when the link is a post with several items (one height for its whole life);
///  - the one-line failure card, when the save could not even be queued;
///  - the full sheet, for a file (its upload runs in this process), and when the owner turned on
///    "show the full share sheet";
///  - nothing else. The quick card and its full-screen overlay are no longer presented (the host ignored
///    `.overFullScreen` on the owner's device and drew the overlay's blur as a grey sheet).
///
/// The view itself is clear: the host's system sheet may flash for the moment the request takes.
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private var model: ShareModel?
    /// The gallery flow (the instant path); nil for the full sheet.
    private var flow: ShareGalleryFlow?
    /// `complete` ran (the request is done) or a close is already under way: nothing left to save.
    private var closed = false
    /// Sizes the presented sheet to the content (no empty space around the card).
    private lazy var fitter = SheetFitter(anchor: self)
    private let openedAt = Date()
    /// Always the sheet: the overlay layout is never asked for (see the class comment).
    private let stage = ShareStage(overlay: false)
    /// Whether this process is showing the full sheet or the failure card (the fitter only matters then).
    private var showsContent = false

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        stage.safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        stage.safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // While nothing is shown the sheet has nothing to hold: ask for the smallest one a host that
        // sizes by this will give (the content, when there is any, replaces it).
        preferredContentSize = CGSize(width: 0, height: 8)
        Telemetry.start(process: .share)
        Telemetry.log(.info, .share, "share opened", data: Telemetry.memoryData())
        CobaltFont.register()
        Task { await start() }
    }

    // MARK: - What to do with the share

    private func start() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        #if DEBUG
        if await startDebugScenario(items) { return }
        #endif
        guard !Settings.shared().shareFullSheet else { await showFullSheet(items); return }
        switch await InstantShare.start(inputItems: items) {
        case .flow(let flow):
            run(flow)
        case .needsSheet:
            await showFullSheet(items)
        case .failed(let failure):
            showFailure(failure)
        }
    }

    // MARK: - The gallery flow

    /// The flow decides what the extension shows: nothing (a single item), the compact sheet (a gallery) or the one-line
    /// card. This watches it and does what it says; every request is the flow's, never this controller's.
    private func run(_ flow: ShareGalleryFlow) {
        self.flow = flow
        watch(flow)
    }

    private func watch(_ flow: ShareGalleryFlow) {
        apply(flow)
        guard flow.finish == nil else { return }
        withObservationTracking {
            _ = flow.sheetShown
            _ = flow.finish
            _ = flow.cardFailure
            _ = flow.isSending
        } onChange: { [weak self, weak flow] in
            Task { @MainActor in
                guard let self, let flow else { return }
                self.watch(flow)
            }
        }
    }

    private func apply(_ flow: ShareGalleryFlow) {
        // A request on its way cannot be swiped away: that would drop it.
        isModalInPresentation = flow.isSending
        if presentationController?.delegate == nil { presentationController?.delegate = self }
        if let finish = flow.finish {
            switch finish {
            case .sent, .cancelled:
                self.finish()
            case .openCobalt:
                Task { @MainActor in
                    _ = await openHostApp(URL(string: "cobalt-apple://open")!)
                    self.finish()
                }
            }
            return
        }
        guard !showsContent else { return }
        if flow.sheetShown {
            host(ShareGallerySheet(flow: flow, onFit: { [weak self] height in self?.fitter.update(contentHeight: height) }))
        } else if let failure = flow.cardFailure {
            showFailure(failure)
        }
    }

    // MARK: - The failure card

    private func showFailure(_ failure: InstantShare.Failure) {
        let openApp: @MainActor () -> Void = { [weak self] in
            Task { @MainActor in
                _ = await self?.openHostApp(URL(string: "cobalt-apple://open")!)
                self?.finish()
            }
        }
        let close: @MainActor () -> Void = { [weak self] in self?.finish() }
        host(InstantFailureView(failure: failure, openCobalt: { openApp() }, close: { close() }, onFit: { [weak self] height in
            self?.fitter.update(contentHeight: height)
        }))
    }

    // MARK: - The full sheet

    private func showFullSheet(_ items: [NSExtensionItem]) async {
        let openApp: @MainActor (URL) async -> Bool = { [weak self] url in await self?.openHostApp(url) ?? false }
        let complete: @MainActor () -> Void = { [weak self] in self?.finish() }
        let model = await ShareModel.live(inputItems: items, openApp: openApp, complete: complete)
        self.model = model
        watchModality(model)
        host(ShareStageView(model: model, stage: stage, onFit: { [weak self] height in
            self?.fitter.update(contentHeight: height)
        }))
    }

    #if DEBUG
    /// Simulator evidence (`/tmp/cobalt-sq/share-debug.json`): the sheet over `PreviewClient`.
    private func startDebugScenario(_ items: [NSExtensionItem]) async -> Bool {
        let openApp: @MainActor (URL) async -> Bool = { [weak self] url in await self?.openHostApp(url) ?? false }
        let complete: @MainActor () -> Void = { [weak self] in self?.finish() }
        ShareDebug.probeLiveActivity()
        if let flow = ShareDebug.galleryFlow() {
            flow.begin()
            run(flow)
            return true
        }
        guard let model = await ShareDebug.model(inputItems: items, openApp: openApp, complete: complete) else { return false }
        self.model = model
        watchModality(model)
        host(ShareStageView(model: model, stage: stage, onFit: { [weak self] height in
            self?.fitter.update(contentHeight: height)
        }))
        return true
    }
    #endif

    /// Puts a SwiftUI view in the controller, pinned to every edge, and sizes the sheet to it.
    private func host<Content: View>(_ content: Content) {
        let host = UIHostingController(rootView: content)
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
        showsContent = true
        fitter.attach()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        stage.safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        stage.safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        if showsContent { fitter.attach() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if showsContent { fitter.attach() }
    }

    private var completed = false

    private func finish() {
        guard !completed else { return }
        completed = true
        Telemetry.log(.info, .share, "share completed", data: ["ms": .int(Int(Date().timeIntervalSince(openedAt) * 1000))].merging(Telemetry.memoryData()) { a, _ in a })
        Telemetry.flush()
        closed = true
        extensionContext?.completeRequest(returningItems: nil)
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
        if let flow {
            // the gallery sheet: closing sends nothing (a request in flight is not closable, the flow ignores it)
            if !flow.isSending { flow.cancel() }
            return
        }
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
