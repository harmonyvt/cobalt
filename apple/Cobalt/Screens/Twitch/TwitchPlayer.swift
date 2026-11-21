import SwiftUI
import WebKit

// The stream (APP-API-CONTRACT 70): Twitch's own embed player in a web view, never the raw video. Twitch only plays an embed
// whose page is on a domain named in `parent`, so the page is loaded as if it came from the web app's domain.
// The embed's "Log in" opens twitch.tv's sign-in in a popup (window.open): the popup opens in a sheet over the player, in a
// web view made from the configuration WebKit hands over, so it shares the player's cookies. When the sign-in closes it
// (or the owner does), the player reloads signed in, and subscriptions apply.

enum TwitchEmbed {
    static let parent = "cobalt.capybaraharmony.com"
    static let base = URL(string: "https://\(parent)/")!

    static func html(channel: String) -> String {
        let c = channel.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        iframe{border:0;position:absolute;inset:0;width:100%;height:100%}</style></head><body>
        <iframe src="https://player.twitch.tv/?channel=\(c)&parent=\(parent)&autoplay=true&muted=false"
          allow="autoplay; fullscreen; picture-in-picture; encrypted-media" allowfullscreen></iframe>
        </body></html>
        """
    }

    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        config.websiteDataStore = .default()
        return config
    }
}

/// The player for one channel. A new channel loads a new page; the same channel keeps playing through layout changes.
struct TwitchPlayer: View {
    let channel: String

    @State private var popups = TwitchPopups()

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        TwitchPlayerWeb(channel: channel, popups: popups, closings: popups.closings)
            .background(Color.black)
            .mediaMask()
            .accessibilityLabel("\(channel)'s stream")
            .sheet(item: Binding(get: { popups.open }, set: { if $0 == nil { popups.dismiss() } })) { popup in
                TwitchPopupSheet(popup: popup) { popups.dismiss() }
            }
    }
}

/// The popup the embed opened (Twitch's sign-in), shown in a sheet.
struct TwitchPopup: Identifiable {
    let id = UUID()
    let view: WKWebView
}

/// The player's popups: the open one, and a reload of the player once it closes (the sign-in finished or was cancelled).
@MainActor @Observable
final class TwitchPopups {
    private(set) var open: TwitchPopup?
    /// Bumped when a popup closes: the player reloads its page.
    private(set) var closings = 0

    func show(_ view: WKWebView) {
        open = TwitchPopup(view: view)
    }

    func dismiss() {
        guard open != nil else { return }
        open = nil
        closings &+= 1
    }
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

#if os(iOS)
private struct TwitchPlayerWeb: UIViewRepresentable {
    let channel: String
    let popups: TwitchPopups
    /// Read here, in the player's body, so a closed popup updates the web view.
    let closings: Int

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TwitchEmbed.configuration())
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.uiDelegate = context.coordinator
        context.coordinator.load(channel, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(channel, in: view)
        context.coordinator.reloadIfPopupClosed(closings, in: view)
    }

    func makeCoordinator() -> TwitchPlayerLoader { TwitchPlayerLoader(popups: popups) }
}
#else
private struct TwitchPlayerWeb: NSViewRepresentable {
    let channel: String
    let popups: TwitchPopups
    /// Read here, in the player's body, so a closed popup updates the web view.
    let closings: Int

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TwitchEmbed.configuration())
        view.setValue(false, forKey: "drawsBackground")
        view.uiDelegate = context.coordinator
        context.coordinator.load(channel, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(channel, in: view)
        context.coordinator.reloadIfPopupClosed(closings, in: view)
    }

    func makeCoordinator() -> TwitchPlayerLoader { TwitchPlayerLoader(popups: popups) }
}
#endif

/// Loads a channel's page once, opens the embed's popups in a sheet, and reloads the page when one closes.
@MainActor
final class TwitchPlayerLoader: NSObject, WKUIDelegate {
    private let popups: TwitchPopups
    private var loaded: String?
    private var closingsSeen = 0

    init(popups: TwitchPopups) {
        self.popups = popups
    }

    func load(_ channel: String, in view: WKWebView) {
        guard loaded != channel else { return }
        loaded = channel
        view.loadHTMLString(TwitchEmbed.html(channel: channel), baseURL: TwitchEmbed.base)
    }

    /// A popup closed since the last look: load the page again so the embed picks up the new sign-in.
    func reloadIfPopupClosed(_ closings: Int, in view: WKWebView) {
        guard closings != closingsSeen else { return }
        closingsSeen = closings
        guard let channel = loaded else { return }
        view.loadHTMLString(TwitchEmbed.html(channel: channel), baseURL: TwitchEmbed.base)
    }

    // window.open from the embed (its "Log in"): a web view from WebKit's configuration, so cookies are shared and
    // the popup keeps its opener.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popups.show(popup)
        return popup
    }

    // window.close from the sign-in page once it is done.
    func webViewDidClose(_ webView: WKWebView) {
        if popups.open?.view === webView { popups.dismiss() }
    }
}
