#if os(macOS)
import AppKit
import CobaltKit
import SwiftUI

/// The menu bar icon: two chevrons, a ring while jobs run, a red dot when one has failed.
struct MenuBarLabel: View {
    let model: AppModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let phases = MenuBarPhases.live(model.queue)
        let failed = max(model.queue.summary.failed, model.unifiedQueue.summary.failed)
        let state = MenuBarIcon.state(phases: phases, failed: failed > 0)
        Image(nsImage: MenuBarGlyphImage.make(state, dark: scheme == .dark))
            .renderingMode(.original)
            .accessibilityLabel(Copy.MenuBar.iconLabel(live: model.queue.summary.live, failed: failed))
            .onAppear { arm() }
    }

    private func arm() {
        MenuBarHandoff.shared.reveal = { MacWindows.reveal(openWindow) }
    }
}

/// Live jobs, as the ring wants them. Waiting (a place in line) is not progress. A download fills the
/// first 80%; saving, reading and rendering fill the rest.
@MainActor
enum MenuBarPhases {
    static func live(_ queue: JobQueue) -> [MenuBarIcon.Phase] {
        queue.live.map(phase(of:))
    }

    static func phase(of job: Job) -> MenuBarIcon.Phase {
        if job.isWaiting { return .waiting }
        switch job.pipeline.state {
        case .uploading(let progress):
            guard let total = progress.total, total > 0 else { return .checking }
            return .downloading(Double(progress.bytes) / Double(total))
        case .fetching:
            if let fraction = job.pipeline.progressStory?.fraction { return .downloading(fraction) }
            return .checking
        case .saving(let bytes, let total, _):
            guard let bytes, let total, total > 0 else { return .checking }
            return .saving(Double(bytes) / Double(total))
        case .reading(let done, let total):
            return .saving(total > 0 ? Double(done) / Double(total) : 0)
        case .rendering(.decoding(let done, let total)):
            return .saving(total > 0 ? Double(done) / Double(total) : 0)
        case .rendering:
            return .saving(0)
        case .gallery:
            if let progress = job.pipeline.galleryProgress, progress.total > 0 {
                return .saving(Double(progress.done) / Double(progress.total))
            }
            return .checking
        default:
            return .checking
        }
    }
}

@MainActor
enum MenuBarGlyphImage {
    static func make(_ state: MenuBarIconState, dark: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let rect = CGRect(origin: .zero, size: image.size)
        let scale = rect.width / 22
        let ink: NSColor = dark ? .white : .black
        let path = NSBezierPath()
        path.lineWidth = 1.7 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // the mock's y grows downward; this image's y grows up
        func chevron(_ x: CGFloat, _ top: CGFloat, _ mid: CGFloat, _ bottom: CGFloat) {
            path.move(to: point(x, top, scale))
            path.line(to: point(x + 4, mid, scale))
            path.line(to: point(x, bottom, scale))
        }
        if state.ring != nil {
            chevron(6.6, 7.2, 11, 14.8)
            chevron(10.8, 7.2, 11, 14.8)
        } else {
            chevron(5.2, 6.2, 11, 15.8)
            chevron(10.6, 6.2, 11, 15.8)
        }
        ink.setStroke()
        path.stroke()

        if let ring = state.ring {
            let radius = 8.5 * scale
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(
                ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            track.lineWidth = 1.6 * scale
            ink.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.lineWidth = 1.6 * scale
            arc.lineCapStyle = .round
            let sweep = CGFloat(min(1, max(0, ring))) * 360
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            ink.setStroke()
            arc.stroke()
        }

        if state.failed {
            let diameter = 5 * scale
            let dot = NSBezierPath(ovalIn: CGRect(
                x: rect.maxX - diameter - scale, y: rect.maxY - diameter - scale,
                width: diameter, height: diameter))
            NSColor.systemRed.setFill()
            dot.fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func point(_ x: CGFloat, _ yDown: CGFloat, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: (22 - yDown) * scale)
    }
}
#endif
