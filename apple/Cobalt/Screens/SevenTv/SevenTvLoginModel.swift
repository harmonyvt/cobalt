import CobaltKit
import Foundation
import Observation
import WebKit

// The login sheet's model (APP-API-CONTRACT 57.12). It owns the web view of 7TV's own login page, watches 7tv.app's
// `localStorage["7tv-token"]` while the page is on 7tv.app, and hands the token to `SevenTvStore.link(token:viaSheet:)` (the
// same `POST /7tv/link` the paste flow uses). The token lives in a local constant for the length of one call: it is never
// stored, logged or shown, and the page's own copy is removed once the link worked.

@MainActor @Observable
final class SevenTvLoginModel {
    enum Phase: Equatable {
        /// The page is up; the model is waiting for the login to leave a token.
        case browsing
        /// A token was found and `POST /7tv/link` is checking it.
        case linking
        /// Linked as this 7TV name; the sheet closes in a moment.
        case linked(String)
        /// The link failed; "try again" goes back to `browsing`.
        case failed(SevenTvError)
    }

    private(set) var phase: Phase
    /// The host of the page showing (the address bar).
    private(set) var host = SevenTvLink.loginURL.host() ?? "7tv.app"
    private(set) var isLoading = true
    /// Opens a page the web view does not keep in the system browser (set by the sheet).
    @ObservationIgnored var openExternally: (URL) -> Void = { _ in }
    /// Closes the sheet (set by the sheet).
    @ObservationIgnored var close: () -> Void = {}

    @ObservationIgnored private let store: SevenTvStore
    @ObservationIgnored private let navigator = SevenTvLoginNavigator()
    /// Previews show a placeholder and never make a web view.
    let isPreview: Bool

    init(store: SevenTvStore, preview: Phase? = nil) {
        self.store = store
        self.phase = preview ?? .browsing
        self.isPreview = preview != nil
        navigator.model = self
    }

    /// The web view: its own persistent data store, 7TV's login page loading. Made once, on first use.
    @ObservationIgnored lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: SevenTvLink.loginDataStoreID)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = navigator
        view.uiDelegate = navigator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: SevenTvLink.loginURL))
        return view
    }()

    // MARK: watching

    /// Polls every second while the page is on 7tv.app; ends with the sheet (the view's `.task`).
    func watch() async {
        guard !isPreview else { return }
        while !Task.isCancelled {
            if phase == .browsing {
                let page = webView
                host = page.url?.host() ?? host
                if SevenTvLink.isSevenTvHost(page.url?.host()), let token = await storedToken(in: page) {
                    guard phase == .browsing else { continue }
                    await link(token)
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// `localStorage.getItem('7tv-token')` of the page, without the JSON quotes; nil while there is none.
    private func storedToken(in page: WKWebView) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            page.evaluateJavaScript("localStorage.getItem('\(SevenTvLink.storageKey)')") { value, _ in
                continuation.resume(returning: SevenTvLink.token(fromStorage: value))
            }
        }
    }

    private func clearStoredToken(in page: WKWebView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            page.evaluateJavaScript("localStorage.removeItem('\(SevenTvLink.storageKey)')") { _, _ in
                continuation.resume()
            }
        }
    }

    private func link(_ token: String) async {
        phase = .linking
        switch await store.link(token: token, viaSheet: true) {
        case .linked(let name):
            phase = .linked(name)
            if !isPreview { await clearStoredToken(in: webView) }     // the 7TV server session stays; only the page's copy goes
            try? await Task.sleep(for: .seconds(1.2))
            close()
        case .failed(let error):
            phase = .failed(error)
        }
    }

    /// "try again". A token 7TV refused or signed out is cleared and the login page loads again; any other failure (offline,
    /// 7TV not answering) keeps the page's token, which the next poll links.
    func retry() {
        guard case .failed(let error) = phase else { return }
        phase = .browsing
        switch error {
        case .tokenInvalid, .relink:
            guard !isPreview else { return }
            let page = webView
            Task {
                await clearStoredToken(in: page)
                page.load(URLRequest(url: SevenTvLink.loginURL))
            }
        default:
            break
        }
    }

    // MARK: the page

    fileprivate func pageStarted() { isLoading = true }

    fileprivate func pageCommitted(host: String?) {
        if let host { self.host = host }
    }

    fileprivate func pageFinished() { isLoading = false }

    /// Main-frame navigations stay in the web view only on the hosts of 7TV and its three sign-ins; everything else (and any
    /// app scheme such as `twitch://`) goes to the system.
    fileprivate func policy(for url: URL?, isMainFrame: Bool) -> WKNavigationActionPolicy {
        guard isMainFrame, let url else { return .allow }
        switch url.scheme?.lowercased() {
        case "http", "https":
            if SevenTvLink.loginAllows(host: url.host()) { return .allow }
        case "about", "blob", "data":
            return .allow
        default:
            break
        }
        openExternally(url)
        return .cancel
    }
}

/// The web view's delegate. Kept apart so the model stays a plain `@Observable`.
@MainActor
private final class SevenTvLoginNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var model: SevenTvLoginModel?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // `targetFrame == nil` is a new window (target=_blank): it counts as the main frame
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        return model?.policy(for: navigationAction.request.url, isMainFrame: main) ?? .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { model?.pageStarted() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { model?.pageCommitted(host: webView.url?.host()) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { model?.pageFinished() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { model?.pageFinished() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        model?.pageFinished()
    }

    /// A link that wants a new window loads here when it is one of ours, else opens in the system browser.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if SevenTvLink.loginAllows(host: url.host()) { webView.load(navigationAction.request) } else { model?.openExternally(url) }
        }
        return nil
    }
}

// MARK: - what the web view keeps

/// The login sheet's website data store (APP-API-CONTRACT 57.12): capystore's own 7TV session, apart from the system browser.
@MainActor
enum SevenTvLoginData {
    /// Drops 7tv.app's records (its `localStorage` and cookies) and keeps the Twitch, Discord and Kick logins, so the next link
    /// is a fresh 7TV session that is one tap away while Twitch remembers the owner.
    static func forgetSevenTv() async {
        let store = WKWebsiteDataStore(forIdentifier: SevenTvLink.loginDataStoreID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records.filter { $0.displayName.lowercased().contains("7tv") })
    }

    /// "forget 7tv login": everything the sheet's web view kept.
    static func forgetAll() async {
        let store = WKWebsiteDataStore(forIdentifier: SevenTvLink.loginDataStoreID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: SevenTvLink.loginDataStoreID)
    }
}
