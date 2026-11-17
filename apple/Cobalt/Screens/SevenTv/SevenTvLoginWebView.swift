import SwiftUI
import WebKit

// The login sheet's web view (APP-API-CONTRACT 57.12): the model's own `WKWebView`, shown as it is (the pattern of
// `StageWebPreview`, which this does not share: that one is non-interactive, muted and non-persistent).

#if os(iOS)
struct SevenTvLoginWebView: UIViewRepresentable {
    let model: SevenTvLoginModel

    func makeUIView(context: Context) -> WKWebView { model.webView }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct SevenTvLoginWebView: NSViewRepresentable {
    let model: SevenTvLoginModel

    func makeNSView(context: Context) -> WKWebView { model.webView }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
