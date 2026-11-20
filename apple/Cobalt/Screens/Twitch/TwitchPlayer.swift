import SwiftUI
import WebKit

// The stream (APP-API-CONTRACT 70): Twitch's own embed player in a web view, never the raw video. Twitch only plays an embed
// whose page is on a domain named in `parent`, so the page is loaded as if it came from the web app's domain.

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

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View {
        TwitchPlayerWeb(channel: channel)
            .background(Color.black)
            .mediaMask()
            .accessibilityLabel("\(channel)'s stream")
    }
}

#if os(iOS)
private struct TwitchPlayerWeb: UIViewRepresentable {
    let channel: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TwitchEmbed.configuration())
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.load(channel, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(channel, in: view)
    }

    func makeCoordinator() -> TwitchPlayerLoader { TwitchPlayerLoader() }
}
#else
private struct TwitchPlayerWeb: NSViewRepresentable {
    let channel: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TwitchEmbed.configuration())
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(channel, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(channel, in: view)
    }

    func makeCoordinator() -> TwitchPlayerLoader { TwitchPlayerLoader() }
}
#endif

/// Loads a channel's page once.
@MainActor
final class TwitchPlayerLoader {
    private var loaded: String?

    func load(_ channel: String, in view: WKWebView) {
        guard loaded != channel else { return }
        loaded = channel
        view.loadHTMLString(TwitchEmbed.html(channel: channel), baseURL: TwitchEmbed.base)
    }
}
