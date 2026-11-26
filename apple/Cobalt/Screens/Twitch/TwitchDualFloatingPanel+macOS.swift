#if os(macOS)
import AppKit
import CobaltKit
import SwiftUI

// Dual-Stream Floating Picture-in-Picture Panel on macOS (Wave 2).
//
// macOS has no `AVPictureInPictureVideoCallViewController`; instead, an always-on-top borderless
// `NSPanel` (`.nonactivatingPanel`, `.floating`, `.canJoinAllSpaces`) reuses both live
// `TwitchNativeVideoView`s directly with Clear Liquid Glass hover controls:
// - Play / Pause
// - Focus Swap (A <-> B)
// - A · Mix · B audio balance toggle
// - 16:9 Focus+Inset <-> 32:9 True Side-by-Side layout toggle (resizes panel smoothly with locked aspect ratio)
// - Return to main window & Close

/// Aspect-ratio mode for the macOS dual-stream floating panel.
enum TwitchDualPanelAspect: String, Sendable, Equatable {
    /// 16:9 Focus + Inset (default).
    case focus16x9
    /// 32:9 True Side-by-Side (both 16:9 streams full height side by side).
    case sideBySide32x9

    var ratio: NSSize {
        switch self {
        case .focus16x9: NSSize(width: 16, height: 9)
        case .sideBySide32x9: NSSize(width: 32, height: 9)
        }
    }

    var defaultSize: NSSize {
        switch self {
        case .focus16x9: NSSize(width: 608, height: 342)
        case .sideBySide32x9: NSSize(width: 896, height: 252)
        }
    }

    var minSize: NSSize {
        switch self {
        case .focus16x9: NSSize(width: 384, height: 216)
        case .sideBySide32x9: NSSize(width: 576, height: 162)
        }
    }

    var toggled: TwitchDualPanelAspect {
        self == .focus16x9 ? .sideBySide32x9 : .focus16x9
    }
}

/// Manages the macOS always-on-top floating `NSPanel` for dual-stream PiP.
@MainActor
final class TwitchDualFloatingPanel: NSObject, NSWindowDelegate {
    private(set) var isOpen = false
    private(set) var aspect: TwitchDualPanelAspect = .focus16x9

    var onDidOpen: (() -> Void)?
    var onDidClose: ((_ restoredUI: Bool) -> Void)?
    var onRestoreUI: (() -> Void)?

    private var panel: NSPanel?
    private var closingForRestore = false

    func open(host: TwitchPlayerHost) {
        if let existing = panel {
            existing.orderFrontRegardless()
            if !isOpen {
                isOpen = true
                onDidOpen?()
            }
            return
        }

        let initialSize = aspect.defaultSize
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.maxX - initialSize.width - 24,
            y: screenFrame.minY + 24
        )
        let frame = NSRect(origin: origin, size: initialSize)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.aspectRatio = aspect.ratio
        p.minSize = aspect.minSize
        p.delegate = self

        let root = TwitchDualFloatingPanelContent(
            host: host,
            aspect: aspect,
            onToggleAspect: { [weak self] in self?.toggleAspect(host: host) },
            onRestore: { [weak self] in self?.restoreToMainWindow() },
            onClose: { [weak self] in self?.close(restoredUI: false) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 16
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        p.contentView = hosting

        panel = p
        closingForRestore = false
        isOpen = true
        onDidOpen?()
        p.orderFrontRegardless()
    }

    func close(restoredUI: Bool = false) {
        guard let p = panel else { return }
        closingForRestore = restoredUI
        panel = nil
        p.delegate = nil
        p.orderOut(nil)
        p.contentView = nil
        if isOpen {
            isOpen = false
            onDidClose?(restoredUI)
        }
        closingForRestore = false
    }

    func restoreToMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        onRestoreUI?()
        close(restoredUI: true)
    }

    func toggleAspect(host: TwitchPlayerHost) {
        aspect = aspect.toggled
        guard let p = panel else { return }
        p.aspectRatio = aspect.ratio
        p.minSize = aspect.minSize

        // Keep top-right anchor stable while switching between 16:9 Focus+Inset and 32:9 Side-by-Side.
        let current = p.frame
        let nextSize = aspect.defaultSize
        let screenFrame = p.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var nextOrigin = NSPoint(
            x: current.maxX - nextSize.width,
            y: current.maxY - nextSize.height
        )
        nextOrigin.x = max(screenFrame.minX + 12, min(nextOrigin.x, screenFrame.maxX - nextSize.width - 12))
        nextOrigin.y = max(screenFrame.minY + 12, min(nextOrigin.y, screenFrame.maxY - nextSize.height - 12))

        if let hosting = p.contentView as? NSHostingView<TwitchDualFloatingPanelContent> {
            hosting.rootView = TwitchDualFloatingPanelContent(
                host: host,
                aspect: aspect,
                onToggleAspect: { [weak self] in self?.toggleAspect(host: host) },
                onRestore: { [weak self] in self?.restoreToMainWindow() },
                onClose: { [weak self] in self?.close(restoredUI: false) }
            )
        }
        p.setFrame(NSRect(origin: nextOrigin, size: nextSize), display: true, animate: true)
    }

    func windowWillClose(_ notification: Notification) {
        let restored = closingForRestore
        panel = nil
        if isOpen {
            isOpen = false
            onDidClose?(restored)
        }
        closingForRestore = false
    }
}

