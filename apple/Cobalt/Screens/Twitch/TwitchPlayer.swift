@preconcurrency import AVFoundation
import CobaltKit
import QuartzCore
import SwiftUI
import WebKit

// The stream (APP-API-CONTRACT 70, 70.4): two playback engines share one app-wide host (`TwitchPlayerHost.shared`), and the
// owner can switch between them at any time:
//
// 1. Low latency (default): pure-Swift `#EXT-X-TWITCH-PREFETCH` -> MPEG-TS demuxer -> `AVSampleBufferDisplayLayer` +
//    `AVSampleBufferAudioRenderer` (`TwitchNativeEngine`). Zero third-party deps, sub-2 s latency, and automatic fallback to
//    the Twitch embed if a channel needs an unsupported codec or Twitch enforces an integrity check.
// 2. Twitch embed: Twitch's interactive `Twitch.Player` (`embed/v1.js`) in a `WKWebView`, loaded first-party as
//    `www.twitch.tv` so WebKit shares sign-in cookies (falling back to the web app's domain if first-party doesn't come up
//    within `firstPartyWait`).
//
// One player for the whole app (`TwitchPlayerHost.shared`): a `TwitchPlayer` view adopts the active view (native display layer
// or web view), so moving the stream between layouts or to the TV window reparents it without a reload.
//
// The app leaving the screen (iOS background, Mac hidden) stops the stream unless capystore's TV window is showing it; it
// starts again on return if a view still wants it. Five minutes stopped with no view wanting it, or a memory warning, lets
// unused views go (rebuilt on the next claim). The Twitch sign-in stays in the default website data store, so it survives
// both restarts and mode switches (and native playback reads its `auth-token` cookie when present).

enum TwitchPlayerMode: String, CaseIterable, Sendable {
    case lowLatency
    case embed
}

enum TwitchEmbed {
    /// Where the page is loaded as: first party to Twitch, so the embed sees the sign-in's cookies.
    static let firstParty = URL(string: "https://www.twitch.tv/")!
    /// The fallback: the web app's domain. Plays, but the embed can never be signed in there (third-party cookies).
    static let fallback = URL(string: "https://cobalt.capybaraharmony.com/")!
    static let handler = "twitch"
    /// How long the embed may take to say it is ready on the first-party page before the app falls back.
    static let firstPartyWait: Duration = .seconds(15)

