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
        let model = await ShareModel.live(
            inputItems: items,
            openApp: { [weak self] url in await self?.openHostApp(url) ?? false },
            complete: { [weak self] in self?.finish() })
        self.model = model
        watchModality(model)

        let host = UIHostingController(rootView: ShareRootView(model: model, onFit: { [weak self] height in self?.fitter.update(contentHeight: height) }))
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fitter.attach()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitter.attach()
    }

    private func finish() {
        Telemetry.log(.info, .share, "share completed", data: Telemetry.memoryData())
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
