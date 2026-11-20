import CobaltKit
import SwiftUI

// Two screens side by side (the Duo redesign, /mnt/project-files/iphone-duo): an unfolded two-screen phone, a landscape
// iPad or a Mac window. Every list-and-detail tab puts the list on the left and what it opened on the right as soon as
// the tab has this much width of its own, instead of pushing, so the list keeps its scroll and picks while you read.
enum Spread {
    /// The width (pt) of the tab's own content from which it splits in two.
    static let minWidth: CGFloat = 700
    /// The left pane of a split: the list.
    static let listWidth: CGFloat = 320
}

/// The line between the two panes, where a two-screen phone has its hinge. While a save or make runs it is the job's
/// progress light: a green bar that fills from the bottom, so no banner covers either pane.
struct HingeSeam: View {
    let queue: JobQueue

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(CobaltColor.hairline).frame(width: 1)
            if !queue.live.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let f = queue.seamFraction(now: context.date) ?? 0
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [CobaltColor.success.opacity(0.25), CobaltColor.success],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 3, height: max(12, geo.size.height * f))
                                .shadow(color: CobaltColor.success.opacity(0.8), radius: 5)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .animation(.easeOut(duration: 0.5), value: f)
                }
                .padding(.vertical, 24)
                .transition(.opacity)
            }
        }
        .frame(width: 5)
        .accessibilityHidden(true)
    }
}
