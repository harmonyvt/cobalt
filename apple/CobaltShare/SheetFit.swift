import OSLog
import UIKit

/// Makes the presented sheet as tall as the SwiftUI content (the card and what is in it) and no
/// taller: a custom detent whose height is the content's height plus the safe area under it, capped
/// at the largest detent (past that the content scrolls, see `ShareRootView`).
///
/// One resize per real change: heights are rounded up to whole points, changes under 2 pt are
/// ignored, and a burst of layout passes (a card swapping its content) is coalesced into a single
/// `animateChanges { invalidateDetents() }`. The SwiftUI side does not animate layout height, so the
/// sheet is the only thing moving. The full sheet always hugs its content: it never asks for the
/// full-screen overlay (whose blur showed as a grey area above the card in a host that ignored it).
///
/// Which object owns the sheet in a share extension is not documented, so `attach()` looks at every
/// candidate, logs which ones exist (category `sheet-fit`, also `NSLog` so `simctl log show` sees it),
/// and applies the detent to the first one that does. `preferredContentSize` is set only while no
/// sheet was found (the fallback for a host that sizes by that instead).
@MainActor
final class SheetFitter {
    static let detentID = UISheetPresentationController.Detent.Identifier("fit")

    private weak var anchor: UIViewController?
    private weak var sheet: UISheetPresentationController?
    /// The content's height as last accepted (whole points).
    private(set) var contentHeight: CGFloat = 0
    private var pendingHeight: CGFloat = 0
    private var flush: Task<Void, Never>?
    /// Where the sheet was found ("none" until it is).
    private(set) var source = "none"
    private var logged = false
    private let logger = Logger(subsystem: "com.capybaraharmony.cobalt", category: "sheet-fit")

    /// The quick card (CONTRACT-SHARE-QUICK.md): no grabber and no dimming up to the fitted detent, so
    /// the app underneath stays in view and the card reads as a floating card, not a sheet. False: the
    /// full sheet, dimmed as usual.
    var compact = false {
        didSet {
            guard compact != oldValue, let sheet else { return }
            sheet.animateChanges { self.style(sheet) }
        }
    }

    init(anchor: UIViewController) {
        self.anchor = anchor
    }

    /// The detent's height. A custom detent is measured above the sheet's bottom safe area (the
    /// sheet ends up `fittedHeight + safeAreaInsets.bottom` tall: measured on iOS 26.5, 416 for a 382
    /// detent with a 34 pt inset), so the content height is the whole answer: the card's own bottom
    /// padding is the margin, the safe area is added by the system.
    var fittedHeight: CGFloat { contentHeight }

    /// The content's height (SwiftUI reports every layout change).
    func update(contentHeight height: CGFloat) {
        let whole = height.rounded(.up)
        guard whole > 0 else { return }
        pendingHeight = whole
        // The first height goes straight in; after that anything under 2 pt is noise (a progress
        // line's digits), and the rest waits a moment so one change is one resize.
        if contentHeight == 0 {
            apply(whole)
            return
        }
        guard abs(whole - contentHeight) >= 2 else { return }
        flush?.cancel()
        flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.pendingHeight)
        }
    }

    private func apply(_ height: CGFloat) {
        guard abs(height - contentHeight) >= 1 || contentHeight == 0 else { return }
        contentHeight = height
        // Both ways to size the sheet are given, always: a host that sizes an extension by
        // `preferredContentSize` (the owner's iOS 27 host drew a grey area around a card that only asked
        // for a detent) and a `UISheetPresentationController` we can reach. Neither can hurt the other.
        anchor?.preferredContentSize = CGSize(width: 0, height: fittedHeight)
        if let sheet {
            sheet.animateChanges { sheet.invalidateDetents() }
            report("resize")
        } else {
            attach()
        }
    }

    /// Finds the sheet and gives it the detent. Cheap to call again (the controller does, on appear
    /// and on layout, until it has found one).
    func attach() {
        guard contentHeight > 0, sheet == nil, let anchor else { return }
        let candidates = candidateSheets(from: anchor)
        if !logged {
            logged = true
            let line = candidates.map { "\($0.name)=\($0.sheet == nil ? "nil" : "SHEET")" }.joined(separator: " ")
            logger.notice("candidates: \(line, privacy: .public)")
            NSLog("sheet-fit candidates: \(line)")
        }
        guard let found = candidates.first(where: { $0.sheet != nil }), let sheet = found.sheet else { return }
        self.sheet = sheet
        source = found.name
        sheet.detents = [
            .custom(identifier: Self.detentID) { [weak self] context in
                guard let self else { return nil }
                return MainActor.assumeIsolated { min(self.fittedHeight, context.maximumDetentValue) }
            }
        ]
        sheet.selectedDetentIdentifier = Self.detentID
        style(sheet)
        logger.notice("custom detent applied via \(found.name, privacy: .public)")
        NSLog("sheet-fit applied via \(found.name)")
        report("applied")
    }

    private func style(_ sheet: UISheetPresentationController) {
        sheet.prefersGrabberVisible = false
        sheet.largestUndimmedDetentIdentifier = compact ? Self.detentID : nil
        sheet.prefersScrollingExpandsWhenScrolledToEdge = !compact
    }

    /// One line per resize: what the content measured, what the detent asks for, and what the sheet
    /// and the hosted view actually are once the animation has settled.
    private func report(_ why: String) {
        let content = contentHeight, fitted = fittedHeight
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, let anchor = self.anchor else { return }
            let sheetH = self.sheet?.presentedViewController.view.superview?.frame.height ?? -1
            let line = "\(why) compact=\(self.compact) content=\(content) inset=\(anchor.view.safeAreaInsets.bottom) fitted=\(fitted) viewH=\(anchor.view.bounds.height) sheetContainerH=\(sheetH)"
            self.logger.notice("\(line, privacy: .public)")
            NSLog("sheet-fit \(line)")
        }
    }

    private func candidateSheets(from anchor: UIViewController) -> [(name: String, sheet: UISheetPresentationController?)] {
        var list: [(String, UISheetPresentationController?)] = [
            ("self.sheetPresentationController", anchor.sheetPresentationController),
            ("self.presentationController", anchor.presentationController as? UISheetPresentationController),
            ("parent.sheetPresentationController", anchor.parent?.sheetPresentationController),
            ("navigationController.sheetPresentationController", anchor.navigationController?.sheetPresentationController),
            ("presentingViewController.presentedViewController", (anchor.presentingViewController?.presentedViewController?.presentationController as? UISheetPresentationController)),
        ]
        // Last resort: the window's own presentation chain.
        var vc = anchor.view.window?.rootViewController
        var depth = 0
        while let current = vc, depth < 6 {
            list.append(("window.root+\(depth) (\(type(of: current)))", current.presentationController as? UISheetPresentationController))
            vc = current.presentedViewController
            depth += 1
        }
        return list
    }
}
