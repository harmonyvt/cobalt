import AVFoundation
import CobaltKit
import ImageIO
import SwiftUI
import Synchronization

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// Media plumbing for the orbit and the library previews: still images, animated webps, and the
// pool of looping players. Everything is muted and short.

/// A CGImage moved between threads once and never touched again.
struct ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Posters and other stills, decoded off the main thread at thumbnail size and cached. Flipbook frames
/// have their own cache (`FlipbookLoader`), so cycling through them never evicts a poster.
actor ImageLoader {
    static let shared = ImageLoader()
    /// Bounded: 64 posters at most.
    private let cache: NSCache<NSURL, ImageHolder> = {
        let c = NSCache<NSURL, ImageHolder>()
        c.countLimit = 64
        return c
    }()

    private final class ImageHolder: Sendable {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    func image(for url: URL, maxPixel: Int = 360) -> ImageBox? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.box }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let box = ImageBox(image)
        cache.setObject(ImageHolder(box), forKey: url as NSURL)
        return box
    }
}

/// The flipbook frames of the orbit's two inner bands, decoded off the main thread at thumbnail size
/// into a cache of its own, bounded by decoded bytes (about 12 MB: roughly 200 frames of 160 px).
actor FlipbookLoader {
    static let shared = FlipbookLoader()
    private let cache: NSCache<NSURL, FrameHolder> = {
        let c = NSCache<NSURL, FrameHolder>()
        c.totalCostLimit = 12 * 1024 * 1024
        c.countLimit = 400
        return c
    }()

    private final class FrameHolder: Sendable {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    func frame(for url: URL, maxPixel: Int = 160) -> ImageBox? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.box }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let box = ImageBox(image)
        cache.setObject(FrameHolder(box), forKey: url as NSURL, cost: max(1, image.bytesPerRow * image.height))
        return box
    }
}

/// The app's audio session policy: everything the app plays on its own (the orbit's players, trim
/// previews, the focused planet while muted) is `.ambient`, so it mixes with whatever the owner is
/// listening to and never interrupts it. Only a planet the owner has unmuted takes `.playback`, and
/// muting, closing or switching to the webp gives the session back.
@MainActor
enum AudioPolicy {
    /// Ambient, mixing: called whenever a player is created.
    static func ambient() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .ambient { try? session.setCategory(.ambient, mode: .default) }
        #endif
    }

    /// The owner unmuted a planet: it plays through the silent switch and takes the audio focus.
    static func playback() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    /// Back to ambient, and tell whoever was interrupted that they may resume.
    static func release() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// A still from a file, filling its frame. Blank until decoded.
struct StillImage: View {
    let url: URL
    @State private var image: ImageBox?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.25), value: image != nil)
            .task(id: url) { image = await ImageLoader.shared.image(for: url) }
    }
}

// MARK: - animated webp

private final class StopFlag: Sendable {
    private let flag = Mutex(false)
    func stop() { flag.withLock { $0 = true } }
    var isStopped: Bool { flag.withLock { $0 } }
}

/// ImageIO's animation callbacks arrive on its own queue, so this lives outside any actor.
private enum AnimationDriver {
    static func play(url: URL, stop: StopFlag, onFrame: @escaping @Sendable (ImageBox) -> Void) -> Bool {
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, image, halt in
            if stop.isStopped { halt.pointee = true; return }
            onFrame(ImageBox(image))
        }
        return status == noErr
    }

    static func play(data: Data, stop: StopFlag, onFrame: @escaping @Sendable (ImageBox) -> Void) -> Bool {
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { _, image, halt in
            if stop.isStopped { halt.pointee = true; return }
            onFrame(ImageBox(image))
        }
        return status == noErr
    }
}

@MainActor @Observable
private final class AnimatedImageModel {
    var image: ImageBox?
    var failed = false
    @ObservationIgnored private var stopFlag: StopFlag?

    func play(file url: URL) {
        stop()
        let flag = StopFlag()
        stopFlag = flag
        let ok = AnimationDriver.play(url: url, stop: flag) { [weak self] frame in
            Task { @MainActor in self?.image = frame }
        }
        failed = !ok
    }

    func play(data: Data) {
        stop()
        let flag = StopFlag()
        stopFlag = flag
        let ok = AnimationDriver.play(data: data, stop: flag) { [weak self] frame in
            Task { @MainActor in self?.image = frame }
        }
        failed = !ok
    }

    func stop() {
        stopFlag?.stop()
        stopFlag = nil
    }
}

/// An animated webp (or gif), from a file on disk or from the network. Shows nothing until the
/// first frame, so a poster underneath stays visible when decoding is not possible.
struct AnimatedImageView: View {
    enum Source: Equatable {
        case file(URL)
        case remote(URL)
    }
    let source: Source
    @State private var model = AnimatedImageModel()

