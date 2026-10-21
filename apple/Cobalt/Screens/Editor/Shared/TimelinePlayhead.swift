import SwiftUI

/// Shared: the playhead, a 2 pt line with a small head that hangs from the ruler. The caller places it (`.offset(x:)`, its
/// centre line is the view's centre) and owns the gestures: the Mac timeline drags it to seek, the iPhone draws it white and
/// fixed at the centre (`color: .white`, `showsHead: false`).
struct TimelinePlayhead: View {
    /// The line's height, from the top of the ruler down through the lanes.
    let height: CGFloat
    var color: Color = EditorColor.playhead
    var showsHead = true
    static let headWidth: CGFloat = 14
    static let headHeight: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(color)
                .frame(width: 2, height: height)
            if showsHead {
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(color)
                    .frame(width: Self.headWidth, height: Self.headHeight)
            }
        }
        .frame(width: Self.headWidth, height: height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
