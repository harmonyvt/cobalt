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
final class TwitchPlayerHost: LifecycleAware, Purgeable {
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

    /// The channel playing now, nil while stopped.
    private(set) var channel: String?
    /// Latency to the broadcaster in seconds, nil until the stream plays.
    private(set) var delay: Double?
    /// The lowest delay seen on this channel: what this stream can do.
    private(set) var bestDelay: Double?
    private(set) var isPlaying = false
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
    /// The view holding the player surface now.
    private(set) var holder: UUID?
    /// Jump to live by itself when the stream drifts behind (on by default).
    var autoCatchUp = true
    /// The popup the embed opened (Twitch's sign-in), shown in a sheet by the holding view.
    private(set) var popup: TwitchPopup?

    var selectedVariant: TwitchVariant? {
        variants.first { $0.id == selectedVariantID }
    }

    var isAudioOnly: Bool {
        activeMode == .lowLatency && selectedVariant?.isAudioOnly == true
    }

    /// Seconds behind live more than this stream's best, nil until known.
    var behind: Double? {
        guard let delay, let bestDelay else { return nil }
        return max(0, delay - bestDelay)
    }
    var isBehind: Bool { (behind ?? 0) >= Self.behindBy }

    /// The web view while there is one; `webView` builds it on demand.
    @ObservationIgnored private var made: WKWebView?
    /// The native display-layer view while there is one; `nativeView` builds it on demand.
    @ObservationIgnored private var madeNative: TwitchNativeVideoView?
    @ObservationIgnored private var nativeEngine: TwitchNativeEngine?
    @ObservationIgnored private var nativeSessionID: UInt64 = 0
    @ObservationIgnored private var nativeStartTask: Task<Void, Never>?
    @ObservationIgnored private var preferredQualityID: String?

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

    private init() {
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(TwitchPlayerMode.init(rawValue:)) ?? .lowLatency
        self.preferredMode = savedMode
        self.activeMode = savedMode
        self.preferredQualityID = UserDefaults.standard.string(forKey: Self.qualityKey)

        let proxy = TwitchMessageProxy()
        self.proxy = proxy
        proxy.host = self
        AppLifecycle.shared.register(self, order: .media)
        AppLifecycle.shared.register(purgeable: self)
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

    /// The app's one native sample-buffer video view, built on first need and again after `releaseResources`.
    var nativeView: TwitchNativeVideoView {
        if let madeNative { return madeNative }
        let view = TwitchNativeVideoView(frame: .zero)
        madeNative = view
        return view
    }

    // MARK: holders

    /// A view wants the stream. The newest claim holds the player surface.
    func claim(_ id: UUID, channel: String) {
        stopTask?.cancel()
        stopTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        claims.removeAll { $0 == id }
        claims.append(id)
        holder = id
        play(channel)
    }

    /// A view went. The claim before it takes the player back; with none left the stream stops shortly after (a layout
    /// change removes one view and adds another in the same moment, so this waits a beat).
    func release(_ id: UUID) {
        claims.removeAll { $0 == id }
        holder = claims.last
        guard claims.isEmpty else { return }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.claims.isEmpty else { return }
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
            stopNative()
        } else {
            stopEmbed()
        }
        activeMode = mode
        reset()
        if let current {
            startActive(current)
        }
    }

