import CobaltKit
import SwiftUI

/// Shared: the ruler of the timeline, `m:ss` labels with minor ticks, chosen for the zoom (`TimelineScale.labelStep`).
///
/// It is `scale.x(duration)` wide and `height` tall, laid out as lazy cells (one per label), so a ten-minute edit zoomed all
/// the way in never builds more than the screen shows. Taps and drags are the caller's: the Mac timeline puts a
/// `DragGesture` over it to seek, the iPhone scrolls under a fixed playhead instead.
struct TimelineRuler: View {
    let scale: TimelineScale
    /// Seconds the ruler runs to (the edit's length, plus whatever room the caller leaves at the end).
    let duration: Double
    var height: CGFloat = 28

    var body: some View {
        let step = scale.labelStep
        let count = max(1, Int((duration / step).rounded(.up)) + 1)
        LazyHStack(alignment: .top, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                RulerCell(seconds: Double(index) * step, step: step, minors: scale.minorCount, width: scale.x(step), height: height)
            }
        }
        .frame(width: scale.x(duration), height: height, alignment: .topLeading)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct RulerCell: View {
    let seconds: Double
    let step: Double
    let minors: Int
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let tick = Path { path in
                    path.move(to: CGPoint(x: 0.5, y: size.height - 12))
                    path.addLine(to: CGPoint(x: 0.5, y: size.height))
                    for i in 1..<max(1, minors) {
                        let x = size.width * CGFloat(i) / CGFloat(minors)
                        path.move(to: CGPoint(x: x, y: size.height - 5))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                context.stroke(tick, with: .color(CobaltColor.caption.opacity(0.7)), lineWidth: 1)
            }
            Text(label)
                .font(Font.cobalt(10, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 5)
                .padding(.top, 5)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var label: String {
        step < 1 ? Copy.Editor.clockTenths(seconds) : Copy.Editor.clock(seconds)
    }
}