/// SwiftUI body hosted inside `TwitchDualFloatingPanel`.
private struct TwitchDualFloatingPanelContent: View {
    let host: TwitchPlayerHost
    let aspect: TwitchDualPanelAspect
    let onToggleAspect: () -> Void
    let onRestore: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var focusedSlot: TwitchDualSlot { host.dualMixer.focusedSlot }
    private var louderSlot: TwitchDualSlot? { host.dualMixer.louderSlot }

    var body: some View {
        ZStack {
            Color.black
            videoBody
            if hovering || host.userPaused {
                hoverOverlay
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onHover { isHovering in
            hovering = isHovering
        }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    @ViewBuilder
    private var videoBody: some View {
        switch aspect {
        case .focus16x9:
            GeometryReader { geo in
                let roles = TwitchDualLayout.heroAndInset(focused: focusedSlot)
                let insetSize = TwitchDualLayout.insetSize(for: geo.size, widthFraction: 0.32, minWidth: 120, maxWidth: 210)
                ZStack(alignment: .bottomTrailing) {
                    TwitchDualPanelSurface(slot: roles.hero)
                        .frame(width: geo.size.width, height: geo.size.height)

                    ZStack(alignment: .topLeading) {
                        TwitchDualPanelSurface(slot: roles.inset)
                            .frame(width: insetSize.width, height: insetSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.32), lineWidth: 1.5)
                            }
                        if louderSlot == roles.inset {
                            speakerBadge
                                .padding(6)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        host.swapDualFocus()
                    }
                    .padding(12)
                }
            }
        case .sideBySide32x9:
            HStack(spacing: 2) {
                tile(slot: .primary)
                tile(slot: .secondary)
            }
        }
    }

    @ViewBuilder
    private func tile(slot: TwitchDualSlot) -> some View {
        ZStack(alignment: .topLeading) {
            TwitchDualPanelSurface(slot: slot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if louderSlot == slot {
                speakerBadge
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            host.setDualFocus(slot)
        }
    }

    private var speakerBadge: some View {
        Image(systemName: Symbol.Twitch.unmuted)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .mediaGlassCircle(interactive: false)
    }

    private var hoverOverlay: some View {
        VStack(spacing: 0) {
            // Top bar: return to window + close
            HStack(spacing: 8) {
                Button(action: onRestore) {
                    Label(Copy.Twitch.closeFloatingWindow, systemImage: Symbol.Twitch.pipExit)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: Metrics.hit, height: Metrics.hit)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .mediaGlassCircle()
                .help(Copy.Twitch.closeFloatingWindow)

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Label(Copy.Twitch.close, systemImage: Symbol.Twitch.close)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: Metrics.hit, height: Metrics.hit)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .mediaGlassCircle()
                .help(Copy.Twitch.close)
            }
            .padding(10)
            .background(alignment: .top) {
                MediaEdgeVignette(edge: .top, height: 64, intensity: 0.48)
            }

            Spacer(minLength: 0)

            // Bottom transport + audio + 16:9 / 32:9 toggle
            MediaGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        host.setPaused(!host.userPaused)
                    } label: {
                        Image(systemName: host.userPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: Metrics.hit, height: Metrics.hit)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .mediaGlassCircle()
                    .help(host.userPaused ? Copy.Twitch.play : Copy.Twitch.pause)

                    Button {
                        host.swapDualFocus()
                    } label: {
                        Image(systemName: Symbol.Twitch.swapFocus)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: Metrics.hit, height: Metrics.hit)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .mediaGlassCircle()
                    .help(Copy.Twitch.swapFocus)

                    // Compact A · Mix · B segmented audio toggle (>= 44 pt tall)
                    HStack(spacing: 2) {
                        audioButton(.primary, title: "A")
                        audioButton(.mix, title: Copy.Twitch.audioMix)
                        audioButton(.secondary, title: "B")
                    }
                    .padding(.horizontal, 4)
                    .frame(height: Metrics.hit)
                    .mediaGlassCapsule(interactive: false)

                    Button(action: onToggleAspect) {
                        Image(systemName: aspect == .focus16x9 ? Symbol.Twitch.splitLayoutHorizontal : Symbol.Twitch.focusLayout)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: Metrics.hit, height: Metrics.hit)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .mediaGlassCircle()
                    .help(aspect == .focus16x9 ? Copy.Twitch.dualSideBySide32x9 : Copy.Twitch.dualFocus16x9)
                }
            }
            .padding(10)
            .background(alignment: .bottom) {
                MediaEdgeVignette(edge: .bottom, height: 76, intensity: 0.52)
            }
        }
    }

    private func audioButton(_ preset: TwitchDualAudioPreset, title: String) -> some View {
        let active = host.dualMixer.activePreset == preset
        return Button {
            host.dualMixer.selectPreset(preset)
        } label: {
            Text(title)
                .font(Font.cobalt(11, active ? .semibold : .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.68))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(active ? Color.white.opacity(0.22) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Adopts one of the two live `TwitchNativeVideoView`s directly inside the floating `NSPanel`.
private struct TwitchDualPanelSurface: NSViewRepresentable {
    let slot: TwitchDualSlot

    func makeNSView(context: Context) -> PanelSlotContainerView {
        let v = PanelSlotContainerView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ container: PanelSlotContainerView, context: Context) {
        let target = TwitchPlayerHost.shared.nativeView(for: slot)
        for sub in container.subviews where sub !== target {
            sub.removeFromSuperview()
        }
        if target.superview !== container {
            target.removeFromSuperview()
            target.autoresizingMask = [.width, .height]
            container.addSubview(target)
        }
        if target.frame != container.bounds {
            target.frame = container.bounds
        }
    }
}

private final class PanelSlotContainerView: NSView {
    override func layout() {
        super.layout()
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}
#endif
