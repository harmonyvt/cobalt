import SwiftUI
import WebKit

// The stream (APP-API-CONTRACT 70, 70.4): Twitch's own interactive embed player (`Twitch.Player`, embed/v1.js) in a web view,
// never the raw video. Twitch only plays an embed whose page is on a domain named in `parent`, so the page is loaded as if it
// came from the web app's domain.
//
// One player for the whole app (`TwitchPlayerHost.shared`): a `TwitchPlayer` view adopts its web view, so moving the stream
// between layouts or to the TV window reparents it without a reload. The page reports Twitch's own "latency to broadcaster"
// every second; the host keeps the best it has seen and jumps back to live when the stream drifts behind it.
// The embed's "Log in" opens twitch.tv's sign-in in a popup (window.open): the popup opens in a sheet over the player, in a
// web view made from the configuration WebKit hands over, so it shares the player's cookies. When the sign-in closes it
// (or the owner does), the player reloads signed in, and subscriptions apply.

enum TwitchEmbed {
    static let parent = "cobalt.capybaraharmony.com"
    static let base = URL(string: "https://\(parent)/")!
    static let handler = "twitch"

    static func safe(_ channel: String) -> String {
        channel.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func html(channel: String) -> String {
        let c = safe(channel)
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
          window.cobaltRebuild = build;
          window.cobaltSetChannel = function (c) { ch = c; if (player) { player.setChannel(c); } else { build(); } };
          if (window.Twitch && Twitch.Player) { build(); } else { post({ e: "noembed" }); }
        })();
        </script>
        </body></html>
        """
    }

    static func configuration(handler proxy: WKScriptMessageHandler) -> WKWebViewConfiguration {
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

/// The app's one Twitch player. Views adopt its web view with `TwitchPlayer(channel:)`; the latest view to appear holds it,
/// and when that view goes the one before it takes it back (the TV window can borrow the stream from the phone this way).
/// With no view left the stream stops.
@MainActor @Observable
final class TwitchPlayerHost {
    static let shared = TwitchPlayerHost()

    /// How far behind its best the stream may drift before it counts as behind (seconds).
    static let behindBy: Double = 2.5
    /// Seconds in a row the stream must be behind before an automatic jump to live.
    static let autoAfter = 8
    /// Least time between two automatic jumps (seconds).
    static let autoCooldown: TimeInterval = 45

    /// The channel playing now, nil while stopped.
    private(set) var channel: String?
    /// Twitch's latency to the broadcaster in seconds, nil until the stream plays.
    private(set) var delay: Double?
    /// The lowest delay seen on this channel: what this stream can do.
    private(set) var bestDelay: Double?
    private(set) var isPlaying = false
    private(set) var isOffline = false
    /// True from a jump to live until the delay settles.
    private(set) var isCatchingUp = false
    /// The view holding the web view now.
    private(set) var holder: UUID?
    /// Jump to live by itself when the stream drifts behind (on by default).
    var autoCatchUp = true
    /// The popup the embed opened (Twitch's sign-in), shown in a sheet by the holding view.
    private(set) var popup: TwitchPopup?

    /// Seconds behind live more than this stream's best, nil until known.
    var behind: Double? {
        guard let delay, let bestDelay else { return nil }
        return max(0, delay - bestDelay)
    }
    var isBehind: Bool { (behind ?? 0) >= Self.behindBy }

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let proxy: TwitchMessageProxy
    @ObservationIgnored private var claims: [UUID] = []
    @ObservationIgnored private var behindRun = 0
    @ObservationIgnored private var lastJump: Date = .distantPast
    @ObservationIgnored private var jumpCheck: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pageLoaded = false

    private init() {
        let proxy = TwitchMessageProxy()
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
        webView = view
        self.proxy = proxy
        proxy.host = self
    }

    // MARK: holders

    /// A view wants the stream. The newest claim holds the web view.
    func claim(_ id: UUID, channel: String) {
        stopTask?.cancel()
        stopTask = nil
        claims.removeAll { $0 == id }
        claims.append(id)
        holder = id
        play(channel)
    }

    /// A view went. The claim before it takes the web view back; with none left the stream stops shortly after (a layout
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

    // MARK: playback

    func play(_ channel: String) {
        let c = TwitchEmbed.safe(channel)
        guard !c.isEmpty, c != self.channel else { return }
        self.channel = c
        reset()
        if pageLoaded {
            webView.evaluateJavaScript("window.cobaltSetChannel && window.cobaltSetChannel(\"\(c)\")")
        } else {
            pageLoaded = true
            webView.loadHTMLString(TwitchEmbed.html(channel: c), baseURL: TwitchEmbed.base)
        }
    }

    func stop() {
        channel = nil
        pageLoaded = false
        reset()
        webView.loadHTMLString("<html><body style=\"background:#000\"></body></html>", baseURL: nil)
    }

    /// Back to the live edge: pause and play, and if the stream is still behind a few seconds later, reload the player.
    func jumpToLive() {
        guard channel != nil else { return }
        lastJump = .now
        behindRun = 0
        isCatchingUp = true
        webView.evaluateJavaScript("window.cobaltJumpToLive && window.cobaltJumpToLive()")
        jumpCheck?.cancel()
        jumpCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            if self.isBehind {
                self.webView.evaluateJavaScript("window.cobaltRebuild && window.cobaltRebuild()", completionHandler: nil)
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                // still behind after a reload: this is as close as the stream gets now, so it becomes the new best
                if self.isBehind, let delay = self.delay { self.bestDelay = delay }
            }
            self.isCatchingUp = false
        }
    }

    /// Loads the channel's page again (after a sign-in, so the embed picks it up).
    func reload() {
        guard let channel else { return }
        reset()
        webView.loadHTMLString(TwitchEmbed.html(channel: channel), baseURL: TwitchEmbed.base)
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
        isOffline = false
        isCatchingUp = false
        behindRun = 0
        jumpCheck?.cancel()
        jumpCheck = nil
    }

    // MARK: the page

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let e = m["e"] as? String else { return }
        switch e {
        case "playing": isPlaying = true; isOffline = false
        case "paused": isPlaying = false
        case "offline": isOffline = true; isPlaying = false; delay = nil
        case "online": isOffline = false
        case "stats":
            let paused = (m["paused"] as? Bool) ?? false
            guard let d = (m["delay"] as? NSNumber)?.doubleValue, d > 0, !paused else { return }
            delay = d
            bestDelay = min(bestDelay ?? d, d)
            if isCatchingUp, !isBehind { isCatchingUp = false; jumpCheck?.cancel() }
            behindRun = isBehind ? behindRun + 1 : 0
            if autoCatchUp, !isCatchingUp, behindRun >= Self.autoAfter,
               Date.now.timeIntervalSince(lastJump) >= Self.autoCooldown {
                jumpToLive()
            }
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
/// a new channel switches in place. `showsDelay` adds the delay badge (tap: jump to live).
struct TwitchPlayer: View {
    let channel: String
    var showsDelay = true

    @State private var id = UUID()
    private var host: TwitchPlayerHost { .shared }

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        ZStack(alignment: .topTrailing) {
            TwitchPlayerSlot(holds: host.holder == id)
                .background(Color.black)
                .mediaMask()
                .overlay {
                    if host.holder != nil, host.holder != id {
                        Text(Copy.Twitch.playingElsewhere)
                            .font(Font.cobalt(13, .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            if showsDelay, host.holder == id {
                TwitchDelayBadge(host: host).padding(8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(channel)'s stream")
        // only the view holding the player shows its sign-in sheet
        .sheet(item: Binding(get: { host.holder == id ? host.popup : nil },
                             set: { if $0 == nil, host.holder == id { host.dismissPopup() } })) { popup in
            TwitchPopupSheet(popup: popup) { host.dismissPopup() }
        }
        .onAppear { host.claim(id, channel: channel) }
        .onDisappear { host.release(id) }
        .onChange(of: channel) { _, new in
            if host.holder == id { host.play(new) }
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(host.isBehind ? Copy.Twitch.behind(delay) : Copy.Twitch.delay(delay))
            .accessibilityHint(Copy.Twitch.jumpToLive)
            .help(Copy.Twitch.jumpToLive)
            .animation(.easeOut(duration: 0.2), value: host.isBehind)
        }
    }
}

/// Where the shared web view sits while this view holds it. Holding is decided by `TwitchPlayer` (appear and disappear);
/// the slot only moves the web view in.
#if os(iOS)
private struct TwitchPlayerSlot: UIViewRepresentable {
    let holds: Bool

    func makeUIView(context: Context) -> UIView {
        let slot = UIView()
        slot.backgroundColor = .black
        slot.clipsToBounds = true
        return slot
    }

    func updateUIView(_ slot: UIView, context: Context) {
        let web = TwitchPlayerHost.shared.webView
        guard holds, web.superview !== slot else { return }
        web.removeFromSuperview()
        web.frame = slot.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        slot.addSubview(web)
    }
}
#else
private struct TwitchPlayerSlot: NSViewRepresentable {
    let holds: Bool

    func makeNSView(context: Context) -> NSView {
        let slot = NSView()
        slot.wantsLayer = true
        slot.layer?.backgroundColor = NSColor.black.cgColor
        return slot
    }

    func updateNSView(_ slot: NSView, context: Context) {
        let web = TwitchPlayerHost.shared.webView
        guard holds, web.superview !== slot else { return }
        web.removeFromSuperview()
        web.frame = slot.bounds
        web.autoresizingMask = [.width, .height]
        slot.addSubview(web)
    }
}
#endif
