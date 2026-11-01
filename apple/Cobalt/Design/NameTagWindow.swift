#if os(macOS)
import AppKit
import SwiftUI

// The Mac shows an icon button's name tag in a small window of its own, just above the button. Drawn inside the app's
// window, the tag sat under whatever came after it (other glass buttons, list rows, scroll views, the toolbar), so the
// icons covered the words. A window of its own is above all of that and is never clipped.

/// Finds the AppKit view under a SwiftUI view, so the tag knows where the button is on screen.
final class NameTagAnchor {
    fileprivate weak var view: NSView?

    /// The button's frame in screen coordinates, and its window.
    @MainActor var placement: (rect: NSRect, window: NSWindow)? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return (window.convertToScreen(inWindow), window)
    }
}

struct NameTagAnchorView: NSViewRepresentable {
    let anchor: NameTagAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The one name tag window. Only one tag shows at a time; the button that showed it is the only one that can hide it.
@MainActor
final class NameTagWindow {
    static let shared = NameTagWindow()

    /// Room around the tag for its shadow.
    private let shadowRoom: CGFloat = 14
    /// Gap between the button and the tag.
    private let gap: CGFloat = 6

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var owner: UUID?

    func show(_ tag: AnyView, for anchor: NameTagAnchor, owner: UUID) {
        guard let (rect, window) = anchor.placement else { return }
        let panel = makePanelIfNeeded()
        let content = AnyView(tag.padding(shadowRoom))
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = [.intrinsicContentSize]
            panel.contentView = host
            self.host = host
        }
        panel.appearance = window.effectiveAppearance
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? .zero
        guard size.width > 0, size.height > 0 else { return }

        // Above the button, centred; below it when there is no room above; kept on the screen.
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap - shadowRoom)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame
        if let screen {
            if origin.y + size.height - shadowRoom > screen.maxY {
                origin.y = rect.minY - gap - size.height + shadowRoom
            }
            origin.x = min(max(origin.x, screen.minX - shadowRoom), screen.maxX - size.width + shadowRoom)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        self.owner = owner
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide(owner: UUID) {
        guard self.owner == owner, let panel else { return }
        self.owner = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.owner == nil else { return }
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }
}
#endif
