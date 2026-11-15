#if os(iOS)
import CobaltKit
import UIKit

/// Where a tap really lands (owner, 2026-11-14: "after watching a video the library becomes uninteractable, but I can
/// still swap tabs"). A watcher on the window, never in the way: it recognises nothing, cancels nothing, delays nothing,
/// and runs beside every other gesture. For each short tap it records `hit`, the view UIKit delivers the tap to (class
/// names only). Only a tap that lands on nothing useful (no view, the window itself, or an empty
/// `UIViewControllerWrapperView`, the stuck-library symptom) pays for the full picture:
///  - `hit` as the whole chain of ancestors, and
///  - `under`: the deepest view drawn at that point regardless of whether it takes touches, with the reason it does not
///    (`!ui` user interaction off, `hidden`, `a0` invisible) for any ancestor that blocks it,
/// so a grid that stopped answering shows either what is lying on top of it or which of its ancestors turned off. An
/// ordinary tap costs one class name (8.17: the walk visited up to 4000 views after every tap).
/// Goes to the self-hosted log (`ui` "tap") and to PostHog (`tap_probe`, inside the replay). Names of views only: never
/// text, titles or links.
@MainActor
enum TouchProbe {
    private static var installed: Set<ObjectIdentifier> = []

    /// Watches every window of the app's scenes (cheap; call again whenever the scene becomes active).
    static func install() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !installed.contains(ObjectIdentifier(window)) {
                installed.insert(ObjectIdentifier(window))
                window.addGestureRecognizer(ProbeRecognizer())
            }
        }
    }

    private static var lastSent: TimeInterval = 0

    /// Told when a tap lands on an empty `UIViewControllerWrapperView` (the library's stuck zoom back; set by
    /// `LibraryController`).
    static var emptyWrapperTapped: (() -> Void)?

    fileprivate static func tapped(at point: CGPoint, in window: UIWindow) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSent > 0.4 else { return }
        lastSent = now
        let hit = window.hitTest(point, with: nil)
        let dead = hit == nil || hit === window
        let wrapper = hit.map { String(describing: type(of: $0)) == "UIViewControllerWrapperView" } ?? false
        if wrapper { emptyWrapperTapped?() }
        guard dead || wrapper else {
            // an ordinary tap: the leaf's name is all it costs
            var data: [String: TelemetryValue] = ["x": .int(Int(point.x)), "y": .int(Int(point.y))]
            if let hit { data["hit"] = .string(shortName(hit)) }
            Telemetry.log(.info, .ui, "tap", data: data)
            Analytics.event("tap_probe", values: data)
            return
        }
        // the names and the walk wait until the tap's own frames are drawn: done here they landed in the frame that
        // stops a fling or opens a page (8.15, scroll jitter)
        Task { @MainActor [weak window, weak hit] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let window else { return }
            describe(hit: hit, dead: dead, at: point, in: window)
        }
    }

    private static func describe(hit: UIView?, dead: Bool, at point: CGPoint, in window: UIWindow) {
        let hitChain = chain(from: hit, to: window)
        let drawn = deepestDrawn(at: point, in: window)
        var data: [String: TelemetryValue] = [
            "x": .int(Int(point.x)), "y": .int(Int(point.y)),
            "hit": .string(hitChain),
            "breadcrumbs": .string(Breadcrumbs.recent()),
        ]
        if let drawn, drawn !== hit {
            data["under"] = .string(chain(from: drawn, to: window, flags: true))
        }
        if dead { data["dead"] = .bool(true) }
        Telemetry.log(.info, .ui, "tap", data: data)
        Analytics.event("tap_probe", values: data)
    }

    /// `Leaf < Parent < … ` up to the window, class names shortened, repeats folded, at most 12.
    private static func chain(from view: UIView?, to window: UIWindow, flags: Bool = false) -> String {
        var names: [String] = []
        var current = view
        while let v = current, v !== window, names.count < 40 {
            var name = shortName(v)
            if flags {
                if !v.isUserInteractionEnabled { name += "!ui" }
                if v.isHidden { name += "!hidden" }
                if v.alpha < 0.01 { name += "!a0" }
            }
            if names.last != name { names.append(name) }
            current = v.superview
        }
        if names.count > 12 { names = Array(names.prefix(6)) + ["…"] + Array(names.suffix(5)) }
        return names.joined(separator: " < ")
    }

    private static func shortName(_ v: UIView) -> String {
        var s = String(describing: type(of: v))
        // SwiftUI's generic hosting types carry the whole view type in their names
        if let lt = s.firstIndex(of: "<") { s = String(s[..<lt]) }
        if let dot = s.lastIndex(of: ".") { s = String(s[s.index(after: dot)...]) }
        return String(s.prefix(40))
    }

    /// The deepest, front-most view whose bounds hold `point`, ignoring whether it takes touches (bounded walk).
    private static func deepestDrawn(at point: CGPoint, in window: UIWindow) -> UIView? {
        var visited = 0
        func walk(_ view: UIView) -> UIView? {
            visited += 1
            guard visited < 4000 else { return nil }
            for sub in view.subviews.reversed() {
                let p = sub.convert(point, from: window)
                guard sub.bounds.contains(p) else { continue }
                if let deeper = walk(sub) { return deeper }
                return sub
            }
            return nil
        }
        return walk(window)
    }
}

/// Recognises nothing: notes where a single short touch went, then fails, so every other gesture runs as if it were not
/// there.
private final class ProbeRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var began: (point: CGPoint, at: TimeInterval)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first, let window = view as? UIWindow {
            FrameMonitor.touchBegan(at: t.location(in: window))
        }
        if touches.count == 1, let t = touches.first, let window = view as? UIWindow {
            began = (t.location(in: window), t.timestamp)
        } else {
            began = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first, let window = view as? UIWindow {
            FrameMonitor.touchMoved(to: t.location(in: window))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        defer { began = nil; state = .failed; FrameMonitor.touchEnded() }
        guard let began, let t = touches.first, let window = view as? UIWindow else { return }
        let end = t.location(in: window)
        guard hypot(end.x - began.point.x, end.y - began.point.y) < 12, t.timestamp - began.at < 0.6 else { return }
        TouchProbe.tapped(at: end, in: window)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        FrameMonitor.touchEnded()
        began = nil
        state = .failed
    }

    override func reset() {
        FrameMonitor.touchEnded()
        began = nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}
#endif