    func selectVariant(_ id: String) {
        guard activeMode == .lowLatency else { return }
        preferredQualityID = id
        UserDefaults.standard.set(id, forKey: Self.qualityKey)
        selectedVariantID = id
        let engine = nativeEngine
        Task { await engine?.selectVariant(id: id) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
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
        // off screen: nothing plays until the app is back, then this channel does
        if suspended {
            resumeChannel = c
            return
        }
        guard c != self.channel else { return }
        // Switching to a fresh channel resets any per-channel fallback so the owner's preferred mode runs again.
        if fellBackToEmbed {
            fellBackToEmbed = false
            if activeMode != preferredMode {
                if activeMode == .embed { stopEmbed() } else { stopNative() }
                activeMode = preferredMode
            }
        }
        self.channel = c
        reset()
        startActive(c)
    }

    private func startActive(_ channel: String) {
        switch activeMode {
        case .lowLatency:
            startNative(channel)
        case .embed:
            startEmbed(channel)
        }
    }

    private func startNative(_ channel: String) {
        stopEmbed()
        nativeStartTask?.cancel()
        nativeSessionID &+= 1
        let sessionID = nativeSessionID
        let rendererBox = TwitchVideoRendererBox(nativeView.displayLayer.sampleBufferRenderer)
        let engine = ensureNativeEngine()
        let muted = isMuted
        let preferredQuality = preferredQualityID
        isLoading = true

        nativeStartTask = Task { [weak self] in
            guard let self else { return }
            let authToken = await self.twitchAuthToken()
            guard !Task.isCancelled, self.nativeSessionID == sessionID,
                  self.activeMode == .lowLatency, self.channel == channel else { return }
            await engine.setEventHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.receiveNative(event, sessionID: sessionID)
                }
            }
            await engine.attach(videoRenderer: rendererBox)
            await engine.setMuted(muted)
            await engine.start(channel: channel, authToken: authToken, preferredVariantID: preferredQuality)
        }
    }

    private func stopNative() {
        nativeStartTask?.cancel()
        nativeStartTask = nil
        nativeSessionID &+= 1
        let engine = nativeEngine
        Task { await engine?.stop() }
    }

    private func ensureNativeEngine() -> TwitchNativeEngine {
        if let nativeEngine { return nativeEngine }
        let engine = TwitchNativeEngine()
        nativeEngine = engine
        return engine
    }

    /// Reads Twitch's `auth-token` cookie from WebKit's persistent store without instantiating a `WKWebView`.
    private func twitchAuthToken() async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.first(where: { $0.name == "auth-token" && $0.domain.contains("twitch.tv") })?.value
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

    /// Stops whichever engine is active. Views nobody wants go after `releaseAfter`.
    func stop() {
        channel = nil
        stopEmbed()
        stopNative()
        reset()
        scheduleRelease()
    }

    /// The pane's play / pause button (and native HUD play / pause).
    func setPaused(_ paused: Bool) {
        guard channel != nil else { return }
        switch activeMode {
        case .lowLatency:
            isPlaying = !paused
            let engine = nativeEngine
            Task { await engine?.setPaused(paused) }
        case .embed:
            made?.evaluateJavaScript(paused ? "window.cobaltPause && window.cobaltPause()" : "window.cobaltPlay && window.cobaltPlay()")
        }
    }

    /// Back to the live edge.
    func jumpToLive() {
        guard channel != nil else { return }
        lastJump = .now
        behindSince = nil
        isCatchingUp = true
        jumpCheck?.cancel()

        switch activeMode {
        case .lowLatency:
            let engine = nativeEngine
            Task { await engine?.jumpToLive() }
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

    /// Reloads the active engine for the current channel (e.g. after a sign-in).
    func reload() {
        guard let channel else { return }
        reset()
        switch activeMode {
        case .lowLatency:
            startNative(channel)
        case .embed:
            loadEmbed(channel)
        }
    }

    // MARK: the app's state

    func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        switch event {
        case .didEnterBackground, .hidden: suspend()
        case .becameActive, .unhidden: resume()
        default: break
        }
    }

    /// Stops the stream for the background, remembering the channel. Not while capystore's TV window shows it: the owner
    /// is watching on the TV with the phone locked.
    private func suspend() {
        guard !suspended else { return }
        #if os(iOS)
        if TwitchTV.shared.onTV { return }
        #endif
        suspended = true
        resumeChannel = channel
        if channel != nil { stop() }
    }

    /// Back on screen: the stream starts again if a view still holds a claim.
    private func resume() {
        guard suspended else { return }
        suspended = false
        let channel = resumeChannel
        resumeChannel = nil
        if let channel, !claims.isEmpty { play(channel) }
    }

    /// A memory warning, or the app leaving the screen, lets unwanted views go at once.
    func purge(_ level: PurgeLevel) {
        releaseResources()
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = nil
        guard claims.isEmpty, (made != nil || madeNative != nil || nativeEngine != nil) else { return }
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: TwitchPlayerHost.releaseAfter)
            guard !Task.isCancelled else { return }
            self?.releaseResources()
        }
    }

    /// Lets unused views and engines go when nothing wants them: no view, no channel, no sign-in open.
    private func releaseResources() {
        guard claims.isEmpty, channel == nil, popup == nil else { return }
        releaseTask?.cancel()
        releaseTask = nil

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
        if let engine = nativeEngine {
            nativeEngine = nil
            Task { await engine.stop() }
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
        reload()
    }

    fileprivate func popupClosed(_ view: WKWebView) {
        if popup?.view === view { dismissPopup() }
    }

    private func reset() {
        delay = nil
        bestDelay = nil
        isPlaying = false
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

    private func receiveNative(_ event: TwitchNativeEvent, sessionID: UInt64) {
        guard sessionID == nativeSessionID, activeMode == .lowLatency else { return }
        switch event {
        case .loading:
            isLoading = true
            isOffline = false
        case .variants(let list, let selectedID):
            variants = list
            selectedVariantID = selectedID
        case .playing:
            isPlaying = true
            isLoading = false
            isBuffering = false
            isOffline = false
        case .paused:
            isPlaying = false
        case .offline:
            isOffline = true
            isPlaying = false
            isLoading = false
            isBuffering = false
            delay = nil
        case .stats(let stats):
            isLowLatencyStream = stats.isLowLatency
            isBuffering = stats.isBuffering
            if let d = stats.delay, d > 0, isPlaying {
                recordDelay(d)
            }
        case .failed:
            // Native playback could not run for this stream: fall back to the Twitch embed for this session without
            // overwriting `preferredMode`, so the next channel tries low latency again.
            guard let current = channel else { return }
            stopNative()
            fellBackToEmbed = true
            activeMode = .embed
            reset()
            startEmbed(current)
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
/// a new channel switches in place. `showsDelay` adds the top-bar pills (mode toggle + delay badge) and native HUD controls.
struct TwitchPlayer: View {
    let channel: String
    var showsDelay = true

    @State private var id = UUID()
    @State private var showsNativeControls = false
    @State private var hideControlsTask: Task<Void, Never>?
    private var host: TwitchPlayerHost { .shared }

    private var isHolder: Bool { host.holder == id }
    private var isNative: Bool { host.activeMode == .lowLatency }

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        ZStack {
            TwitchPlayerSlot(holds: isHolder, mode: host.activeMode)
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
                        MediaEdgeVignette(edge: .top, height: 64, intensity: 0.34)
                        Spacer(minLength: 0)
                        if isNative, (showsNativeControls || (!host.isPlaying && !host.isLoading && !host.isOffline)) {
                            MediaEdgeVignette(edge: .bottom, height: 80, intensity: 0.42)
                        }
                    }
                    .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        MediaGlassGroup(spacing: 6) {
                            HStack(spacing: 6) {
                                TwitchModeMenu(host: host)
                                TwitchDelayBadge(host: host)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 60)

                        Spacer(minLength: 0)

                        if isNative, (showsNativeControls || (!host.isPlaying && !host.isLoading && !host.isOffline)) {
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
        .animation(.easeOut(duration: 0.18), value: showsNativeControls)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(channel)'s stream")
        // only the view holding the player shows its sign-in sheet
        .sheet(item: Binding(get: { isHolder ? host.popup : nil },
                             set: { if $0 == nil, isHolder { host.dismissPopup() } })) { popup in
            TwitchPopupSheet(popup: popup) { host.dismissPopup() }
        }
        .onAppear { host.claim(id, channel: channel) }
        .onDisappear {
            hideControlsTask?.cancel()
            hideControlsTask = nil
            host.release(id)
        }
        .onChange(of: channel) { _, new in
            if isHolder { host.play(new) }
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
            if host.isPlaying {
                showsNativeControls = false
            }
        }
    }
}

/// Compact capsule in the top-leading corner of the player: switches between low-latency native playback and Twitch's embed,
/// and exposes native quality + mute controls.
struct TwitchModeMenu: View {
    let host: TwitchPlayerHost

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
                } label: {
                    if host.activeMode == .lowLatency {
                        Label(Copy.Twitch.playerLowLatency, systemImage: "checkmark")
                    } else {
                        Label(Copy.Twitch.playerLowLatency, systemImage: Symbol.Twitch.lowLatency)
                    }
                }
                Button {
                    host.setMode(.embed)
                } label: {
                    if host.activeMode == .embed {
                        Label(Copy.Twitch.playerEmbed, systemImage: "checkmark")
                    } else {
                        Label(Copy.Twitch.playerEmbed, systemImage: Symbol.Twitch.embed)
                    }
                }
            }

            if host.activeMode == .lowLatency, !host.variants.isEmpty {
                Menu {
                    ForEach(host.variants) { variant in
                        Button {
                            host.selectVariant(variant.id)
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

    var body: some View {
        MediaGlassGroup(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    host.setPaused(host.isPlaying)
                    onInteract()
                } label: {
                    Label(host.isPlaying ? Copy.Twitch.pause : Copy.Twitch.play,
                          systemImage: host.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(host.isPlaying ? Copy.Twitch.pause : Copy.Twitch.play)

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

                if !host.variants.isEmpty {
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

    var body: some View {
        if let delay = host.delay {
            Button {
                host.jumpToLive()
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(host.isBehind ? Copy.Twitch.behind(delay) : Copy.Twitch.delay(delay))
            .accessibilityHint(Copy.Twitch.jumpToLive)
            .help(Copy.Twitch.jumpToLive)
            .animation(.easeOut(duration: 0.2), value: host.isBehind)
        }
    }
}

/// Where the shared player view (native display layer or web view) sits while this view holds it. Holding is decided by
/// `TwitchPlayer` (appear and disappear); the slot only moves the active view in and removes the inactive one.
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

    func makeUIView(context: Context) -> TwitchPlayerSlotView {
        let slot = TwitchPlayerSlotView()
        slot.backgroundColor = .black
        slot.clipsToBounds = true
        return slot
    }

    func updateUIView(_ slot: TwitchPlayerSlotView, context: Context) {
        // only a holder asks for the active view, so a slot left on screen never rebuilds one that was let go
        guard holds else { return }
        let target: UIView = mode == .lowLatency
            ? TwitchPlayerHost.shared.nativeView
            : TwitchPlayerHost.shared.webView
        for sub in slot.subviews where sub !== target {
            sub.removeFromSuperview()
        }
        if target.superview !== slot {
            target.removeFromSuperview()
            target.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            slot.addSubview(target)
        }
        if target.frame != slot.bounds {
            target.frame = slot.bounds
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

    func makeNSView(context: Context) -> TwitchPlayerSlotView {
        let slot = TwitchPlayerSlotView()
        slot.wantsLayer = true
        slot.layer?.backgroundColor = NSColor.black.cgColor
        return slot
    }

    func updateNSView(_ slot: TwitchPlayerSlotView, context: Context) {
        // only a holder asks for the active view, so a slot left on screen never rebuilds one that was let go
        guard holds else { return }
        let target: NSView = mode == .lowLatency
            ? TwitchPlayerHost.shared.nativeView
            : TwitchPlayerHost.shared.webView
        for sub in slot.subviews where sub !== target {
            sub.removeFromSuperview()
        }
        if target.superview !== slot {
            target.removeFromSuperview()
            target.autoresizingMask = [.width, .height]
            slot.addSubview(target)
        }
        if target.frame != slot.bounds {
            target.frame = slot.bounds
        }
    }
}
#endif