    static func safe(_ channel: String) -> String {
        channel.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The player page for `channel`, to load with `baseURL: base` (`parent` must be the page's own domain).
    static func html(channel: String, base: URL) -> String {
        let c = safe(channel)
        let parent = base.host() ?? "localhost"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        #p,#p iframe{border:0;position:absolute;inset:0;width:100%;height:100%}</style></head><body>
        <div id="p"></div>
        <script src="https://player.twitch.tv/js/embed/v1.js"></script>
        <script>
        (function () {
          var ch = "\(c)", player = null;
          function post(m) { try { window.webkit.messageHandlers.\(handler).postMessage(m); } catch (e) {} }
          function build() {
            document.getElementById("p").innerHTML = "";
            player = new Twitch.Player("p", { channel: ch, parent: ["\(parent)"], width: "100%", height: "100%",
                                              autoplay: true, muted: false });
            var E = Twitch.Player;
            player.addEventListener(E.READY, function () { post({ e: "ready" }); });
            player.addEventListener(E.PLAYING, function () { post({ e: "playing" }); });
            player.addEventListener(E.PAUSE, function () { post({ e: "paused" }); });
            player.addEventListener(E.OFFLINE, function () { post({ e: "offline" }); });
            player.addEventListener(E.ONLINE, function () { post({ e: "online" }); });
          }
          setInterval(function () {
            if (!player) return;
            try {
              var s = player.getPlaybackStats() || {};
              post({ e: "stats", delay: Number(s.hlsLatencyBroadcaster) || 0, buffer: Number(s.bufferSize) || 0,
                     paused: !!player.isPaused() });
            } catch (e) {}
          }, 1000);
          // Live has no seek: a pause and play lands on the live edge; a rebuild is the stronger step.
          window.cobaltJumpToLive = function () {
            if (!player) return;
            player.pause();
            setTimeout(function () { player.play(); }, 150);
          };
          window.cobaltPause = function () { if (player) player.pause(); };
          window.cobaltPlay = function () { if (player) player.play(); };
          window.cobaltRebuild = build;
          window.cobaltSetChannel = function (c) { ch = c; if (player) { player.setChannel(c); } else { build(); } };
          if (window.Twitch && Twitch.Player) { build(); } else { post({ e: "noembed" }); }
        })();
        </script>
        </body></html>
        """
    }

    /// The persistent `.default()` data store keeps the Twitch sign-in's cookies when the web view is let go and rebuilt.
    @MainActor static func configuration(handler proxy: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        config.websiteDataStore = .default()
        config.userContentController.add(proxy, name: handler)
        return config
    }
}

/// Platform view backed by an `AVSampleBufferDisplayLayer` for low-latency native playback.
#if os(iOS)
final class TwitchNativeVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // Guaranteed by `layerClass`.
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Platform view backed by an `AVPlayerLayer` for Video-Only AirPlay handoff while in low-latency mode.
final class TwitchAirPlayVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Guaranteed by `layerClass`.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
#else
final class TwitchNativeVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(displayLayer)
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
#endif

/// The app's one Twitch player. Views adopt its active surface with `TwitchPlayer(channel:)`; the latest view to appear holds
/// it, and when that view goes the one before it takes it back (the TV window can borrow the stream from the phone this way).
/// With no view left the stream stops.
@MainActor @Observable
final class TwitchPlayerHost: LifecycleAware, Purgeable, TwitchDualAudioTarget {
    static let shared = TwitchPlayerHost()

    /// How long a stopped stream with no view wanting it keeps its views (and WebKit's page process) around.
    static let releaseAfter: Duration = .seconds(300)

    /// How far behind its best the stream may drift before it counts as behind (seconds).
    static let behindBy: Double = 2.5
    /// Seconds in a row the stream must be behind before an automatic jump to live.
    static let autoAfterSeconds: TimeInterval = 8
    /// Least time between two automatic jumps (seconds).
    static let autoCooldown: TimeInterval = 45

    private static let modeKey = "twitch.player.mode"
    private static let qualityKey = "twitch.player.quality"

    /// The owner's chosen mode, persisted across runs.
    private(set) var preferredMode: TwitchPlayerMode
    /// The engine actually running for the current channel (differs from `preferredMode` only during auto-fallback).
    private(set) var activeMode: TwitchPlayerMode
    /// True when low-latency playback failed on this channel and the host automatically switched to the Twitch embed.
    private(set) var fellBackToEmbed = false

    /// The primary channel playing now, nil while stopped.
    private(set) var channel: String?
    /// The secondary channel playing in dual-stream mode, nil in single-stream mode.
    private(set) var secondaryChannel: String?
    /// True when two concurrent Twitch streams are active.
    var isDualStream: Bool { channel != nil && secondaryChannel != nil }
    /// Dual-stream visual layout mode (Focus + Inset default; 1-tap 50/50 toggle).
    var dualStageMode: TwitchDualStageMode = .focusInset {
        didSet {
            guard dualStageMode != oldValue else { return }
            syncDualPiPLayout()
        }
    }
    /// Equal-power audio crossfader + follow-focus pin state machine.
    let dualMixer = TwitchDualAudioMixer()
    /// Currently visually focused channel login in dual-stream mode (primary in single-stream mode).
    var focusedChannel: String? {
        guard isDualStream else { return channel }
        return dualMixer.focusedSlot == .primary ? channel : secondaryChannel
    }

    /// Latency to the broadcaster in seconds, nil until the stream plays.
    private(set) var delay: Double?
    /// The lowest delay seen on this channel: what this stream can do.
    private(set) var bestDelay: Double?
    private(set) var isPlaying = false
    /// Explicit user-requested pause state (distinct from transient buffering; reported to PiP & Now Playing).
    private(set) var userPaused = false
    private(set) var isLoading = false
    private(set) var isBuffering = false
    private(set) var isOffline = false
    private(set) var isMuted = false
    private(set) var isLowLatencyStream = false
    /// True from a jump to live until the delay settles.
    private(set) var isCatchingUp = false
    /// Available quality variants when running in low-latency native mode.
    private(set) var variants: [TwitchVariant] = []
    private(set) var selectedVariantID: String?

    // MARK: secondary stream (Slot B) observable state

    private(set) var secondaryDelay: Double?
    private(set) var secondaryIsPlaying = false
    private(set) var secondaryIsLoading = false
    private(set) var secondaryIsBuffering = false
    private(set) var secondaryIsOffline = false
    private(set) var secondaryVariants: [TwitchVariant] = []
    private(set) var secondarySelectedVariantID: String?
    /// True while the unfocused stream has been stepped down under `AppLifecycle.snapshot.shouldThrottle`.
    private(set) var isThermalThrottled = false
    private(set) var thermalThrottledSlot: TwitchDualSlot?

    /// True when low-latency native mode has handed video off to an AirPlay TV via `AVPlayer`.
    private(set) var isAirPlayingVideo = false
    /// True while probing an AirPlay route/picker with a muted `AVPlayer` before external playback activates.
    private(set) var isAirPlayProbing = false
    /// True while Picture-in-Picture (single, iOS dual PiP, or macOS floating panel) is active.
    private(set) var isPiPActive = false
    /// True when the system reports single-stream PiP can start on the attached display layer.
    private(set) var isPiPPossible = false
    /// True when dual-stream PiP (iOS `AVPictureInPictureVideoCallViewController` or macOS floating panel) can start.
    private(set) var isDualPiPPossible = false
    /// The view holding the player surface now.
    private(set) var holder: UUID?
    /// Jump to live by itself when the stream drifts behind (on by default).
    var autoCatchUp = true
    /// Guard hook for Wave 2 dual-stream mode: disables the parallel muted `AVPlayer` AirPlay probe when false.
    var allowAirPlayProbe = true {
        didSet {
            #if os(iOS)
            if !allowAirPlayProbe && (isAirPlayProbing || isAirPlayingVideo) {
                stopAirPlay(reason: "probe_disabled", resumeNative: true)
            }
            #endif
        }
    }
    /// The popup the embed opened (Twitch's sign-in), shown in a sheet by the holding view.
    private(set) var popup: TwitchPopup?

    var selectedVariant: TwitchVariant? {
        variants.first { $0.id == selectedVariantID }
    }

    var isAudioOnly: Bool {
        activeMode == .lowLatency && !isAirPlayingVideo && selectedVariant?.isAudioOnly == true
    }

    var canTogglePiP: Bool {
        if isDualStream {
            guard activeMode == .lowLatency, channel != nil, secondaryChannel != nil else { return false }
            #if os(macOS)
            return true
            #else
            return isDualPiPPossible || isPiPActive
            #endif
        }
        return activeMode == .lowLatency && !isAirPlayingVideo && !isAudioOnly
            && channel != nil && !isOffline && (isPiPPossible || isPiPActive)
    }

    /// Seconds behind live more than this stream's best, nil until known.
    var behind: Double? {
        guard let delay, let bestDelay else { return nil }
        return max(0, delay - bestDelay)
    }
    var isBehind: Bool { (behind ?? 0) >= Self.behindBy }

    private static let pipAudioClaimID = "twitch.pip"
    private static let airPlayAudioClaimID = "twitch.airplay"

    /// The web view while there is one; `webView` builds it on demand.
    @ObservationIgnored private var made: WKWebView?
    /// The primary native display-layer view while there is one; `nativeView` builds it on demand.
    @ObservationIgnored private var madeNative: TwitchNativeVideoView?
    @ObservationIgnored private var nativeEngine: TwitchNativeEngine?
    @ObservationIgnored private var nativeSessionID: UInt64 = 0
    /// Strictly serializes `stop` and `start` calls into `TwitchNativeEngine` so a stale stop can never cancel a newer start.
    @ObservationIgnored private var nativeLifecycleTask: Task<Void, Never>?
    /// Single MainActor consumer reading `TwitchNativeEvent`s in guaranteed FIFO order.
    @ObservationIgnored private var nativeEventTask: Task<Void, Never>?
    @ObservationIgnored private var nativeEventContinuation: AsyncStream<TwitchNativeEvent>.Continuation?
    @ObservationIgnored private var nativeStartInstant: ContinuousClock.Instant?
    @ObservationIgnored private var lastLoggedBuffering = false
    @ObservationIgnored private var hasLoggedVariants = false
    @ObservationIgnored private var resolvedMasterURL: URL?
    @ObservationIgnored private var preferredQualityID: String?

    /// The secondary native display-layer view (Slot B) for dual-stream mode.
    @ObservationIgnored private var madeSecondaryNative: TwitchNativeVideoView?
    @ObservationIgnored private var secondaryNativeEngine: TwitchNativeEngine?
    @ObservationIgnored private var secondaryNativeSessionID: UInt64 = 0
    @ObservationIgnored private var secondaryNativeLifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var secondaryNativeEventTask: Task<Void, Never>?
    @ObservationIgnored private var secondaryNativeEventContinuation: AsyncStream<TwitchNativeEvent>.Continuation?
    @ObservationIgnored private var secondaryStartInstant: ContinuousClock.Instant?
    @ObservationIgnored private var preThrottleVariantID: String?
    @ObservationIgnored private var lastThermalShouldThrottle = false
    @ObservationIgnored private var resumeSecondaryChannel: String?

    @ObservationIgnored private let pipController = TwitchPiPController()
    #if os(iOS)
    @ObservationIgnored private let dualPiPController = TwitchDualPiPController()
    @ObservationIgnored private weak var dualPiPSourceView: UIView?
    #else
    @ObservationIgnored private let dualFloatingPanel = TwitchDualFloatingPanel()
    #endif
    @ObservationIgnored private let nowPlaying = TwitchNowPlayingController.shared
    /// Held from PiP willStart through didStop so closing/replacing UI never tears down active PiP.
    @ObservationIgnored private var hasPiPClaim = false
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var backgroundVideoOffTask: Task<Void, Never>?
    @ObservationIgnored var restoreHandler: ((String) -> Void)?
    @ObservationIgnored var restoreDualHandler: ((String, String) -> Void)?
    @ObservationIgnored private weak var attachedModel: AppModel?
    @ObservationIgnored private var observingModel = false

    #if os(iOS)
    @ObservationIgnored private var madeAirPlay: TwitchAirPlayVideoView?
    @ObservationIgnored private var airPlayPlayer: AVPlayer?
    @ObservationIgnored private var airPlayExternalObs: NSKeyValueObservation?
    @ObservationIgnored private var airPlayTimeControlObs: NSKeyValueObservation?
    @ObservationIgnored private var airPlayItemStatusObs: NSKeyValueObservation?
    @ObservationIgnored private var airPlayProbeTask: Task<Void, Never>?
    @ObservationIgnored private var airPlayResolveTask: Task<Void, Never>?
    @ObservationIgnored private var airPlayPickerOpen = false
    @ObservationIgnored private var ignoredAudioOnlyAirPlayUID: String?
    @ObservationIgnored private var airPlayRefreshAttempted = false
    #endif

    @ObservationIgnored private let proxy: TwitchMessageProxy
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    /// The app is off screen and the stream was stopped for it.
    @ObservationIgnored private var suspended = false
    /// The channel to play again when the app is back (the one stopped for the background, or one asked for meanwhile).
    @ObservationIgnored private var resumeChannel: String?
    @ObservationIgnored private var claims: [UUID] = []
    @ObservationIgnored private var behindSince: Date?
    @ObservationIgnored private var lastJump: Date = .distantPast
    @ObservationIgnored private var jumpCheck: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pageLoaded = false
    /// The page is loaded as Twitch's own site (signed-in embed) until that once fails to come up in this run.
    @ObservationIgnored private var firstParty = true
    /// The embed said it is ready since the page last loaded.
    @ObservationIgnored private var embedReady = false
    @ObservationIgnored private var readyCheck: Task<Void, Never>?
    /// Cached Twitch `auth-token` cookie so channel switches start instantly without waiting on WebKit XPC.
    @ObservationIgnored private var cachedAuthToken: String?
    @ObservationIgnored private var hasCachedAuthToken = false

    private init() {
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(TwitchPlayerMode.init(rawValue:)) ?? .lowLatency
        self.preferredMode = savedMode
        self.activeMode = savedMode
        self.preferredQualityID = UserDefaults.standard.string(forKey: Self.qualityKey)

        let proxy = TwitchMessageProxy()
        self.proxy = proxy
        proxy.host = self
        dualMixer.target = self
        configurePiPAndNowPlaying()
        AppLifecycle.shared.register(self, order: .media)
        AppLifecycle.shared.register(purgeable: self)
    }

    private func configurePiPAndNowPlaying() {
        pipController.onPossibleChange = { [weak self] possible in
            self?.isPiPPossible = possible
        }
        pipController.onWillStart = { [weak self] in
            guard let self else { return }
            self.hasPiPClaim = true
            self.stopTask?.cancel()
            self.stopTask = nil
            self.releaseTask?.cancel()
            self.releaseTask = nil
            self.backgroundVideoOffTask?.cancel()
            self.backgroundVideoOffTask = nil
            AudioSessionCoordinator.shared.claim(Self.pipAudioClaimID, kind: .playback(allowsPiP: true))
            let engine = self.nativeEngine
            Task { await engine?.setVideoOutputEnabled(true) }
        }
        pipController.onDidStart = { [weak self] in
            guard let self else { return }
            self.isPiPActive = true
            Breadcrumbs.add("twitch.pip.start")
        }
        pipController.onFailedToStart = { [weak self] _ in
            guard let self else { return }
            self.hasPiPClaim = false
            self.isPiPActive = false
            AudioSessionCoordinator.shared.release(Self.pipAudioClaimID)
            Breadcrumbs.add("twitch.pip.failed")
        }
        pipController.onDidStop = { [weak self] restoredUI in
            guard let self else { return }
            self.isPiPActive = false
            self.hasPiPClaim = false
            AudioSessionCoordinator.shared.release(Self.pipAudioClaimID)
            Breadcrumbs.add("twitch.pip.stop", ["restored": .bool(restoredUI)])
            if !restoredUI {
                if self.claims.isEmpty {
                    self.stop()
                } else {
                    self.setPaused(true)
                }
            }
            self.syncPiPAndNowPlaying()
        }
        pipController.onSetPlaying = { [weak self] playing in
            self?.setPaused(!playing)
        }
        pipController.onRestoreUI = { [weak self] completion in
            guard let self else {
                completion(true)
                return
            }
            if let primary = self.channel, let secondary = self.secondaryChannel {
                self.restoreDualHandler?(primary, secondary)
            } else if let ch = self.channel {
                self.restoreHandler?(ch)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                completion(true)
            }
        }

        #if os(iOS)
        dualPiPController.onPossibleChange = { [weak self] possible in
            self?.isDualPiPPossible = possible
        }
        dualPiPController.onWillStart = { [weak self] in
            guard let self else { return }
            self.hasPiPClaim = true
            self.stopTask?.cancel()
            self.stopTask = nil
            self.releaseTask?.cancel()
            self.releaseTask = nil
            self.backgroundVideoOffTask?.cancel()
            self.backgroundVideoOffTask = nil
            self.dualMixer.handleForegrounded()
            AudioSessionCoordinator.shared.claim(Self.pipAudioClaimID, kind: .playback(allowsPiP: true))
            let primaryEngine = self.nativeEngine
            let secondaryEngine = self.secondaryNativeEngine
            Task {
                await primaryEngine?.setVideoOutputEnabled(true)
                await secondaryEngine?.setVideoOutputEnabled(true)
            }
        }
        dualPiPController.onDidStart = { [weak self] in
            guard let self else { return }
            self.isPiPActive = true
            Breadcrumbs.add("twitch.dual.pip.start")
        }
        dualPiPController.onFailedToStart = { [weak self] _ in
            guard let self else { return }
            self.hasPiPClaim = false
            self.isPiPActive = false
            AudioSessionCoordinator.shared.release(Self.pipAudioClaimID)
            Breadcrumbs.add("twitch.dual.pip.failed")
        }
        dualPiPController.onDidStop = { [weak self] restoredUI in
            guard let self else { return }
            self.isPiPActive = false
            self.hasPiPClaim = false
            AudioSessionCoordinator.shared.release(Self.pipAudioClaimID)
            Breadcrumbs.add("twitch.dual.pip.stop", ["restored": .bool(restoredUI)])
            if !restoredUI {
                if self.claims.isEmpty {
                    self.stop()
                } else {
                    self.setPaused(true)
                }
            }
            self.syncPiPAndNowPlaying()
        }
        dualPiPController.onRestoreUI = { [weak self] completion in
            guard let self else {
                completion(true)
                return
            }
            if let primary = self.channel, let secondary = self.secondaryChannel {
                self.restoreDualHandler?(primary, secondary)
            } else if let ch = self.channel {
                self.restoreHandler?(ch)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                completion(true)
            }
        }
        #else
        isDualPiPPossible = true
        dualFloatingPanel.onDidOpen = { [weak self] in
            guard let self else { return }
            self.hasPiPClaim = true
            self.isPiPActive = true
            self.stopTask?.cancel()
            self.stopTask = nil
            self.releaseTask?.cancel()
            self.releaseTask = nil
            AudioSessionCoordinator.shared.claim(Self.pipAudioClaimID, kind: .playback(allowsPiP: true))
            Breadcrumbs.add("twitch.dual.panel.open")
        }
        dualFloatingPanel.onDidClose = { [weak self] restoredUI in
            guard let self else { return }
            self.isPiPActive = false
            self.hasPiPClaim = false
            AudioSessionCoordinator.shared.release(Self.pipAudioClaimID)
            Breadcrumbs.add("twitch.dual.panel.close", ["restored": .bool(restoredUI)])
            if !restoredUI, self.claims.isEmpty {
                self.stop()
            }
            self.syncPiPAndNowPlaying()
        }
        dualFloatingPanel.onRestoreUI = { [weak self] in
            guard let self else { return }
            if let primary = self.channel, let secondary = self.secondaryChannel {
                self.restoreDualHandler?(primary, secondary)
            } else if let ch = self.channel {
                self.restoreHandler?(ch)
            }
        }
        #endif

        nowPlaying.onPlay = { [weak self] in
            self?.setPaused(false)
        }
        nowPlaying.onPause = { [weak self] in
            self?.setPaused(true)
        }
        nowPlaying.onTogglePlayPause = { [weak self] in
            guard let self else { return }
            self.setPaused(!self.userPaused)
        }
    }

    /// Attaches the shared `AppModel` so Lock Screen / Control Center Now Playing reflects live stream metadata.
    func attachModel(_ model: AppModel) {
        let changed = attachedModel !== model
        attachedModel = model
        syncNowPlaying()
        if changed || !observingModel {
            observingModel = true
            observeAttachedModel()
        }
    }

    /// Registers how single-stream PiP's restore button re-opens the stream pane when the user returns to the app.
    func registerRestoreHandler(_ handler: @escaping (String) -> Void) {
        restoreHandler = handler
    }

    /// Registers how dual-stream PiP's restore button re-opens `.dualStream(primary:secondary:)` in the pane.
    func registerRestoreDualHandler(_ handler: @escaping (String, String) -> Void) {
        restoreDualHandler = handler
    }

    #if os(iOS)
    /// Registers the active `TwitchDualStage` host view as the source for iOS dual-stream VideoCall PiP.
    /// Switches between single-stream and dual-stream PiP strictly while PiP is inactive.
    func registerDualPiPSourceView(_ view: UIView?) {
        dualPiPSourceView = view
        guard isDualStream, let view, !isPiPActive else { return }
        pipController.setAutoStartFromInline(false)
        dualPiPController.attach(
            sourceView: view,
            primaryView: nativeView,
            secondaryView: secondaryNativeView,
            focusedSlot: dualMixer.focusedSlot,
            layoutMode: dualStageMode
        )
        syncPiPAndNowPlaying()
    }
    #endif

    private func syncDualPiPLayout() {
        #if os(iOS)
        guard isDualStream else { return }
        dualPiPController.updateLayout(focusedSlot: dualMixer.focusedSlot, layoutMode: dualStageMode)
        #endif
    }

    private func observeAttachedModel() {
        guard let model = attachedModel else {
            observingModel = false
            return
        }
        withObservationTracking {
            _ = model.twitch.channel
            _ = model.twitch.stream
            _ = model.twitch.channelInfo
            _ = model.twitch.secondaryChannel
            _ = model.twitch.secondaryStream
            _ = model.twitch.secondaryChannelInfo
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncNowPlaying()
                self.observeAttachedModel()
            }
        }
    }

    func togglePiP() {
        if isDualStream {
            #if os(iOS)
            if dualPiPController.isActive {
                dualPiPController.stop()
            } else if pipController.isActive {
                pipController.stop()
            } else if let source = dualPiPSourceView {
                pipController.setAutoStartFromInline(false)
                dualPiPController.attach(
                    sourceView: source,
                    primaryView: nativeView,
                    secondaryView: secondaryNativeView,
                    focusedSlot: dualMixer.focusedSlot,
                    layoutMode: dualStageMode
                )
                dualPiPController.start()
            }
            #else
            if dualFloatingPanel.isOpen {
                dualFloatingPanel.close(restoredUI: true)
            } else {
                if pipController.isActive { pipController.stop() }
                dualFloatingPanel.open(host: self)
            }
            #endif
            return
        }

        if isPiPActive {
            #if os(iOS)
            if dualPiPController.isActive {
                dualPiPController.stop()
            } else {
                pipController.stop()
            }
            #else
            if dualFloatingPanel.isOpen {
                dualFloatingPanel.close(restoredUI: true)
            } else {
                pipController.stop()
            }
            #endif
        } else if canTogglePiP {
            pipController.attach(to: nativeView.displayLayer)
            pipController.setUserPaused(userPaused)
            pipController.start()
        }
    }

    private func syncPiPAndNowPlaying() {
        pipController.setUserPaused(userPaused)
        let allowSingleAutoPiP: Bool
        let allowDualAutoPiP: Bool
        #if os(iOS)
        if isDualStream {
            allowSingleAutoPiP = false
            allowDualAutoPiP = activeMode == .lowLatency && channel != nil && secondaryChannel != nil
                && !userPaused && !TwitchTV.shared.onTV
        } else {
            allowSingleAutoPiP = activeMode == .lowLatency && !isAirPlayingVideo && !isAudioOnly
                && channel != nil && !userPaused && !isOffline && !TwitchTV.shared.onTV
            allowDualAutoPiP = false
        }
        dualPiPController.setAutoStartFromInline(allowDualAutoPiP)
        #else
        allowSingleAutoPiP = false
        allowDualAutoPiP = false
        _ = allowDualAutoPiP
        #endif
        pipController.setAutoStartFromInline(allowSingleAutoPiP)
        syncNowPlaying()
    }

    private func syncNowPlaying() {
        guard let ch = channel, (activeMode == .lowLatency || isAirPlayingVideo) else {
            nowPlaying.onNextTrack = nil
            nowPlaying.onPreviousTrack = nil
            nowPlaying.clear()
            return
        }

        if let sec = secondaryChannel {
            // Dual-stream Now Playing: wire next/previous track buttons to swap audio focus A <-> B.
            nowPlaying.onNextTrack = { [weak self] in
                self?.swapDualAudioFocusFromRemote()
            }
            nowPlaying.onPreviousTrack = { [weak self] in
                self?.swapDualAudioFocusFromRemote()
            }
            let twitch = attachedModel?.twitch
            let nameA = twitch?.displayName(for: ch) ?? ch
            let nameB = twitch?.displayName(for: sec) ?? sec
            let louder = dualMixer.louderSlot
            let combinedTitle: String
            switch louder {
            case .primary:
                combinedTitle = "🔊 \(nameA) · \(nameB)"
            case .secondary:
                combinedTitle = "\(nameA) · 🔊 \(nameB)"
            case nil:
                combinedTitle = "\(nameA) · \(nameB)"
            }
            let audioChannel = (louder ?? dualMixer.focusedSlot) == .primary ? ch : sec
            let info = twitch?.streamInfo(for: audioChannel)
            let channelMeta = twitch?.channelInfo(for: audioChannel)
            let game = info?.game
            let artworkURL = info?.thumbnail ?? channelMeta?.avatar
            let activePlaying = !userPaused && (isPlaying || secondaryIsPlaying || isLoading || secondaryIsLoading || isBuffering || secondaryIsBuffering)
            nowPlaying.update(.init(
                channel: audioChannel,
                displayName: combinedTitle,
                title: combinedTitle,
                game: game,
                artworkURL: artworkURL,
                isPlaying: activePlaying,
                isLive: true
            ))
            return
        }

        nowPlaying.onNextTrack = nil
        nowPlaying.onPreviousTrack = nil
        guard !isOffline else {
            nowPlaying.clear()
            return
        }
        var displayName = ch
        var title: String?
        var game: String?
        var artworkURL: URL?
        if let twitch = attachedModel?.twitch, twitch.channel == ch {
            displayName = twitch.stream?.displayName ?? twitch.channelInfo?.displayName ?? ch
            title = twitch.stream?.title
            game = twitch.stream?.game
            artworkURL = twitch.stream?.thumbnail ?? twitch.channelInfo?.avatar
        }
        let activePlaying = !userPaused && (isPlaying || isLoading || isBuffering)
        nowPlaying.update(.init(
            channel: ch,
            displayName: displayName,
            title: title,
            game: game,
            artworkURL: artworkURL,
            isPlaying: activePlaying,
            isLive: true
        ))
    }

    /// The app's one player web view, built on first need and again after it was let go (`releaseResources`).
    var webView: WKWebView {
        if let made { return made }
        let view = WKWebView(frame: .zero, configuration: TwitchEmbed.configuration(handler: proxy))
        view.uiDelegate = proxy
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        made = view
        return view
    }

    /// The primary native sample-buffer video view (Slot A), built on first need and again after `releaseResources`.
    var nativeView: TwitchNativeVideoView {
        if let madeNative { return madeNative }
        let view = TwitchNativeVideoView(frame: .zero)
        madeNative = view
        return view
    }

    /// The secondary native sample-buffer video view (Slot B) for dual-stream mode.
    var secondaryNativeView: TwitchNativeVideoView {
        if let madeSecondaryNative { return madeSecondaryNative }
        let view = TwitchNativeVideoView(frame: .zero)
        madeSecondaryNative = view
        return view
    }

    /// Returns the live `TwitchNativeVideoView` for the requested dual-stream slot.
    func nativeView(for slot: TwitchDualSlot) -> TwitchNativeVideoView {
        switch slot {
        case .primary: nativeView
        case .secondary: secondaryNativeView
        }
    }

    #if os(iOS)
    /// The app's one `AVPlayerLayer` view used during Video-Only AirPlay handoff from low-latency mode.
    var airPlayView: TwitchAirPlayVideoView {
        if let madeAirPlay { return madeAirPlay }
        let view = TwitchAirPlayVideoView(frame: .zero)
        madeAirPlay = view
        return view
    }
    #endif

    // MARK: holders

    /// A view wants a single stream. The newest claim holds the player surface.
    func claim(_ id: UUID, channel: String) {
        stopTask?.cancel()
        stopTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        claims.removeAll { $0 == id }
        claims.append(id)
        holder = id
        if isDualStream {
            demoteToSingle(keeping: channel)
        } else {
            play(channel)
        }
    }

    /// A view wants two simultaneous streams (Zero-Flash promotion when `primary` is already running in Slot A).
    func claimDual(_ id: UUID, primary: String, secondary: String) {
        stopTask?.cancel()
        stopTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        claims.removeAll { $0 == id }
        claims.append(id)
        holder = id
        playDual(primary: primary, secondary: secondary)
    }

    /// A view went. The claim before it takes the player back; with none left (and no active PiP claim) the stream stops
    /// shortly after (a layout change removes one view and adds another in the same moment, so this waits a beat).
    func release(_ id: UUID) {
        claims.removeAll { $0 == id }
        holder = claims.last
        guard claims.isEmpty && !hasPiPClaim else { return }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.claims.isEmpty, !self.hasPiPClaim else { return }
            self.stop()
        }
    }

    // MARK: mode & playback controls

    /// Switch between native low-latency playback and Twitch's embed, persisting the choice.
    func setMode(_ mode: TwitchPlayerMode) {
        preferredMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        fellBackToEmbed = false

        guard activeMode != mode else { return }
        let current = channel
        if activeMode == .lowLatency {
            if isPiPActive { pipController.stop() }
            stopNative()
        } else {
            stopEmbed()
        }
        activeMode = mode
        reset()
        if let current {
            startActive(current)
        }
        syncPiPAndNowPlaying()
    }

    func selectVariant(_ id: String) {
        guard activeMode == .lowLatency else { return }
        preferredQualityID = id
        UserDefaults.standard.set(id, forKey: Self.qualityKey)
        selectedVariantID = id
        if isAudioOnly && isPiPActive {
            pipController.stop()
        }
        syncPiPAndNowPlaying()
        if isAirPlayingVideo { return }
        let engine = nativeEngine
        Task { await engine?.selectVariant(id: id) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        #if os(iOS)
        if isAirPlayingVideo {
            airPlayPlayer?.isMuted = muted
            return
        }
        #endif
        if isDualStream {
            dualMixer.syncToTarget(animated: false)
            return
        }
        if activeMode == .lowLatency {
            let engine = nativeEngine
            Task { await engine?.setMuted(muted) }
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func play(_ channel: String) {
        let c = TwitchEmbed.safe(channel)
        guard !c.isEmpty else { return }
        if isDualStream {
            demoteToSingle(keeping: c)
            return
        }
        // off screen: nothing plays until the app is back, then this channel does
        if suspended {
            resumeChannel = c
            resumeSecondaryChannel = nil
            return
        }
        if c == self.channel {
            // Self-heal if this channel was re-claimed after a layout swap or teardown left no active native session.
            if activeMode == .lowLatency, !isAirPlayingVideo, !userPaused, !isOffline,
               (nativeEngine == nil || nativeEventTask == nil) {
                reset()
                startNative(c)
            }
            return
        }
        // Switching to a fresh channel resets any per-channel fallback so the owner's preferred mode runs again.
        if fellBackToEmbed {
            fellBackToEmbed = false
            if activeMode != preferredMode {
                if activeMode == .embed { stopEmbed() } else { stopNative() }
                activeMode = preferredMode
            }
        }
        allowAirPlayProbe = true
        self.channel = c
        resolvedMasterURL = nil
        reset()
        startActive(c)
    }

    /// Called when `TwitchPlayerSlot` or `TwitchNativeSlotSurface` reparents a live `TwitchNativeVideoView`
    /// across containers (e.g. fold/unfold `layout.swap`, `span`, or `pane.bar -> pane.screen`).
    func notifyNativeViewReparented(for slot: TwitchDualSlot = .primary) {
        guard activeMode == .lowLatency, !isAirPlayingVideo else { return }
        let engine = slot == .primary ? nativeEngine : secondaryNativeEngine
        guard let engine else { return }
        Task {
            await engine.recoverVideoRenderer()
        }
    }

    /// Starts or promotes into dual-stream mode (`primary` in Slot A + `secondary` in Slot B).
    /// Keeps any already-running stream's `TwitchNativeEngine` and `AVSampleBufferDisplayLayer` alive with zero black flash.
    func playDual(primary rawPrimary: String, secondary rawSecondary: String) {
        let p = TwitchEmbed.safe(rawPrimary)
        let s = TwitchEmbed.safe(rawSecondary)
        guard !p.isEmpty, !s.isEmpty else { return }
        if p == s {
            demoteToSingle(keeping: p)
            return
        }
        if suspended {
            resumeChannel = p
            resumeSecondaryChannel = s
            return
        }

        // Disable the 3rd parallel AirPlay HLS probe whenever dual-stream is active.
        allowAirPlayProbe = false

        // Dual-stream always runs on the native low-latency engine pair.
        if activeMode != .lowLatency {
            stopEmbed()
            fellBackToEmbed = false
            activeMode = .lowLatency
        }

        // Already running this exact pair: just sync mixer/PiP/Now Playing.
        if self.channel == p, self.secondaryChannel == s, nativeEngine != nil, secondaryNativeEngine != nil {
            syncPiPAndNowPlaying()
            attachedModel?.twitch.updateCombinedChatFocus(focusedChannel)
            return
        }

        // Zero-flash slot swap if the requested pair is simply reversed.
        if self.channel == s, self.secondaryChannel == p, nativeEngine != nil, secondaryNativeEngine != nil {
            swapPrimaryAndSecondarySlots()
            dualMixer.reset(focused: .primary, animated: true)
            attachedModel?.twitch.updateCombinedChatFocus(focusedChannel)
            syncPiPAndNowPlaying()
            return
        }

        // Zero-flash promotion: if the requested primary is currently in Slot B, promote Slot B -> Slot A first.
        if self.secondaryChannel == p, self.channel != p, secondaryNativeEngine != nil {
            swapPrimaryAndSecondarySlots()
        }

        let primaryAlreadyLive = (self.channel == p && nativeEngine != nil && !isOffline)
        let secondaryAlreadyLive = (self.secondaryChannel == s && secondaryNativeEngine != nil && !secondaryIsOffline)

        self.channel = p
        self.secondaryChannel = s

        // Reset mixer to follow-focus on primary (A = 1.0, B = 0.0) without clicking primary audio.
        dualMixer.reset(focused: .primary, animated: false)

        if !primaryAlreadyLive {
            resolvedMasterURL = nil
            reset()
            startNative(p)
        } else {
            // Keep Slot A alive with zero black flash; simply ensure its gain matches the mixer.
            let engine = nativeEngine
            let gain = isMuted ? Float(0) : dualMixer.gains.primary
            Task {
                await engine?.rampVolume(to: gain, duration: .seconds(0.08), curve: .equalPower, updateMuteOnEndpoints: true)
            }
        }

        if !secondaryAlreadyLive {
            resetSecondary()
            startSecondaryNative(s)
        } else {
            dualMixer.syncToTarget(animated: false)
        }

        #if os(iOS)
        if !isPiPActive, let source = dualPiPSourceView {
            pipController.setAutoStartFromInline(false)
            dualPiPController.attach(
                sourceView: source,
                primaryView: nativeView,
                secondaryView: secondaryNativeView,
                focusedSlot: dualMixer.focusedSlot,
                layoutMode: dualStageMode
            )
        }
        #endif

        applyThermalThrottling(shouldThrottle: AppLifecycle.shared.snapshot.shouldThrottle)
        attachedModel?.twitch.updateCombinedChatFocus(focusedChannel)
        syncPiPAndNowPlaying()
        Breadcrumbs.add("twitch.dual.start", ["primary_kept": .bool(primaryAlreadyLive)])
    }

    /// Demotes dual-stream mode down to a single stream, preserving the surviving stream's live engine and
    /// `AVSampleBufferDisplayLayer` with zero black flash (even when keeping Slot B!).
    func demoteToSingle(keeping rawChannel: String) {
        let keep = TwitchEmbed.safe(rawChannel)
        guard !keep.isEmpty else { return }

        // If keeping Slot B, promote Slot B -> Slot A in place without dropping a frame.
        if self.secondaryChannel == keep, self.channel != keep, secondaryNativeEngine != nil {
            swapPrimaryAndSecondarySlots()
        }

        clearThermalThrottling(restoreVariant: false)
        dualMixer.handleForegrounded()
        stopSecondaryNative()
        secondaryChannel = nil
        resetSecondary()
        allowAirPlayProbe = true

        #if os(iOS)
        // Guard: switch dual -> single PiP controller strictly while PiP is inactive.
        if !isPiPActive {
            dualPiPController.detach()
            pipController.attach(to: nativeView.displayLayer)
        }
        #else
        if dualFloatingPanel.isOpen {
            dualFloatingPanel.close(restoredUI: true)
        }
        #endif

        if self.channel == keep, nativeEngine != nil {
            // Surviving stream stays live with zero flash; ramp audio back to full unmuted gain (unless user muted).
            let engine = nativeEngine
            let targetGain: Float = isMuted ? 0.0 : 1.0
            Task {
                await engine?.setPaused(userPaused)
                await engine?.rampVolume(to: targetGain, duration: .seconds(0.16), curve: .equalPower, updateMuteOnEndpoints: true)
            }
            syncPiPAndNowPlaying()
            Breadcrumbs.add("twitch.dual.demote", ["kept_live": .bool(true)])
        } else {
            self.channel = keep
            resolvedMasterURL = nil
            reset()
            startActive(keep)
            Breadcrumbs.add("twitch.dual.demote", ["kept_live": .bool(false)])
        }
    }

    // MARK: dual-stream focus, audio mixer target & thermal throttling

    func holds(_ id: UUID) -> Bool {
        holder == id
    }

    func toggleDualStageMode() {
        dualStageMode = dualStageMode == .focusInset ? .split5050 : .focusInset
    }

    func setDualFocus(_ slot: TwitchDualSlot) {
        guard isDualStream else { return }
        dualMixer.setFocus(slot, animated: true)
        attachedModel?.twitch.updateCombinedChatFocus(focusedChannel)
        syncDualPiPLayout()
        syncNowPlaying()
        if AppLifecycle.shared.snapshot.shouldThrottle {
            applyThermalThrottling(shouldThrottle: true)
        }
    }

    func swapDualFocus() {
        setDualFocus(dualMixer.focusedSlot.other)
    }

    /// Invoked by Lock Screen / Control Center next/previous track buttons to swap audio focus A <-> B.
    func swapDualAudioFocusFromRemote() {
        guard isDualStream else { return }
        dualMixer.swapAudioFocusForRemoteCommand(animated: true)
        attachedModel?.twitch.updateCombinedChatFocus(focusedChannel)
        syncDualPiPLayout()
        syncNowPlaying()
        Breadcrumbs.add("twitch.dual.remote_swap", ["focused": .string(dualMixer.focusedSlot.rawValue)])
    }

    func applyDualAudioRamp(
        primaryGain: Float,
        secondaryGain: Float,
        duration: TimeInterval,
        curve: TwitchVolumeRampCurve,
        updateMuteOnEndpoints: Bool
    ) {
        let pGain: Float = isMuted ? 0.0 : primaryGain
        let sGain: Float = isMuted ? 0.0 : secondaryGain
        let rampDuration: Duration = .seconds(max(0, duration))
        let primaryEngine = nativeEngine
        let secondaryEngine = secondaryNativeEngine
        Task {
            async let p: Void = {
                if let primaryEngine {
                    await primaryEngine.rampVolume(
                        to: pGain,
                        duration: rampDuration,
                        curve: curve,
                        updateMuteOnEndpoints: updateMuteOnEndpoints
                    )
                }
            }()
            async let s: Void = {
                if let secondaryEngine {
                    await secondaryEngine.rampVolume(
                        to: sGain,
                        duration: rampDuration,
                        curve: curve,
                        updateMuteOnEndpoints: updateMuteOnEndpoints
                    )
                }
            }()
            _ = await (p, s)
        }
        syncNowPlaying()
    }

    func setDualSlotSuspended(_ slot: TwitchDualSlot, suspended: Bool) {
        let engine = slot == .primary ? nativeEngine : secondaryNativeEngine
        guard let engine else { return }
        let allowVideo = !suspended && (!isInBackground || isPiPActive || hasPiPClaim)
        let shouldPause = suspended || userPaused
        Task {
            await engine.setVideoOutputEnabled(allowVideo)
            await engine.setPaused(shouldPause)
        }
        Breadcrumbs.add("twitch.dual.lock_suspend", [
            "slot": .string(slot.rawValue),
            "suspended": .bool(suspended),
        ])
    }

    /// Selects quality variant for a specific slot in dual-stream mode.
    func selectVariant(_ id: String, for slot: TwitchDualSlot) {
        guard activeMode == .lowLatency else { return }
        switch slot {
        case .primary:
            selectVariant(id)
        case .secondary:
            secondarySelectedVariantID = id
            let engine = secondaryNativeEngine
            Task { await engine?.selectVariant(id: id) }
        }
    }

    /// Swaps Slot A and Slot B engines, views, and metadata in place with zero frame drop.
    private func swapPrimaryAndSecondarySlots() {
        swap(&channel, &secondaryChannel)
        swap(&madeNative, &madeSecondaryNative)
        swap(&nativeEngine, &secondaryNativeEngine)
        swap(&nativeLifecycleTask, &secondaryNativeLifecycleTask)
        swap(&delay, &secondaryDelay)
        swap(&isPlaying, &secondaryIsPlaying)
        swap(&isLoading, &secondaryIsLoading)
        swap(&isBuffering, &secondaryIsBuffering)
        swap(&isOffline, &secondaryIsOffline)
        swap(&variants, &secondaryVariants)
        swap(&selectedVariantID, &secondarySelectedVariantID)
        bestDelay = delay

        // Rebind FIFO event streams to the swapped slots without stopping or flushing either engine.
        if let primary = nativeEngine {
            rebindPrimaryEventStream(for: primary)
        }
        if let secondary = secondaryNativeEngine {
            rebindSecondaryEventStream(for: secondary)
        }
    }

    private func rebindPrimaryEventStream(for engine: TwitchNativeEngine) {
        nativeSessionID &+= 1
        let sessionID = nativeSessionID
        nativeEventContinuation?.finish()
        nativeEventTask?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: TwitchNativeEvent.self)
        nativeEventContinuation = continuation
        nativeEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.receiveNative(event, sessionID: sessionID)
            }
        }
        Task {
            await engine.setEventHandler { event in
                continuation.yield(event)
            }
        }
    }

    private func rebindSecondaryEventStream(for engine: TwitchNativeEngine) {
        secondaryNativeSessionID &+= 1
        let sessionID = secondaryNativeSessionID
        secondaryNativeEventContinuation?.finish()
        secondaryNativeEventTask?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: TwitchNativeEvent.self)
        secondaryNativeEventContinuation = continuation
        secondaryNativeEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.receiveSecondaryNative(event, sessionID: sessionID)
            }
        }
        Task {
            await engine.setEventHandler { event in
                continuation.yield(event)
            }
        }
    }

    /// Steps down the unfocused stream's quality under thermal or memory pressure (`AppLifecycle.snapshot.shouldThrottle`)
    /// and restores it once pressure clears.
    private func applyThermalThrottling(shouldThrottle: Bool) {
        guard isDualStream else {
            if isThermalThrottled { clearThermalThrottling(restoreVariant: false) }
            return
        }
        if !shouldThrottle {
            clearThermalThrottling(restoreVariant: true)
            return
        }

        let targetSlot = dualMixer.focusedSlot.other
        // If focus moved to the previously throttled slot, restore it before stepping down the newly unfocused slot.
        if let existingSlot = thermalThrottledSlot, existingSlot != targetSlot {
            clearThermalThrottling(restoreVariant: true)
        }

        let slotVariants = targetSlot == .primary ? variants : secondaryVariants
        let currentID = targetSlot == .primary ? selectedVariantID : secondarySelectedVariantID
        guard let steppedDown = Self.lowPowerVariant(from: slotVariants), steppedDown.id != currentID else { return }

        if preThrottleVariantID == nil {
            preThrottleVariantID = currentID
        }
        thermalThrottledSlot = targetSlot
        isThermalThrottled = true
        if targetSlot == .primary {
            selectedVariantID = steppedDown.id
            let engine = nativeEngine
            Task { await engine?.selectVariant(id: steppedDown.id) }
        } else {
            secondarySelectedVariantID = steppedDown.id
            let engine = secondaryNativeEngine
            Task { await engine?.selectVariant(id: steppedDown.id) }
        }
        Breadcrumbs.add("twitch.dual.thermal_stepdown", [
            "slot": .string(targetSlot.rawValue),
            "variant": .string(steppedDown.shortLabel),
        ])
    }

    private func clearThermalThrottling(restoreVariant: Bool) {
        guard isThermalThrottled || thermalThrottledSlot != nil else { return }
        let slot = thermalThrottledSlot
        let previousID = preThrottleVariantID
        isThermalThrottled = false
        thermalThrottledSlot = nil
        preThrottleVariantID = nil
        guard restoreVariant, let slot, let previousID else { return }
        if slot == .primary {
            selectedVariantID = previousID
            let engine = nativeEngine
            Task { await engine?.selectVariant(id: previousID) }
        } else {
            secondarySelectedVariantID = previousID
            let engine = secondaryNativeEngine
            Task { await engine?.selectVariant(id: previousID) }
        }
    }

    /// Picks a low-power video variant (preferring 480p/360p, else lowest non-audio-only video tier) for thermal step-down.
    private static func lowPowerVariant(from list: [TwitchVariant]) -> TwitchVariant? {
        let videoOnly = list.filter { !$0.isAudioOnly }
        guard !videoOnly.isEmpty else { return nil }
        let moderate = videoOnly
            .filter { ($0.height ?? 0) > 0 && ($0.height ?? 0) <= 480 }
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        if let pick = moderate.first { return pick }
        return videoOnly.min { ($0.bandwidth) < ($1.bandwidth) }
    }

    private func startActive(_ channel: String) {
        switch activeMode {
        case .lowLatency:
            #if os(iOS)
            if isAirPlayingVideo {
                switchAirPlayChannel(channel)
                return
            }
            #endif
            startNative(channel)
        case .embed:
            startEmbed(channel)
        }
    }

    private func startNative(_ channel: String) {
        stopEmbed()
        nativeSessionID &+= 1
        let sessionID = nativeSessionID
        let displayLayer = nativeView.displayLayer
        if !isDualStream && !isPiPActive {
            pipController.attach(to: displayLayer)
        }
        let rendererBox = TwitchVideoRendererBox(displayLayer.sampleBufferRenderer)
        let engine = ensureNativeEngine()
        let initialGain: Float = isMuted ? 0.0 : (isDualStream ? dualMixer.gains.primary : 1.0)
        let initialMuted = initialGain <= 0.0001
        let preferredQuality = preferredQualityID

        nativeEventContinuation?.finish()
        nativeEventContinuation = nil
        nativeEventTask?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: TwitchNativeEvent.self)
        nativeEventContinuation = continuation
        nativeEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.receiveNative(event, sessionID: sessionID)
            }
        }

        userPaused = false
        isLoading = true
        nativeStartInstant = .now
        lastLoggedBuffering = false
        hasLoggedVariants = false
        syncPiPAndNowPlaying()
        Breadcrumbs.add("twitch.native.start", ["quality": .string(preferredQuality ?? "auto")])

        let previous = nativeLifecycleTask
        previous?.cancel()
        nativeLifecycleTask = Task { [weak self] in
            // Wait for any in-flight stop/start to finish on the engine actor before starting this session.
            await previous?.value
            guard let self, !Task.isCancelled, self.nativeSessionID == sessionID,
                  self.activeMode == .lowLatency, self.channel == channel else { return }
            let authToken = await self.twitchAuthToken()
            guard !Task.isCancelled, self.nativeSessionID == sessionID,
                  self.activeMode == .lowLatency, self.channel == channel else { return }
            let videoEnabled = !self.isInBackground || self.isPiPActive || self.hasPiPClaim
            await engine.setEventHandler { event in
                continuation.yield(event)
            }
            await engine.attach(videoRenderer: rendererBox)
            await engine.setVideoOutputEnabled(videoEnabled)
            await engine.setVolume(initialGain)
            await engine.setMuted(initialMuted)
            await engine.start(channel: channel, authToken: authToken, preferredVariantID: preferredQuality)
        }
    }

    private func startSecondaryNative(_ channel: String) {
        secondaryNativeSessionID &+= 1
        let sessionID = secondaryNativeSessionID
        let displayLayer = secondaryNativeView.displayLayer
        let rendererBox = TwitchVideoRendererBox(displayLayer.sampleBufferRenderer)
        let engine = ensureSecondaryNativeEngine()
        let initialGain: Float = isMuted ? 0.0 : dualMixer.gains.secondary
        let initialMuted = initialGain <= 0.0001
        let preferredQuality = preferredQualityID

        secondaryNativeEventContinuation?.finish()
        secondaryNativeEventContinuation = nil
        secondaryNativeEventTask?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: TwitchNativeEvent.self)
        secondaryNativeEventContinuation = continuation
        secondaryNativeEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.receiveSecondaryNative(event, sessionID: sessionID)
            }
        }

        secondaryIsLoading = true
        secondaryStartInstant = .now
        syncPiPAndNowPlaying()
        Breadcrumbs.add("twitch.native.secondary.start")

        let previous = secondaryNativeLifecycleTask
        previous?.cancel()
        secondaryNativeLifecycleTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.secondaryNativeSessionID == sessionID,
                  self.activeMode == .lowLatency, self.secondaryChannel == channel else { return }
            let authToken = await self.twitchAuthToken()
            guard !Task.isCancelled, self.secondaryNativeSessionID == sessionID,
                  self.activeMode == .lowLatency, self.secondaryChannel == channel else { return }
            let videoEnabled = !self.isInBackground || self.isPiPActive || self.hasPiPClaim
            await engine.setEventHandler { event in
                continuation.yield(event)
            }
            await engine.attach(videoRenderer: rendererBox)
            await engine.setVideoOutputEnabled(videoEnabled)
            await engine.setVolume(initialGain)
            await engine.setMuted(initialMuted)
            await engine.start(channel: channel, authToken: authToken, preferredVariantID: preferredQuality)
        }
    }

    private func stopNative(keepAirPlay: Bool = false) {
        #if os(iOS)
        if !keepAirPlay {
            stopAirPlay(reason: "stop", resumeNative: false)
        }
        #endif
        backgroundVideoOffTask?.cancel()
        backgroundVideoOffTask = nil
        let wasActive = nativeEventContinuation != nil || nativeStartInstant != nil
        nativeSessionID &+= 1
        nativeEventContinuation?.finish()
        nativeEventContinuation = nil
        nativeEventTask?.cancel()
        nativeEventTask = nil
        nativeStartInstant = nil
        lastLoggedBuffering = false
        hasLoggedVariants = false
        if wasActive && !keepAirPlay {
            Breadcrumbs.add("twitch.native.stop")
        }

        let engine = nativeEngine
        let previous = nativeLifecycleTask
        previous?.cancel()
        nativeLifecycleTask = Task {
            await previous?.value
            await engine?.stop()
        }
    }

    private func stopSecondaryNative() {
        let wasActive = secondaryNativeEventContinuation != nil || secondaryStartInstant != nil
        secondaryNativeSessionID &+= 1
        secondaryNativeEventContinuation?.finish()
        secondaryNativeEventContinuation = nil
        secondaryNativeEventTask?.cancel()
        secondaryNativeEventTask = nil
        secondaryStartInstant = nil
        if wasActive {
            Breadcrumbs.add("twitch.native.secondary.stop")
        }

        let engine = secondaryNativeEngine
        let previous = secondaryNativeLifecycleTask
        previous?.cancel()
        secondaryNativeLifecycleTask = Task {
            await previous?.value
            await engine?.stop()
        }
    }

    private func ensureNativeEngine() -> TwitchNativeEngine {
        if let nativeEngine { return nativeEngine }
        let engine = TwitchNativeEngine()
        nativeEngine = engine
        return engine
    }

    private func ensureSecondaryNativeEngine() -> TwitchNativeEngine {
        if let secondaryNativeEngine { return secondaryNativeEngine }
        let engine = TwitchNativeEngine()
        secondaryNativeEngine = engine
        return engine
    }

    private func resetSecondary() {
        secondaryDelay = nil
        secondaryIsPlaying = false
        secondaryIsLoading = false
        secondaryIsBuffering = false
        secondaryIsOffline = false
        secondaryVariants = []
        secondarySelectedVariantID = nil
    }

    /// Reads Twitch's `auth-token` cookie from WebKit's persistent store without instantiating a `WKWebView`.
    /// Uses an in-memory cache for instant channel switches and bounds the WebKit XPC lookup so a stalled
    /// `WKHTTPCookieStore` can never freeze native startup before `TwitchNativeEngine` starts its watchdog.
    private func twitchAuthToken(timeout: Duration = .milliseconds(1200)) async -> String? {
        if hasCachedAuthToken {
            let cached = cachedAuthToken
            refreshCachedAuthToken()
            return cached
        }
        return await withCheckedContinuation { continuation in
            final class ResumeGate: @unchecked Sendable {
                var resumed = false
            }
            let gate = ResumeGate()
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, !gate.resumed else { return }
                gate.resumed = true
                Breadcrumbs.add("twitch.auth_cookie.timeout")
                continuation.resume(returning: self?.cachedAuthToken)
            }
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                let token = cookies.first(where: { $0.name == "auth-token" && $0.domain.contains("twitch.tv") })?.value
                Task { @MainActor in
                    self?.cachedAuthToken = token
                    self?.hasCachedAuthToken = true
                    timer.cancel()
                    guard !gate.resumed else { return }
                    gate.resumed = true
                    continuation.resume(returning: token)
                }
            }
        }
    }

    private func refreshCachedAuthToken() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let token = cookies.first(where: { $0.name == "auth-token" && $0.domain.contains("twitch.tv") })?.value
            Task { @MainActor in
                self?.cachedAuthToken = token
                self?.hasCachedAuthToken = true
            }
        }
    }

    private func startEmbed(_ channel: String) {
        if pageLoaded {
            webView.evaluateJavaScript("window.cobaltSetChannel && window.cobaltSetChannel(\"\(channel)\")")
        } else {
            pageLoaded = true
            loadEmbed(channel)
        }
    }

    /// Loads the player page for `channel`: as www.twitch.tv while that works, else on the web app's domain.
    private func loadEmbed(_ channel: String) {
        let base = firstParty ? TwitchEmbed.firstParty : TwitchEmbed.fallback
        embedReady = false
        readyCheck?.cancel()
        readyCheck = nil
        webView.loadHTMLString(TwitchEmbed.html(channel: channel, base: base), baseURL: base)
        guard firstParty else { return }
        readyCheck = Task { [weak self] in
            try? await Task.sleep(for: TwitchEmbed.firstPartyWait)
            guard let self, !Task.isCancelled, !self.embedReady, self.firstParty,
                  self.activeMode == .embed, self.channel == channel, !self.suspended else { return }
            self.firstParty = false
            self.loadEmbed(channel)
        }
    }

    private func stopEmbed() {
        pageLoaded = false
        readyCheck?.cancel()
        readyCheck = nil
        made?.loadHTMLString("<html><body style=\"background:#000\"></body></html>", baseURL: nil)
    }

    /// Stops whichever engine(s) are active. Views nobody wants go after `releaseAfter`.
    func stop() {
        if isPiPActive {
            #if os(iOS)
            if dualPiPController.isActive { dualPiPController.stop() }
            if pipController.isActive { pipController.stop() }
            #else
            if dualFloatingPanel.isOpen { dualFloatingPanel.close(restoredUI: false) }
            if pipController.isActive { pipController.stop() }
            #endif
        }
        hasPiPClaim = false
        AudioSessionCoordinator.shared.release(Self.pipAudioClaimID)
        backgroundVideoOffTask?.cancel()
        backgroundVideoOffTask = nil
        clearThermalThrottling(restoreVariant: false)
        dualMixer.handleForegrounded()
        channel = nil
        secondaryChannel = nil
        allowAirPlayProbe = true
        resolvedMasterURL = nil
        stopEmbed()
        stopNative()
        stopSecondaryNative()
        reset()
        resetSecondary()
        syncPiPAndNowPlaying()
        scheduleRelease()
    }

    /// The pane's play / pause button (and native HUD, PiP, and Lock Screen play / pause).
    func setPaused(_ paused: Bool) {
        guard channel != nil else { return }
        userPaused = paused
        #if os(iOS)
        if isAirPlayingVideo {
            isPlaying = !paused
            if paused {
                airPlayPlayer?.pause()
            } else {
                airPlayPlayer?.play()
            }
            syncPiPAndNowPlaying()
            return
        }
        #endif
        switch activeMode {
        case .lowLatency:
            isPlaying = !paused
            if isDualStream { secondaryIsPlaying = !paused }
            syncPiPAndNowPlaying()
            let primaryEngine = nativeEngine
            let secondaryEngine = isDualStream ? secondaryNativeEngine : nil
            let suspendedSlot = dualMixer.suspendedSlot
            Task {
                if suspendedSlot != .primary {
                    await primaryEngine?.setPaused(paused)
                }
                if let secondaryEngine, suspendedSlot != .secondary {
                    await secondaryEngine.setPaused(paused)
                }
            }
        case .embed:
            made?.evaluateJavaScript(paused ? "window.cobaltPause && window.cobaltPause()" : "window.cobaltPlay && window.cobaltPlay()")
        }
    }

    /// Back to the live edge (jumps both streams when in dual-stream mode).
    func jumpToLive() {
        guard channel != nil else { return }
        #if os(iOS)
        if isAirPlayingVideo, let player = airPlayPlayer {
            if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue, range.isValid {
                let end = CMTimeRangeGetEnd(range)
                if end.isValid && end.isNumeric {
                    player.seek(to: end)
                }
            }
            player.play()
            return
        }
        #endif
        lastJump = .now
        behindSince = nil
        isCatchingUp = true
        jumpCheck?.cancel()

        switch activeMode {
        case .lowLatency:
            let primaryEngine = nativeEngine
            let secondaryEngine = isDualStream ? secondaryNativeEngine : nil
            Task {
                await primaryEngine?.jumpToLive()
                await secondaryEngine?.jumpToLive()
            }
            jumpCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                if self.isBehind, let delay = self.delay { self.bestDelay = delay }
                self.isCatchingUp = false
            }
        case .embed:
            made?.evaluateJavaScript("window.cobaltJumpToLive && window.cobaltJumpToLive()")
            jumpCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                if self.isBehind {
                    _ = try? await self.made?.evaluateJavaScript("window.cobaltRebuild && window.cobaltRebuild()")
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    // still behind after a reload: this is as close as the stream gets now, so it becomes the new best
                    if self.isBehind, let delay = self.delay { self.bestDelay = delay }
                }
                self.isCatchingUp = false
            }
        }
    }

    /// Reloads the active engine(s) for the current channel(s) (e.g. after a sign-in).
    func reload() {
        guard let channel else { return }
        resolvedMasterURL = nil
        reset()
        switch activeMode {
        case .lowLatency:
            #if os(iOS)
            if isAirPlayingVideo {
                switchAirPlayChannel(channel)
                return
            }
            #endif
            startNative(channel)
            if let sec = secondaryChannel {
                resetSecondary()
                startSecondaryNative(sec)
            }
        case .embed:
            loadEmbed(channel)
        }
    }

    // MARK: Video-Only AirPlay handoff (iOS)

    #if os(iOS)
    /// Called when the user opens an `AVRoutePickerView`: primes a muted `AVPlayer` with `allowsExternalPlayback = true`
    /// so iOS immediately negotiates Video-Only AirPlay if the user picks an Apple TV / AirPlay 2 TV.
    func prepareAirPlayRoutePicker() {
        airPlayPickerOpen = true
        ignoredAudioOnlyAirPlayUID = nil
        guard allowAirPlayProbe, activeMode == .lowLatency, channel != nil, !isAirPlayingVideo,
              !TwitchTV.shared.onTV, !TwitchTV.shared.screenConnected else { return }
        startAirPlayProbe(fromPicker: true)
    }

    /// Called when `AVRoutePickerView` finishes presenting routes.
    func finishAirPlayRoutePicker() {
        airPlayPickerOpen = false
        guard !isAirPlayingVideo else { return }
        if !TwitchTV.shared.airPlayRoute {
            scheduleAirPlayProbeTimeout(after: .seconds(1.5), reason: "picker_dismissed", markAudioOnly: false)
        } else {
            scheduleAirPlayProbeTimeout(after: .seconds(6), reason: "audio_only_route", markAudioOnly: true)
        }
    }

    /// Called when `AVAudioSession.routeChangeNotification` reports an AirPlay output joining or leaving.
    func airPlayRouteChanged(active: Bool, outputUID: String?) {
        if !active {
            ignoredAudioOnlyAirPlayUID = nil
            if isAirPlayingVideo || isAirPlayProbing {
                stopAirPlay(reason: "route_ended", resumeNative: true)
            }
            return
        }
        guard allowAirPlayProbe, activeMode == .lowLatency, channel != nil, !isAirPlayingVideo,
              !TwitchTV.shared.onTV, !TwitchTV.shared.screenConnected else { return }
        if let outputUID, outputUID == ignoredAudioOnlyAirPlayUID { return }
        startAirPlayProbe(fromPicker: false)
    }

    /// Called when Screen Mirroring TV Mode takes over: stop any Video-Only AirPlay `AVPlayer` so TV Mode renders natively.
    func handleTVModeActivated() {
        if isPiPActive { pipController.stop() }
        if isAirPlayingVideo || isAirPlayProbing {
            stopAirPlay(reason: "tv_mode", resumeNative: true)
        }
        syncPiPAndNowPlaying()
    }

    private func maybeStartAirPlayFromRoute() {
        guard allowAirPlayProbe, TwitchTV.shared.airPlayRoute, !TwitchTV.shared.onTV, !TwitchTV.shared.screenConnected,
              activeMode == .lowLatency, channel != nil, !isAirPlayingVideo, !isAirPlayProbing else { return }
        if let uid = TwitchTV.shared.airPlayOutputUID, uid == ignoredAudioOnlyAirPlayUID { return }
        startAirPlayProbe(fromPicker: false)
    }

    private func startAirPlayProbe(fromPicker: Bool) {
        guard allowAirPlayProbe, let currentChannel = channel, activeMode == .lowLatency,
              !TwitchTV.shared.onTV, !TwitchTV.shared.screenConnected else { return }
        if airPlayPlayer != nil {
            if !fromPicker {
                scheduleAirPlayProbeTimeout(after: .seconds(6), reason: "audio_only_route", markAudioOnly: true)
            }
            return
        }

        isAirPlayProbing = true
        airPlayRefreshAttempted = false
        Breadcrumbs.add("twitch.airplay.start", ["picker": .bool(fromPicker)])

        if let url = resolvedMasterURL {
            attachAirPlayPlayer(url: url, fromPicker: fromPicker)
            return
        }

        airPlayResolveTask?.cancel()
        airPlayResolveTask = Task { [weak self] in
            guard let self else { return }
            let auth = await self.twitchAuthToken()
            guard !Task.isCancelled, self.channel == currentChannel, self.activeMode == .lowLatency else { return }
            do {
                let resolved = try await TwitchStreamResolver().resolveStream(channel: currentChannel, authToken: auth)
                guard !Task.isCancelled, self.channel == currentChannel, self.activeMode == .lowLatency,
                      self.isAirPlayProbing || self.isAirPlayingVideo else { return }
                self.resolvedMasterURL = resolved.masterURL
                self.attachAirPlayPlayer(url: resolved.masterURL, fromPicker: fromPicker)
            } catch {
                guard !Task.isCancelled else { return }
                self.stopAirPlay(reason: "resolve_failed", resumeNative: false)
            }
        }
    }

    private func attachAirPlayPlayer(url: URL, fromPicker: Bool) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        // Keep muted while probing so native audio isn't doubled; unmuted as soon as external playback activates.
        player.isMuted = !isAirPlayingVideo || isMuted

        airPlayPlayer = player
        airPlayView.playerLayer.player = player
        observeAirPlayPlayer(player, item: item)
        player.play()

        if !fromPicker && !isAirPlayingVideo {
            scheduleAirPlayProbeTimeout(after: .seconds(6), reason: "audio_only_route", markAudioOnly: true)
        }
    }

    private func observeAirPlayPlayer(_ player: AVPlayer, item: AVPlayerItem) {
        airPlayExternalObs?.invalidate()
        airPlayTimeControlObs?.invalidate()
        airPlayItemStatusObs?.invalidate()

        airPlayExternalObs = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                self?.handleAirPlayExternalActive(active)
            }
        }

        airPlayTimeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.isAirPlayingVideo, self.airPlayPlayer === p else { return }
                switch status {
                case .playing:
                    self.isPlaying = true
                    self.userPaused = false
                    self.isLoading = false
                    self.isBuffering = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                case .paused:
                    self.isPlaying = false
                    self.isBuffering = false
                @unknown default:
                    break
                }
                self.syncNowPlaying()
            }
        }

        airPlayItemStatusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let status = it.status
            Task { @MainActor [weak self] in
                guard let self, status == .failed else { return }
                if self.isAirPlayingVideo, !self.airPlayRefreshAttempted, let ch = self.channel {
                    // Refresh expired Usher token once on long TV sessions before giving up.
                    self.airPlayRefreshAttempted = true
                    self.resolvedMasterURL = nil
                    self.switchAirPlayChannel(ch)
                } else {
                    self.stopAirPlay(reason: "item_failed", resumeNative: true)
                }
            }
        }
    }

    private func handleAirPlayExternalActive(_ active: Bool) {
        if active {
            guard !isAirPlayingVideo, let player = airPlayPlayer else { return }
            if isPiPActive { pipController.stop() }
            airPlayProbeTask?.cancel()
            airPlayProbeTask = nil
            isAirPlayProbing = false
            isAirPlayingVideo = true
            isLoading = false
            isBuffering = false
            isOffline = false
            isPlaying = true
            userPaused = false
            delay = nil
            bestDelay = nil
            player.isMuted = isMuted
            AudioSessionCoordinator.shared.claim(Self.airPlayAudioClaimID, kind: .playback(allowsPiP: false))
            stopNative(keepAirPlay: true)
            syncPiPAndNowPlaying()
            Breadcrumbs.add("twitch.airplay.active")
        } else if isAirPlayingVideo {
            stopAirPlay(reason: "external_ended", resumeNative: true)
        }
    }

    private func switchAirPlayChannel(_ newChannel: String) {
        guard let player = airPlayPlayer else {
            startNative(newChannel)
            return
        }
        isLoading = true
        airPlayResolveTask?.cancel()
        airPlayResolveTask = Task { [weak self] in
            guard let self else { return }
            let auth = await self.twitchAuthToken()
            guard !Task.isCancelled, self.channel == newChannel, self.isAirPlayingVideo else { return }
            do {
                let resolved = try await TwitchStreamResolver().resolveStream(channel: newChannel, authToken: auth)
                guard !Task.isCancelled, self.channel == newChannel, self.isAirPlayingVideo else { return }
                self.resolvedMasterURL = resolved.masterURL
                let item = AVPlayerItem(url: resolved.masterURL)
                self.observeAirPlayPlayer(player, item: item)
                player.replaceCurrentItem(with: item)
                player.isMuted = self.isMuted
                player.play()
                self.isLoading = false
            } catch TwitchHLSError.offline {
                guard !Task.isCancelled else { return }
                self.isOffline = true
                self.isLoading = false
                self.isPlaying = false
                self.syncNowPlaying()
            } catch {
                guard !Task.isCancelled else { return }
                self.stopAirPlay(reason: "switch_failed", resumeNative: true)
            }
        }
    }

    private func scheduleAirPlayProbeTimeout(after delay: Duration, reason: String, markAudioOnly: Bool) {
        airPlayProbeTask?.cancel()
        airPlayProbeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.isAirPlayingVideo, !self.airPlayPickerOpen else { return }
            if markAudioOnly {
                self.ignoredAudioOnlyAirPlayUID = TwitchTV.shared.airPlayOutputUID
            }
            self.stopAirPlay(reason: reason, resumeNative: false)
        }
    }

    private func stopAirPlay(reason: String, resumeNative: Bool) {
        let wasActive = isAirPlayingVideo
        airPlayProbeTask?.cancel()
        airPlayProbeTask = nil
        airPlayResolveTask?.cancel()
        airPlayResolveTask = nil
        airPlayExternalObs?.invalidate()
        airPlayExternalObs = nil
        airPlayTimeControlObs?.invalidate()
        airPlayTimeControlObs = nil
        airPlayItemStatusObs?.invalidate()
        airPlayItemStatusObs = nil

        if let player = airPlayPlayer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            airPlayPlayer = nil
        }
        madeAirPlay?.playerLayer.player = nil
        isAirPlayingVideo = false
        isAirPlayProbing = false
        AudioSessionCoordinator.shared.release(Self.airPlayAudioClaimID)

        if wasActive {
            Breadcrumbs.add("twitch.airplay.stop", ["reason": .string(reason)])
            if resumeNative, !suspended, activeMode == .lowLatency, (!claims.isEmpty || hasPiPClaim), let current = channel {
                startNative(current)
            } else {
                syncPiPAndNowPlaying()
            }
        }
    }
    #endif

    // MARK: the app's state

    func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        lastThermalShouldThrottle = snapshot.shouldThrottle
        applyThermalThrottling(shouldThrottle: snapshot.shouldThrottle)
        switch event {
        case .didEnterBackground, .hidden: suspend()
        case .becameActive, .unhidden: resume()
        default: break
        }
    }

    /// Whether active low-latency playback (background audio or Picture-in-Picture) should keep running when the app
    /// moves to the background or is hidden.
    private var keepsAliveInBackground: Bool {
        #if os(iOS)
        if TwitchTV.shared.onTV || isAirPlayingVideo { return true }
        #endif
        if hasPiPClaim || isPiPActive { return true }
        return activeMode == .lowLatency && channel != nil && !userPaused && (!isOffline || (isDualStream && !secondaryIsOffline))
    }

    /// Stops the stream for the background only when background audio, PiP, TV Mode, and AirPlay are all inactive.
    /// When background audio continues without PiP on iOS, video decoding is paused after a brief grace window (so
    /// auto-PiP can still engage on swipe-home) and seamlessly resumes on return. In dual-stream mode when locked
    /// without PiP, a muted secondary stream is immediately suspended (`dualMixer.handleBackgrounded`).
    private func suspend() {
        isInBackground = true
        guard !suspended else { return }
        if keepsAliveInBackground {
            if isDualStream {
                dualMixer.handleBackgrounded(isPiPActive: isPiPActive || hasPiPClaim)
            }
            #if os(iOS)
            if activeMode == .lowLatency && !isAirPlayingVideo && !TwitchTV.shared.onTV && !isPiPActive && !hasPiPClaim {
                backgroundVideoOffTask?.cancel()
                backgroundVideoOffTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard let self, !Task.isCancelled, self.isInBackground,
                          !self.isPiPActive, !self.hasPiPClaim, !TwitchTV.shared.onTV else { return }
                    let primary = self.nativeEngine
                    let secondary = self.secondaryNativeEngine
                    await primary?.setVideoOutputEnabled(false)
                    await secondary?.setVideoOutputEnabled(false)
                }
            }
            #endif
            return
        }
        suspended = true
        resumeChannel = channel
        resumeSecondaryChannel = secondaryChannel
        if channel != nil { stop() }
    }

    /// Back on screen: re-enables video output for background-audio sessions, resumes any lock-suspended dual slot,
    /// or restarts a suspended stream.
    private func resume() {
        isInBackground = false
        backgroundVideoOffTask?.cancel()
        backgroundVideoOffTask = nil

        if isDualStream {
            dualMixer.handleForegrounded()
        }

        if activeMode == .lowLatency && channel != nil && !isAirPlayingVideo {
            let primary = nativeEngine
            let secondary = secondaryNativeEngine
            let allowSecondary = isDualStream && dualMixer.suspendedSlot != .secondary
            Task {
                await primary?.setVideoOutputEnabled(true)
                if allowSecondary {
                    await secondary?.setVideoOutputEnabled(true)
                }
            }
        }

        guard suspended else { return }
        suspended = false
        let primary = resumeChannel
        let secondary = resumeSecondaryChannel
        resumeChannel = nil
        resumeSecondaryChannel = nil
        if let primary, !claims.isEmpty {
            if let secondary {
                playDual(primary: primary, secondary: secondary)
            } else {
                play(primary)
            }
        }
    }

    /// A memory warning, or the app leaving the screen, lets unwanted views go at once (never touching active PiP or
    /// background audio).
    func purge(_ level: PurgeLevel) {
        if isDualStream {
            applyThermalThrottling(shouldThrottle: true)
        }
        releaseResources()
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = nil
        guard claims.isEmpty, !hasPiPClaim, !isPiPActive,
              (made != nil || madeNative != nil || madeSecondaryNative != nil || nativeEngine != nil || secondaryNativeEngine != nil) else { return }
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: TwitchPlayerHost.releaseAfter)
            guard !Task.isCancelled else { return }
            self?.releaseResources()
        }
    }

    /// Lets unused views and engines go when nothing wants them: no view, no PiP, no channel, no sign-in open.
    private func releaseResources() {
        guard claims.isEmpty, !hasPiPClaim, !isPiPActive, channel == nil, secondaryChannel == nil, popup == nil else { return }
        releaseTask?.cancel()
        releaseTask = nil

        pipController.detach()
        #if os(iOS)
        dualPiPController.detach()
        #else
        dualFloatingPanel.close(restoredUI: false)
        #endif
        if let view = made {
            made = nil
            pageLoaded = false
            view.stopLoading()
            view.configuration.userContentController.removeScriptMessageHandler(forName: TwitchEmbed.handler)
            view.uiDelegate = nil
            view.removeFromSuperview()
        }
        if let native = madeNative {
            madeNative = nil
            native.removeFromSuperview()
        }
        if let secondary = madeSecondaryNative {
            madeSecondaryNative = nil
            secondary.removeFromSuperview()
        }
        #if os(iOS)
        stopAirPlay(reason: "purge", resumeNative: false)
        if let ap = madeAirPlay {
            madeAirPlay = nil
            ap.removeFromSuperview()
        }
        #endif
        if let engine = nativeEngine {
            nativeEngine = nil
            let prev = nativeLifecycleTask
            prev?.cancel()
            nativeLifecycleTask = Task {
                await prev?.value
                await engine.stop()
            }
        }
        if let engine = secondaryNativeEngine {
            secondaryNativeEngine = nil
            let prev = secondaryNativeLifecycleTask
            prev?.cancel()
            secondaryNativeLifecycleTask = Task {
                await prev?.value
                await engine.stop()
            }
        }
    }

    // MARK: popups

    fileprivate func showPopup(_ view: WKWebView) {
        popup = TwitchPopup(view: view)
    }

    /// The popup closed (sign-in done, or the owner closed it): reload the player.
    func dismissPopup() {
        guard popup != nil else { return }
        popup = nil
        hasCachedAuthToken = false
        reload()
    }

    fileprivate func popupClosed(_ view: WKWebView) {
        if popup?.view === view { dismissPopup() }
    }

    private func reset() {
        delay = nil
        bestDelay = nil
        isPlaying = false
        userPaused = false
        isLoading = false
        isBuffering = false
        isOffline = false
        isLowLatencyStream = false
        isCatchingUp = false
        variants = []
        selectedVariantID = nil
        behindSince = nil
        jumpCheck?.cancel()
        jumpCheck = nil
    }

    private func recordDelay(_ d: Double) {
        delay = d
        bestDelay = min(bestDelay ?? d, d)
        if isCatchingUp, !isBehind {
            isCatchingUp = false
            jumpCheck?.cancel()
        }
        if isBehind {
            let now = Date.now
            let since = behindSince ?? now
            behindSince = since
            if autoCatchUp, !isCatchingUp,
               now.timeIntervalSince(since) >= Self.autoAfterSeconds,
               now.timeIntervalSince(lastJump) >= Self.autoCooldown {
                jumpToLive()
            }
        } else {
            behindSince = nil
        }
    }

    // MARK: native engine events

    private static func shortFallbackReason(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timeout") { return "startup_timeout" }
        if lower.contains("segment") { return "segment_failed" }
        if lower.contains("playlist") { return "playlist_unavailable" }
        if lower.contains("codec") { return "unsupported_codec" }
        if lower.contains("integrity") { return "integrity" }
        if lower.contains("stall") { return "stalled" }
        return "error"
    }

    private func receiveNative(_ event: TwitchNativeEvent, sessionID: UInt64) {
        guard sessionID == nativeSessionID, activeMode == .lowLatency else { return }
        switch event {
        case .loading:
            isLoading = true
            isOffline = false
        case .streamURL(let url):
            resolvedMasterURL = url
            #if os(iOS)
            maybeStartAirPlayFromRoute()
            #endif
        case .variants(let list, let selectedID):
            variants = list
            selectedVariantID = selectedID
            if !hasLoggedVariants {
                hasLoggedVariants = true
                Breadcrumbs.add("twitch.native.variants", ["count": .int(list.count)])
            }
            if isDualStream && lastThermalShouldThrottle {
                applyThermalThrottling(shouldThrottle: true)
            }
            syncPiPAndNowPlaying()
        case .playing:
            isPlaying = true
            isLoading = false
            isBuffering = false
            isOffline = false
            if let started = nativeStartInstant {
                let elapsed = ContinuousClock.now - started
                let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                nativeStartInstant = nil
                Breadcrumbs.add("twitch.native.playing", ["ms": .int(max(0, ms))])
            }
            syncPiPAndNowPlaying()
        case .paused:
            isPlaying = false
            syncNowPlaying()
        case .userPausedChanged(let paused):
            userPaused = paused
            if paused {
                isPlaying = false
            }
            syncPiPAndNowPlaying()
        case .offline:
            isOffline = true
            isPlaying = false
            isLoading = false
            isBuffering = false
            delay = nil
            nativeStartInstant = nil
            if isPiPActive && !isDualStream { pipController.stop() }
            syncPiPAndNowPlaying()
            Breadcrumbs.add("twitch.native.offline")
        case .stats(let stats):
            isLowLatencyStream = stats.isLowLatency
            // Self-heal if `.loading` ever raced past `.playing`: active synchronizer clock means playback is live.
            if stats.isClockStarted && isLoading {
                isLoading = false
                if !isPlaying && stats.rate > 0 {
                    isPlaying = true
                }
            }
            if stats.isBuffering != lastLoggedBuffering {
                lastLoggedBuffering = stats.isBuffering
                Breadcrumbs.add("twitch.native.buffering", ["on": .bool(stats.isBuffering)])
            }
            isBuffering = stats.isBuffering
            if let d = stats.delay, d > 0, isPlaying {
                recordDelay(d)
            }
        case .failed(let reason):
            Breadcrumbs.add("twitch.native.fallback", ["reason": .string(Self.shortFallbackReason(reason))])
            // Dual-stream runs two native display layers; never drop into a single WebView embed while dual is active.
            if isDualStream {
                isOffline = true
                isPlaying = false
                isLoading = false
                isBuffering = false
                syncPiPAndNowPlaying()
                return
            }
            // Native playback could not run for this stream: fall back to the Twitch embed for this session without
            // overwriting `preferredMode`, so the next channel tries low latency again.
            guard let current = channel else { return }
            if isPiPActive { pipController.stop() }
            stopNative()
            fellBackToEmbed = true
            activeMode = .embed
            reset()
            syncPiPAndNowPlaying()
            startEmbed(current)
        }
    }

    private func receiveSecondaryNative(_ event: TwitchNativeEvent, sessionID: UInt64) {
        guard sessionID == secondaryNativeSessionID, activeMode == .lowLatency else { return }
        switch event {
        case .loading:
            secondaryIsLoading = true
            secondaryIsOffline = false
        case .streamURL:
            break
        case .variants(let list, let selectedID):
            secondaryVariants = list
            secondarySelectedVariantID = selectedID
            if lastThermalShouldThrottle {
                applyThermalThrottling(shouldThrottle: true)
            }
            syncPiPAndNowPlaying()
        case .playing:
            secondaryIsPlaying = true
            secondaryIsLoading = false
            secondaryIsBuffering = false
            secondaryIsOffline = false
            if let started = secondaryStartInstant {
                let elapsed = ContinuousClock.now - started
                let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                secondaryStartInstant = nil
                Breadcrumbs.add("twitch.native.secondary.playing", ["ms": .int(max(0, ms))])
            }
            syncPiPAndNowPlaying()
        case .paused:
            secondaryIsPlaying = false
            syncNowPlaying()
        case .userPausedChanged(let paused):
            if paused {
                secondaryIsPlaying = false
            }
            syncPiPAndNowPlaying()
        case .offline:
            secondaryIsOffline = true
            secondaryIsPlaying = false
            secondaryIsLoading = false
            secondaryIsBuffering = false
            secondaryDelay = nil
            secondaryStartInstant = nil
            syncPiPAndNowPlaying()
            Breadcrumbs.add("twitch.native.secondary.offline")
        case .stats(let stats):
            if stats.isClockStarted && secondaryIsLoading {
                secondaryIsLoading = false
                if !secondaryIsPlaying && stats.rate > 0 {
                    secondaryIsPlaying = true
                }
            }
            secondaryIsBuffering = stats.isBuffering
            if let d = stats.delay, d > 0, secondaryIsPlaying {
                secondaryDelay = d
            }
        case .failed(let reason):
            secondaryIsOffline = true
            secondaryIsPlaying = false
            secondaryIsLoading = false
            secondaryIsBuffering = false
            secondaryStartInstant = nil
            syncPiPAndNowPlaying()
            Breadcrumbs.add("twitch.native.secondary.failed", ["reason": .string(Self.shortFallbackReason(reason))])
        }
    }

    // MARK: the embed page

    fileprivate func receive(_ body: Any) {
        guard activeMode == .embed, let m = body as? [String: Any], let e = m["e"] as? String else { return }
        switch e {
        case "ready": embedReady = true
        case "playing": isPlaying = true; isOffline = false; embedReady = true
        case "paused": isPlaying = false
        case "offline": isOffline = true; isPlaying = false; delay = nil
        case "online": isOffline = false
        case "stats":
            let paused = (m["paused"] as? Bool) ?? false
            guard let d = (m["delay"] as? NSNumber)?.doubleValue, d > 0, !paused else { return }
            recordDelay(d)
        default: break
        }
    }
}

/// The web view's message handler and UI delegate. Holds the host weakly, so the web view doesn't keep it alive in a cycle.
@MainActor
private final class TwitchMessageProxy: NSObject, WKScriptMessageHandler, WKUIDelegate {
    weak var host: TwitchPlayerHost?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.receive(message.body)
    }

    // window.open from the embed (its "Log in"): a web view from WebKit's configuration, so cookies are shared and
    // the popup keeps its opener.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        host?.showPopup(popup)
        return popup
    }

    // window.close from the sign-in page once it is done.
    func webViewDidClose(_ webView: WKWebView) {
        host?.popupClosed(webView)
    }
}

/// The popup the embed opened (Twitch's sign-in), shown in a sheet.
struct TwitchPopup: Identifiable {
    let id = UUID()
    let view: WKWebView
}

private struct TwitchPopupSheet: View {
    let popup: TwitchPopup
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            TwitchPopupWeb(view: popup.view)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Copy.Twitch.playerSignIn)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        CloseButton(cancels: true, action: onClose)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 640)
        #endif
    }
}

#if os(iOS)
private struct TwitchPopupWeb: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct TwitchPopupWeb: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

/// The player for one channel. It adopts the app's one player, so the same channel keeps playing through layout changes and
/// a new channel switches in place. `showsDelay` adds the auto-hiding HUD (mode toggle, delay badge, and native controls).
struct TwitchPlayer: View {
    let channel: String
    var showsDelay = true

    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var id = UUID()
    @State private var showsNativeControls = false
    @State private var isHovering = false
    @State private var showsTransientEmbedPill = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var hideEmbedPillTask: Task<Void, Never>?
    private var host: TwitchPlayerHost { .shared }

    private var isHolder: Bool { host.holder == id }
    private var isNative: Bool { host.activeMode == .lowLatency }
    private var showsNativeHUD: Bool {
        isNative && (showsNativeControls || isHovering || (!host.isPlaying && !host.isLoading && !host.isOffline))
    }
    private var showsTopPills: Bool {
        showsNativeHUD || (!isNative && (showsTransientEmbedPill || isHovering))
    }

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        ZStack {
            TwitchPlayerSlot(
                holds: isHolder,
                mode: host.activeMode,
                airPlayActive: host.isAirPlayingVideo,
                airPlayProbing: host.isAirPlayProbing,
                pipActive: host.isPiPActive
            )
                .background(Color.black)
                .mediaMask()
                .overlay {
                    if host.holder != nil, !isHolder {
                        Text(Copy.Twitch.playingElsewhere)
                            .font(Font.cobalt(13, .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

            // Native-only interactive tap layer & state overlays. Never present in embed mode so Twitch's iframe receives all input.
            if isHolder, isNative {
                if showsDelay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleNativeControls() }
                }
                nativeCenterStatus
            }

            if showsDelay, isHolder {
                ZStack {
                    VStack(spacing: 0) {
                        if showsTopPills {
                            MediaEdgeVignette(edge: .top, height: 64, intensity: 0.34)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 0)
                        if showsNativeHUD {
                            MediaEdgeVignette(edge: .bottom, height: 80, intensity: 0.42)
                                .transition(.opacity)
                        }
                    }
                    .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        if showsTopPills {
                            MediaGlassGroup(spacing: 6) {
                                HStack(spacing: 6) {
                                    Spacer(minLength: 0)
                                    TwitchModeMenu(host: host) {
                                        if isNative {
                                            scheduleHideControls()
                                        } else {
                                            flashEmbedPill()
                                        }
                                    }
                                    TwitchDelayBadge(host: host) {
                                        if isNative {
                                            scheduleHideControls()
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                            .padding(.horizontal, 10)
                            .transition(.opacity)
                        }

                        Spacer(minLength: 0)

                        if showsNativeHUD {
                            TwitchNativeControlBar(host: host) {
                                scheduleHideControls()
                            }
                            .padding(8)
                            .transition(.opacity)
                        }
                    }
                }
            }
        }
        .onHover { hovering in
            guard showsDelay else { return }
            isHovering = hovering
            if !hovering && showsNativeControls && host.isPlaying {
                scheduleHideControls()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsTopPills)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsNativeHUD)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(channel)'s stream")
        // only the view holding the player shows its sign-in sheet
        .sheet(item: Binding(get: { isHolder ? host.popup : nil },
                             set: { if $0 == nil, isHolder { host.dismissPopup() } })) { popup in
            TwitchPopupSheet(popup: popup) { host.dismissPopup() }
        }
        .onAppear {
            host.claim(id, channel: channel)
            if let pane {
                host.registerRestoreHandler { [weak pane] ch in
                    pane?.open(.stream(ch))
                }
            }
        }
        .onDisappear {
            hideControlsTask?.cancel()
            hideControlsTask = nil
            hideEmbedPillTask?.cancel()
            hideEmbedPillTask = nil
            isHovering = false
            host.release(id)
        }
        .onChange(of: channel) { _, new in
            if isHolder { host.play(new) }
        }
        .onChange(of: host.isPlaying) { _, playing in
            if playing && showsNativeControls {
                scheduleHideControls()
            }
        }
        .onChange(of: host.activeMode) { _, mode in
            if mode == .embed {
                showsNativeControls = false
                hideControlsTask?.cancel()
                hideControlsTask = nil
                flashEmbedPill()
            } else {
                showsTransientEmbedPill = false
                hideEmbedPillTask?.cancel()
                hideEmbedPillTask = nil
            }
        }
        .onChange(of: host.fellBackToEmbed) { _, fellBack in
            if fellBack {
                flashEmbedPill()
            }
        }
    }

    @ViewBuilder
    private var nativeCenterStatus: some View {
        if host.isOffline {
            Text(Copy.Twitch.offline)
                .font(Font.cobalt(12, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .mediaGlassCapsule(interactive: false)
        } else if host.isLoading || host.isBuffering {
            ProgressView()
                .tint(.white)
                .padding(12)
                .mediaGlassCircle(interactive: false)
        } else if host.isAirPlayingVideo {
            HStack(spacing: 6) {
                Image(systemName: Symbol.Twitch.airPlay)
                    .font(.system(size: 12, weight: .semibold))
                Text(Copy.Twitch.airPlaying)
                    .font(Font.cobalt(12, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .mediaGlassCapsule(interactive: false)
        } else if host.isPiPActive {
            HStack(spacing: 6) {
                Image(systemName: Symbol.Twitch.pipExit)
                    .font(.system(size: 12, weight: .semibold))
                Text(Copy.Twitch.inPiP)
                    .font(Font.cobalt(12, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .mediaGlassCapsule(interactive: false)
        } else if host.isAudioOnly {
            HStack(spacing: 6) {
                Image(systemName: Symbol.Twitch.audioOnly)
                    .font(.system(size: 12, weight: .semibold))
                Text(Copy.Twitch.audioOnly)
                    .font(Font.cobalt(12, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .mediaGlassCapsule(interactive: false)
        }
    }

    private func toggleNativeControls() {
        showsNativeControls.toggle()
        if showsNativeControls {
            scheduleHideControls()
        } else {
            hideControlsTask?.cancel()
            hideControlsTask = nil
        }
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            if host.isPlaying && !isHovering {
                showsNativeControls = false
            }
        }
    }

    private func flashEmbedPill() {
        guard showsDelay else { return }
        showsTransientEmbedPill = true
        hideEmbedPillTask?.cancel()
        hideEmbedPillTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            if !isHovering {
                showsTransientEmbedPill = false
            }
        }
    }
}

/// Compact Clear Liquid Glass capsule in the auto-hiding player HUD: switches between low-latency native playback and
/// Twitch's embed, and exposes native quality + mute controls.
struct TwitchModeMenu: View {
    let host: TwitchPlayerHost
    var onInteract: (() -> Void)? = nil

    private var pillIcon: String {
        host.activeMode == .lowLatency ? Symbol.Twitch.lowLatency : Symbol.Twitch.embed
    }

    private var pillLabel: String {
        if host.activeMode == .lowLatency {
            return Copy.Twitch.playerLowLatency
        }
        return host.fellBackToEmbed ? Copy.Twitch.usingEmbed : Copy.Twitch.playerEmbedShort
    }

    var body: some View {
        Menu {
            Section(Copy.Twitch.playerMode) {
                Button {
                    host.setMode(.lowLatency)
                    onInteract?()
                } label: {
                    if host.activeMode == .lowLatency {
                        Label(Copy.Twitch.playerLowLatency, systemImage: "checkmark")
                    } else {
                        Label(Copy.Twitch.playerLowLatency, systemImage: Symbol.Twitch.lowLatency)
                    }
                }
                Button {
                    host.setMode(.embed)
                    onInteract?()
                } label: {
                    if host.activeMode == .embed {
                        Label(Copy.Twitch.playerEmbed, systemImage: "checkmark")
                    } else {
                        Label(Copy.Twitch.playerEmbed, systemImage: Symbol.Twitch.embed)
                    }
                }
            }

            if host.activeMode == .lowLatency, !host.isAirPlayingVideo, !host.variants.isEmpty {
                Menu {
                    ForEach(host.variants) { variant in
                        Button {
                            host.selectVariant(variant.id)
                            onInteract?()
                        } label: {
                            if variant.id == host.selectedVariantID {
                                Label(variant.shortLabel, systemImage: "checkmark")
                            } else {
                                Text(variant.shortLabel)
                            }
                        }
                    }
                } label: {
                    Label(host.selectedVariant?.shortLabel ?? Copy.Twitch.quality, systemImage: Symbol.Twitch.quality)
                }
            }

            if host.activeMode == .lowLatency {
                Divider()
                Button {
                    host.toggleMute()
                    onInteract?()
                } label: {
                    Label(
                        host.isMuted ? Copy.Twitch.unmute : Copy.Twitch.mute,
                        systemImage: host.isMuted ? Symbol.Twitch.unmuted : Symbol.Twitch.muted
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pillIcon)
                    .font(.system(size: 10, weight: .bold))
                Text(pillLabel)
                    .font(Font.cobalt(11, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .mediaGlassCapsule()
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Twitch.playerMode)
        .accessibilityValue(pillLabel)
        .help(Copy.Twitch.playerMode)
    }
}

/// Clear Liquid Glass bottom HUD strip shown on tap in low-latency native mode.
private struct TwitchNativeControlBar: View {
    let host: TwitchPlayerHost
    let onInteract: () -> Void

    private var showsPauseGlyph: Bool {
        !host.userPaused && (host.isPlaying || host.isLoading || host.isBuffering)
    }

    var body: some View {
        MediaGlassGroup(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    host.setPaused(showsPauseGlyph)
                    onInteract()
                } label: {
                    Label(showsPauseGlyph ? Copy.Twitch.pause : Copy.Twitch.play,
                          systemImage: showsPauseGlyph ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPauseGlyph ? Copy.Twitch.pause : Copy.Twitch.play)

                Button {
                    host.toggleMute()
                    onInteract()
                } label: {
                    Label(host.isMuted ? Copy.Twitch.unmute : Copy.Twitch.mute,
                          systemImage: host.isMuted ? Symbol.Twitch.muted : Symbol.Twitch.unmuted)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(host.isMuted ? Copy.Twitch.unmute : Copy.Twitch.mute)

                Spacer(minLength: 0)

                if host.canTogglePiP {
                    Button {
                        host.togglePiP()
                        onInteract()
                    } label: {
                        Label(
                            host.isPiPActive ? Copy.Twitch.pipExit : Copy.Twitch.pipEnter,
                            systemImage: host.isPiPActive ? Symbol.Twitch.pipExit : Symbol.Twitch.pipEnter
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(host.isPiPActive ? Copy.Twitch.pipExit : Copy.Twitch.pipEnter)
                }

                #if os(iOS)
                TwitchAirPlayButton(tint: .white)
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .accessibilityLabel(Copy.Twitch.airPlay)
                #endif

                if !host.isAirPlayingVideo, !host.variants.isEmpty {
                    Menu {
                        ForEach(host.variants) { variant in
                            Button {
                                host.selectVariant(variant.id)
                                onInteract()
                            } label: {
                                if variant.id == host.selectedVariantID {
                                    Label(variant.shortLabel, systemImage: "checkmark")
                                } else {
                                    Text(variant.shortLabel)
                                }
                            }
                        }
                    } label: {
                        Text(host.selectedVariant?.shortLabel ?? Copy.Twitch.quality)
                            .font(Font.cobalt(11, .semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .mediaGlassCapsule()
                            .frame(minHeight: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Twitch.quality)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .mediaGlassCapsule(interactive: false)
        }
    }
}

/// "2.1 s" while near live; "4.8 s behind · jump to live" when the stream drifted. Tap to jump.
struct TwitchDelayBadge: View {
    let host: TwitchPlayerHost
    var onInteract: (() -> Void)? = nil

    var body: some View {
        if let delay = host.delay {
            Button {
                host.jumpToLive()
                onInteract?()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(host.isBehind ? Color.yellow : Color.green)
                        .frame(width: 6, height: 6)
                    Text(host.isCatchingUp ? Copy.Twitch.catchingUp
                         : host.isBehind ? Copy.Twitch.behind(delay) : Copy.Twitch.delay(delay))
                        .font(Font.cobalt(11, .semibold).monospacedDigit())
                    if host.isBehind, !host.isCatchingUp {
                        Image(systemName: Symbol.Twitch.jumpToLive)
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .mediaGlassCapsule()
                .frame(minHeight: Metrics.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(host.isBehind ? Copy.Twitch.behind(delay) : Copy.Twitch.delay(delay))
            .accessibilityHint(Copy.Twitch.jumpToLive)
            .help(Copy.Twitch.jumpToLive)
            .animation(.easeOut(duration: 0.2), value: host.isBehind)
        }
    }
}

/// Where the shared player view (native display layer, AirPlay layer, or web view) sits while this view holds it.
/// Holding is decided by `TwitchPlayer` (appear and disappear); the slot only moves the active view in and removes the inactive one.
#if os(iOS)
private final class TwitchPlayerSlotView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}

private struct TwitchPlayerSlot: UIViewRepresentable {
    let holds: Bool
    let mode: TwitchPlayerMode
    let airPlayActive: Bool
    let airPlayProbing: Bool
    let pipActive: Bool

    func makeUIView(context: Context) -> TwitchPlayerSlotView {
        let slot = TwitchPlayerSlotView()
        slot.backgroundColor = .black
        slot.clipsToBounds = true
        return slot
    }

    func updateUIView(_ slot: TwitchPlayerSlotView, context: Context) {
        // only a holder asks for the active view, so a slot left on screen never rebuilds one that was let go
        guard holds else { return }
        let host = TwitchPlayerHost.shared
        let primary: UIView
        var backing: UIView?
        if mode == .lowLatency {
            if airPlayActive {
                primary = host.airPlayView
            } else {
                primary = host.nativeView
                if airPlayProbing {
                    backing = host.airPlayView
                }
            }
        } else {
            primary = host.webView
        }

        // Never yank `nativeView` out of Picture-in-Picture while PiP is hosting its `AVSampleBufferDisplayLayer`.
        let holdNativeForPiP = pipActive && primary === host.nativeView

        for sub in slot.subviews where sub !== primary && sub !== backing {
            sub.removeFromSuperview()
        }
        if let backing {
            if backing.superview !== slot {
                backing.removeFromSuperview()
                backing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                slot.insertSubview(backing, at: 0)
            }
            if backing.frame != slot.bounds {
                backing.frame = slot.bounds
            }
        }
        if !holdNativeForPiP {
            if primary.superview !== slot {
                primary.removeFromSuperview()
                primary.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                slot.addSubview(primary)
                if primary === host.nativeView {
                    host.notifyNativeViewReparented(for: .primary)
                }
            } else if backing != nil {
                slot.bringSubviewToFront(primary)
            }
            if primary.frame != slot.bounds {
                primary.frame = slot.bounds
            }
        }
    }
}
#else
private final class TwitchPlayerSlotView: NSView {
    override func layout() {
        super.layout()
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}

private struct TwitchPlayerSlot: NSViewRepresentable {
    let holds: Bool
    let mode: TwitchPlayerMode
    let airPlayActive: Bool
    let airPlayProbing: Bool
    let pipActive: Bool

    func makeNSView(context: Context) -> TwitchPlayerSlotView {
        let slot = TwitchPlayerSlotView()
        slot.wantsLayer = true
        slot.layer?.backgroundColor = NSColor.black.cgColor
        return slot
    }

    func updateNSView(_ slot: TwitchPlayerSlotView, context: Context) {
        // only a holder asks for the active view, so a slot left on screen never rebuilds one that was let go
        guard holds else { return }
        let host = TwitchPlayerHost.shared
        let target: NSView = mode == .lowLatency
            ? host.nativeView
            : host.webView
        let holdNativeForPiP = pipActive && target === host.nativeView

        for sub in slot.subviews where sub !== target {
            sub.removeFromSuperview()
        }
        if !holdNativeForPiP {
            if target.superview !== slot {
                target.removeFromSuperview()
                target.autoresizingMask = [.width, .height]
                slot.addSubview(target)
                if target === host.nativeView {
                    host.notifyNativeViewReparented(for: .primary)
                }
            }
            if target.frame != slot.bounds {
                target.frame = slot.bounds
            }
        }
    }
}
#endif

// MARK: - Dual-Stream Native Video Slot Surfaces & iOS PiP Source Anchor

#if os(iOS)
/// Embeds a single `TwitchNativeVideoView` (Slot A or Slot B) in `TwitchDualStage` while holding a live claim.
/// Never yanks the view away while dual PiP owns both `AVSampleBufferDisplayLayer` views.
struct TwitchNativeSlotSurface: UIViewRepresentable {
    let slot: TwitchDualSlot
    let holds: Bool
    let pipActive: Bool

    func makeUIView(context: Context) -> UIView {
        let container = TwitchDualSurfaceContainerView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard holds else { return }
        let host = TwitchPlayerHost.shared
        let target = host.nativeView(for: slot)
        for sub in container.subviews where sub !== target {
            sub.removeFromSuperview()
        }
        guard !pipActive else { return }
        if target.superview !== container {
            target.removeFromSuperview()
            target.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(target)
            host.notifyNativeViewReparented(for: slot)
        }
        if target.frame != container.bounds {
            target.frame = container.bounds
        }
    }
}

private final class TwitchDualSurfaceContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}

/// Zero-chrome `UIView` mounted behind `TwitchDualStage` so `AVPictureInPictureController.ContentSource`
/// has a live `activeVideoCallSourceView` in the window hierarchy for dual-stream PiP.
struct TwitchDualPiPSourceAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TwitchDualPiPAnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if view.window != nil {
            TwitchPlayerHost.shared.registerDualPiPSourceView(view)
        }
    }
}

private final class TwitchDualPiPAnchorView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            TwitchPlayerHost.shared.registerDualPiPSourceView(self)
        }
    }
}
#else
/// Embeds a single `TwitchNativeVideoView` (Slot A or Slot B) in `TwitchDualStage` on macOS.
/// Never yanks the view away while `TwitchDualFloatingPanel` is presenting both streams.
struct TwitchNativeSlotSurface: NSViewRepresentable {
    let slot: TwitchDualSlot
    let holds: Bool
    let pipActive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = TwitchDualSurfaceContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard holds else { return }
        let host = TwitchPlayerHost.shared
        let target = host.nativeView(for: slot)
        for sub in container.subviews where sub !== target {
            sub.removeFromSuperview()
        }
        guard !pipActive else { return }
        if target.superview !== container {
            target.removeFromSuperview()
            target.autoresizingMask = [.width, .height]
            container.addSubview(target)
            host.notifyNativeViewReparented(for: slot)
        }
        if target.frame != container.bounds {
            target.frame = container.bounds
        }
    }
}

private final class TwitchDualSurfaceContainerView: NSView {
    override func layout() {
        super.layout()
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}
#endif

