import CobaltKit
import Foundation
import Network
import Observation
import SwiftUI
import Synchronization

// Which mosaic tiles move (CONTRACT-LIBRARY2 decision 12): only webp faces, only while at least 80 % visible, at
// most 4 at once on iPhone and 8 on iPad and Mac (the ones nearest the centre of the viewport win), none
// while the scroll is moving (they resume 0.3 s after it settles), and none at all with Reduce Motion, Low Power
// Mode, an inactive scene or (for a webp that is not on this device) an expensive or constrained network.

/// What the system says that the budget cares about. Both callbacks arrive on system queues; the owner hops to
/// the main actor itself.
private final class SystemSignals: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var token: NSObjectProtocol?

    init(power: @escaping @Sendable (Bool) -> Void, network: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { @Sendable path in
            network(!path.isExpensive && !path.isConstrained)
        }
        monitor.start(queue: DispatchQueue(label: "com.capybaraharmony.cobalt.library.path"))
        token = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { @Sendable _ in
            power(ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    deinit {
        monitor.cancel()
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

@MainActor @Observable
final class AnimationBudget {
    /// A visible webp tile: where its centre is in the scroll content, and whether its bytes come from the network.
    struct Candidate: Equatable {
        var y: Double
        var remote: Bool
    }

    /// 4 on iPhone, 8 on iPad and Mac.
    let limit: Int
    /// The tiles that move right now (the only thing views read).
    private(set) var playing: Set<String> = []

    @ObservationIgnored private var visible: [String: Candidate] = [:]
    @ObservationIgnored private var centerY: Double = 0
    @ObservationIgnored private var scrolling = false
    @ObservationIgnored private var settled = true
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var networkOK = true
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var signals: SystemSignals?

    init(limit: Int) { self.limit = limit }

    /// Starts listening to Low Power Mode and the network path. Safe to call twice.
    func start() {
        guard signals == nil else { return }
        signals = SystemSignals(
            power: { [weak self] low in Task { @MainActor in self?.setLowPower(low) } },
            network: { [weak self] ok in Task { @MainActor in self?.setNetworkOK(ok) } })
    }

    func stop() {
        signals = nil
        settleTask?.cancel()
        if !playing.isEmpty { playing = [] }
    }

    // MARK: inputs

    /// A webp tile became visible (`candidate`) or stopped being (nil).
    func setVisible(_ id: String, _ candidate: Candidate?) {
        if visible[id] == candidate { return }
        visible[id] = candidate
        recompute()
    }

    /// The viewport centre in scroll content coordinates (read when the choice is made, not observed).
    func setCenter(_ y: Double) { centerY = y }

    /// The scroll is moving (any phase but idle): everything stops at once; 0.3 s after it settles, the choice is made again.
    func setScrolling(_ moving: Bool) {
        if moving {
            scrolling = true
            settled = false
            settleTask?.cancel()
            if !playing.isEmpty { playing = [] }
        } else if scrolling {
            scrolling = false
            settleTask?.cancel()
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.settled = true
                self?.recompute()
            }
        }
    }

    func setEnvironment(reduceMotion: Bool, sceneActive: Bool) {
        guard reduceMotion != self.reduceMotion || sceneActive != self.sceneActive else { return }
        self.reduceMotion = reduceMotion
        self.sceneActive = sceneActive
        recompute()
    }

    private func setLowPower(_ value: Bool) {
        lowPower = value
        recompute()
    }

    private func setNetworkOK(_ value: Bool) {
        guard value != networkOK else { return }
        networkOK = value
        recompute()
    }

    // MARK: the choice

    private var allowed: Bool { !reduceMotion && !lowPower && sceneActive && !scrolling && settled }

    /// The `limit` visible candidates nearest the viewport's centre (ties by id, so the choice is stable).
    func recompute() {
        guard allowed else {
            if !playing.isEmpty { playing = [] }
            return
        }
        let center = centerY
        let usable = visible.filter { !$0.value.remote || networkOK }
        let ranked = usable.sorted { a, b in
            let da = abs(a.value.y - center), db = abs(b.value.y - center)
            return da != db ? da < db : a.key < b.key
        }
        let next = Set(ranked.prefix(limit).map(\.key))
        if next != playing { playing = next }
    }
}

// MARK: - the moving picture

private final class StopFlag: Sendable {
    private let flag = Mutex(false)
    func stop() { flag.withLock { $0 = true } }
    var isStopped: Bool { flag.withLock { $0 } }
}

/// ImageIO's animation callback arrives on its own queue, so this lives outside any actor and the callback is
/// `@Sendable`; the owner hops to the main actor to show a frame.
private enum LibraryAnimationDriver {
    static func play(data: Data, stop: StopFlag, onFrame: @escaping @Sendable (ImageBox) -> Void) -> Bool {
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { @Sendable _, image, halt in
            if stop.isStopped { halt.pointee = true; return }
            onFrame(ImageBox(image))
        }
        return status == noErr
    }
}

@MainActor @Observable
private final class LibraryAnimator {
    var image: ImageBox?
    @ObservationIgnored private var stopFlag: StopFlag?

    func play(data: Data) {
        halt()
        let flag = StopFlag()
        stopFlag = flag
        _ = LibraryAnimationDriver.play(data: data, stop: flag) { @Sendable [weak self] frame in
            Task { @MainActor in self?.image = frame }
        }
    }

    func halt() {
        stopFlag?.stop()
        stopFlag = nil
    }
}

/// A tile's moving picture: the webp (this device's file, else its public link through the library cache),
/// drawn over the still while it is in the budget. A webp that cannot be read leaves the still alone.
struct LibraryAnimatedLayer: View {
    let url: URL
    @State private var animator = LibraryAnimator()

    var body: some View {
        Color.clear
            .overlay {
                if let image = animator.image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .task(id: url) {
                guard let data = try? await LibraryMediaCache.data(from: url), !Task.isCancelled else { return }
                animator.play(data: data)
            }
            .onDisappear { animator.halt() }
    }
}

/// One tile's slot in the budget: draws `LibraryAnimatedLayer` only while the budget lets this tile play. Its
/// own small view, so a change of the playing set re-evaluates only these, never the tiles.
struct TileAnimationSlot: View {
    let id: String
    let url: URL
    let budget: AnimationBudget

    var body: some View {
        if budget.playing.contains(id) {
            LibraryAnimatedLayer(url: url).transition(.opacity)
        }
    }
}
