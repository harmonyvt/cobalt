import AVFoundation
import CobaltKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Shared: an `AVPlayerLayer` for the session's player, filling its frame (the composition is already canvas-shaped, so the
/// layer uses `resizeAspect`). No controls: the transport is the screen's.
#if os(iOS)
struct EditorPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        // the composition is local: start at once instead of waiting for a playability estimate that may never come
        player.automaticallyWaitsToMinimizeStalling = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }     // swiftlint:disable:this force_cast
    }
}
#else
struct EditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        player.automaticallyWaitsToMinimizeStalling = false
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif

/// Shared: the canvas of the editor. Black, as wide as the canvas's aspect allows inside its container, with the session's
/// player in it, the `getting your clips · 40%` line while files download, and `missingClip` / `sourceFailed` over frames
/// whose file is gone. `overlay` draws on top at the canvas's own size (the Mac's overlay handles; the iPhone's drag and pinch).
///
/// Give it all the room there is: it fits itself. `EditorCanvasFit` is the maths, for callers that lay out around it.
struct EditorCanvasView<Overlay: View>: View {
    let session: EditSession
    var cornerRadius: CGFloat = 10
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let fit = EditorCanvasFit.size(canvas: session.timeline.canvas, in: geo.size)
            ZStack {
                EditorPlayerView(player: session.player)
                    .opacity(session.isPlayerReady ? 1 : 0)
                stateLine
                overlay(fit)
            }
            .frame(width: fit.width, height: fit.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CobaltColor.border.opacity(0.35), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Editor.canvasA11y)
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        if let line {
            Text(line)
                .font(CobaltType.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(12)
                .transition(.opacity)
        }
    }

    /// The one line over the canvas: a missing file first, then the download, then a file that would not come.
    private var line: String? {
        if session.hasMissingSources { return Copy.Editor.missingClip }
        if let fraction = session.loadingFraction { return Copy.Editor.loadingSources(Int((fraction * 100).rounded())) }
        if !session.sourceFailures.isEmpty { return Copy.Editor.sourceFailed }
        return nil
    }
}

extension EditorCanvasView where Overlay == EmptyView {
    init(session: EditSession, cornerRadius: CGFloat = 10) {
        self.init(session: session, cornerRadius: cornerRadius, overlay: { _ in EmptyView() })
    }
}

/// The largest rectangle of the canvas's aspect that fits a container.
enum EditorCanvasFit {
    static func size(canvas: EditCanvas, in container: CGSize) -> CGSize {
        size(aspect: CGFloat(canvas.w) / CGFloat(max(1, canvas.h)), in: container)
    }

    static func size(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0, aspect > 0 else { return .zero }
        if container.width / container.height > aspect {
            return CGSize(width: (container.height * aspect).rounded(.down), height: container.height)
        }
        return CGSize(width: container.width, height: (container.width / aspect).rounded(.down))
    }
}
