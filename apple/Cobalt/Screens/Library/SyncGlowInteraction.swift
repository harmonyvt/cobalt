import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#else
import AppKit
#endif

/// What the owner's hands are doing, for the sync glow: where a finger (or on the Mac the pointer) is,
/// and how fast they are scrolling. It only listens: on iOS a recognizer that never recognizes and
/// never cancels or delays a touch, on the Mac a local event monitor that passes every event on. The
/// band reads it each frame and draws a pool of light under the finger and a brighter line while
/// scrolling. Reduce Motion turns all of it off in `SyncGlowComposer`.
@MainActor
final class SyncGlowInteraction {
    static let shared = SyncGlowInteraction()

    /// After a finger lifts (or the pointer stops), the pool fades over this long.
    static let fade: TimeInterval = 0.7
    /// A resting pointer keeps its pool this long before it fades.
    static let pointerRest: TimeInterval = 1.2
    /// Scrolling energy halves in about this long.
    static let scrollSettle: TimeInterval = 0.35

    /// Window coordinates of the last finger or pointer position. iOS: points from the window's top
    /// left. Mac: the window's base coordinates (from the bottom left).
    private(set) var point: CGPoint?
    private weak var window: AnyObject?
    private var touching = false
    private var pointer = false
    private var lastMove: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    private var scrollEnergy: Double = 0
    private var scrollAt: TimeInterval = 0
    private let bands = NSHashTable<SyncGlowRenderer>.weakObjects()
    #if os(macOS)
    private var monitor: Any?
    #endif

    private init() {}

    // MARK: bands

    func register(_ renderer: SyncGlowRenderer) {
        bands.add(renderer)
    }

    /// Something moved: every band that is resting starts its frames again.
    private func wake() {
        for band in bands.allObjects { band.interactionWoke() }
    }

    // MARK: reading

    /// The finger or pointer in `window`, if it belongs to that window.
    func point(in window: AnyObject?) -> CGPoint? {
        guard let point, let window, window === self.window else { return nil }
        return point
    }

    /// Whether this is a finger (or a pressed mouse) rather than a hovering pointer.
    var isTouch: Bool { !pointer || touching }

    /// 0...1: full while a finger is down, fading after it lifts. A pointer stays lit for a moment after
    /// it stops moving, then fades.
    func level(now: TimeInterval) -> Float {
        if touching { return 1 }
        let since: TimeInterval
        if pointer {
            since = now - lastMove - Self.pointerRest
            if since <= 0 { return 1 }
        } else {
            since = now - releasedAt
        }
        guard since < Self.fade else { return 0 }
        let p = max(0, since / Self.fade)
        return Float(1 - p * p)
    }

    /// 0...1, decaying since the last scroll.
    func scroll(now: TimeInterval) -> Float {
        guard scrollEnergy > 0 else { return 0 }
        let value = scrollEnergy * pow(0.5, (now - scrollAt) / Self.scrollSettle)
        return value < 0.01 ? 0 : Float(min(value, 1))
    }

    /// Whether anything here still moves the light, so the band keeps drawing.
    func isLive(now: TimeInterval) -> Bool {
        level(now: now) > 0 || scroll(now: now) > 0
    }

    // MARK: writing

    private func moved(to point: CGPoint, in window: AnyObject, pointer: Bool) {
        let resting = !isLive(now: CACurrentMediaTime())
        self.point = point
        self.window = window
        self.pointer = pointer
        lastMove = CACurrentMediaTime()
        if resting { wake() }
    }

    func touchBegan(at point: CGPoint, in window: AnyObject) {
        touching = true
        moved(to: point, in: window, pointer: false)
        wake()
    }

    func touchMoved(to point: CGPoint, in window: AnyObject, verticalSpeed: Double) {
        moved(to: point, in: window, pointer: false)
        // 2500 points a second is a hard flick.
        scrolled(min(abs(verticalSpeed) / 2500, 1))
    }

    func touchEnded() {
        guard touching else { return }
        touching = false
        releasedAt = CACurrentMediaTime()
        if pointer { lastMove = releasedAt - Self.pointerRest }
    }

    func pointerMoved(to point: CGPoint, in window: AnyObject) {
        moved(to: point, in: window, pointer: true)
    }

    func pointerLeft() {
        guard pointer, !touching else { return }
        // Fade from now, as if it had rested.
        lastMove = CACurrentMediaTime() - Self.pointerRest
    }

    /// `amount` 0...1 for one scroll step or one finger move; the strongest recent one wins and decays.
    func scrolled(_ amount: Double) {
        guard amount.isFinite, amount > 0 else { return }
        let now = CACurrentMediaTime()
        let resting = !isLive(now: now)
        let current = Double(scroll(now: now))
        scrollEnergy = min(max(current, amount), 1)
        scrollAt = now
        if resting { wake() }
    }

    // MARK: listening

    #if os(iOS)
    /// Puts the listening recognizer on `window`, once.
    func attach(to window: UIWindow) {
        if window.gestureRecognizers?.contains(where: { $0 is SyncGlowTouchRecognizer }) == true { return }
        window.addGestureRecognizer(SyncGlowTouchRecognizer())
    }
    #else
    /// Lets `window` report pointer moves, and starts the one local monitor.
    func attach(to window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .mouseExited]
        ) { event in
            MainActor.assumeIsolated { SyncGlowInteraction.shared.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            // Trackpads report points, mouse wheels report lines.
            let delta = abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) * 0.5
            scrolled(min(delta * (event.hasPreciseScrollingDeltas ? 0.012 : 0.12), 1))
            if let window = event.window { pointerMoved(to: event.locationInWindow, in: window) }
        case .mouseExited:
            pointerLeft()
        case .leftMouseDown:
            if let window = event.window { touchBegan(at: event.locationInWindow, in: window) }
            pointer = true
        case .leftMouseUp:
            touchEnded()
        default:
            if let window = event.window { pointerMoved(to: event.locationInWindow, in: window) }
        }
    }
    #endif
}

#if os(iOS)
/// Listens to every touch in its window and never takes part: it does not recognize, cancel or
/// delay anything, and it lets every other recognizer run alongside it.
final class SyncGlowTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let window = view as? UIWindow else { return }
        SyncGlowInteraction.shared.touchBegan(at: touch.location(in: window), in: window)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let window = view as? UIWindow else { return }
        let now = touch.location(in: window)
        let before = touch.previousLocation(in: window)
        let dt = max(touch.timestamp - lastStamp, 1.0 / 120)
        lastStamp = touch.timestamp
        SyncGlowInteraction.shared.touchMoved(to: now, in: window, verticalSpeed: Double(now.y - before.y) / dt)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(event)
    }

    private var lastStamp: TimeInterval = 0

    /// Once the last finger is up this recognizer fails, so the system resets it for the next touch.
    private func finish(_ event: UIEvent) {
        let down = event.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled } ?? false
        guard !down else { return }
        SyncGlowInteraction.shared.touchEnded()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        false
    }
}
#endif