    var body: some View {
        Color.clear
            .overlay {
                if let image = model.image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: source) {
                switch source {
                case .file(let url):
                    model.play(file: url)
                    #if DEBUG
                    // Evidence runs (`-previewWebp`) swap the preview's one-pixel placeholder for a real file a
                    // moment after it lands: look again until it decodes.
                    var tries = 0
                    while model.failed, tries < 30, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        model.play(file: url)
                        tries += 1
                    }
                    #endif
                case .remote(let url):
                    guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
                    model.play(data: data)
                }
            }
            .onDisappear { model.stop() }
    }
}

// MARK: - players

#if canImport(UIKit)
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }
}
#else
final class PlayerLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }
}
#endif

/// A planet's player, lent to its detail screen: the detail shows this very player (already playing, with
/// the picture on screen) instead of starting a second one, so the zoom carries the picture and the video
/// does not restart.
struct LentPlayer {
    let id: String
    let player: AVQueuePlayer
}

private struct LentPlayerKey: EnvironmentKey {
    static var defaultValue: LentPlayer? { nil }
}

extension EnvironmentValues {
    var lentPlayer: LentPlayer? {
        get { self[LentPlayerKey.self] }
        set { self[LentPlayerKey.self] = newValue }
    }
}

/// A pool of three muted looping players, bound to the three front-most orbit items.
@MainActor @Observable
final class OrbitPlayerPool {
    static let capacity = 3
    private(set) var players: [String: AVQueuePlayer] = [:]
    @ObservationIgnored private var loopers: [String: AVPlayerLooper] = [:]
    /// The planet whose detail is open: its player keeps playing under the detail (the detail shows it) and
    /// is still there, playing, when the detail goes away.
    @ObservationIgnored var lent: String?

    func lend(_ id: String) -> LentPlayer? {
        guard let player = players[id] else { return nil }
        lent = id
        return LentPlayer(id: id, player: player)
    }

    /// `front` is ordered front-most first; `sources` maps an id to its local file and duration.
    func sync(front: [String], sources: [String: (url: URL, duration: Double?)], active: Bool) {
        guard active else {
            stopAll()
            return
        }
        // a player that already runs for a front planet (handed over from the focus layer) stays, even
        // before the disk check has confirmed that planet's file
        let wanted = front.filter { sources[$0] != nil || players[$0] != nil }.prefix(Self.capacity)
        for id in players.keys where !wanted.contains(id) { remove(id) }
        if !wanted.isEmpty { AudioPolicy.ambient() }
        for id in wanted where players[id] == nil {
            guard let source = sources[id] else { continue }
            let item = AVPlayerItem(url: source.url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let length = min(3, source.duration ?? 3)
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: max(0.5, length), preferredTimescale: 600))
            loopers[id] = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
            players[id] = player
            player.play()
        }
    }

    /// The planet comes back from focus with its player: still playing, no restart, no black frame.
    func adopt(id: String, player: AVQueuePlayer, looper: AVPlayerLooper) {
        remove(id)
        AudioPolicy.ambient()
        player.isMuted = true
        loopers[id] = looper
        players[id] = player
        player.play()
    }

    func stopAll() {
        for id in Array(players.keys) where id != lent { remove(id) }
    }

    private func remove(_ id: String) {
        players[id]?.pause()
        loopers[id]?.disableLooping()
        loopers[id] = nil
        players[id] = nil
    }
}

/// A looping preview of one clip, or of its selection: muted, filling its frame.
struct LoopingPlayerView: View {
    let url: URL
    /// Plays only this span, looping (the trim preview); nil plays the first 3 s.
    var span: ClosedRange<Double>?
    @State private var holder = LoopHolder()

    var body: some View {
        Group {
            if let player = holder.player { PlayerSurface(player: player) } else { Color.clear }
        }
        .task(id: Key(url: url, lower: span?.lowerBound, upper: span?.upperBound)) {
            if span != nil {
                // a drag moves the span many times a second: wait for it to settle
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            holder.start(url: url, span: span)
        }
        .onDisappear { holder.stop() }
    }

    private struct Key: Hashable {
        let url: URL
        let lower: Double?
        let upper: Double?
    }
}

@MainActor @Observable
private final class LoopHolder {
    var player: AVPlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?

    func start(url: URL, span: ClosedRange<Double>?) {
        stop()
        AudioPolicy.ambient()
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        let lower = span?.lowerBound ?? 0
        let upper = span?.upperBound ?? 3
        let range = CMTimeRange(
            start: CMTime(seconds: lower, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.5, upper - lower), preferredTimescale: 600))
        looper = AVPlayerLooper(player: queue, templateItem: item, timeRange: range)
        player = queue
        queue.play()
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
    }
}

extension Pipeline {
    /// The run's first frame: the star's thumbnail and the focused planet's poster until the video plays.
    /// (Evidence runs with `-previewClip` swap the preview's grey gradient for that clip's first frame.)
    var posterFrame: CGImage? {
        #if DEBUG
        if let image = PreviewClip.poster { return image }
        #endif
        return frames.compactMap { $0 }.first?.image
    }
}
