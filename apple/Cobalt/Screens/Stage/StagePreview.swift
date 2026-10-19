import CobaltKit
import SwiftUI
import WebKit

// The preview (APP-API-CONTRACT 29.11): a non-interactive web view of `live_url?preview=1` (always muted, no store hint),
// 16:9, with "preview · what obs sees" under it. Off air the canvas is empty and see-through, so the card says so instead of
// loading it. The page is the server's; the app only shows it.

struct StagePreviewCard: View {
    let stage: StageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            screen
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Stage.previewA11y)
            HStack {
                Text(Copy.Stage.previewCaption)
                Spacer(minLength: 8)
                Text(Copy.Stage.previewSize)
            }
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .accessibilityHidden(true)
        }
    }

    private var screen: some View {
        ZStack {
            Rectangle().fill(CobaltColor.frameBase)
            if stage.onAir {
                StageWebPreview(url: stage.previewURL)
                    .allowsHitTesting(false)
            } else {
                offAir
            }
        }
    }

    private var offAir: some View {
        VStack(spacing: 6) {
            Image(systemName: Symbol.stageOffAir)
                .font(.system(size: 24))
            Text(Copy.Stage.previewOffTitle)
                .font(CobaltType.bodySemibold)
            Text(Copy.Stage.previewOffBody)
                .font(CobaltType.captionSmall)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(CobaltColor.badgeInk)
        .padding(.horizontal, 20)
    }
}

// MARK: - the web view

/// Loads the preview page once per address (a rotated link loads the new one) and keeps the page see-through.
@MainActor
final class StageWebCoordinator: NSObject {
    private var loaded: URL?

    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        return view
    }

    func load(_ url: URL, in view: WKWebView) {
        guard loaded != url else { return }
        loaded = url
        view.load(URLRequest(url: url))
    }
}

#if os(iOS)
struct StageWebPreview: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> StageWebCoordinator { StageWebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = StageWebCoordinator.makeWebView()
        context.coordinator.load(url, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(url, in: view)
    }
}
#else
struct StageWebPreview: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> StageWebCoordinator { StageWebCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = StageWebCoordinator.makeWebView()
        context.coordinator.load(url, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(url, in: view)
    }
}
#endif
