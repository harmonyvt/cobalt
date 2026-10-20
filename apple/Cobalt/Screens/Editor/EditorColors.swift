import SwiftUI

/// The editor's own colours (apple/CONTRACT-EDITOR.md 4.3). Everything else comes from `CobaltColor`; `Tokens.swift` is not
/// touched. The selection blue is `CobaltColor.linkBlue` (#2f8af9 in dark).
enum EditorColor {
    /// The overlay lane's amber, #f5a524.
    static let overlay = Color(hex: 0xf5a524)
    /// The selected clip's ring, its trim handles and the playhead.
    static let selection = CobaltColor.linkBlue
    /// The playhead on the timeline (the board's blue in both appearances).
    static let playhead = Color(hex: 0x2f8af9)
    /// The bars of the Mac editor (top bar, panels, timeline).
    static let bar = CobaltColor.sidebar
    static let panel = CobaltColor.surface
    static let lane = CobaltColor.railTrack
    static let line = CobaltColor.hairline
    /// A field's fill inside a panel.
    static let field = CobaltColor.bg
    /// The "too long" bar at the end of the main track.
    static let over = CobaltColor.error
    /// A clip's ink: always white, the blocks are always dark.
    static let clipInk = Color.white

    /// The board's block colours: a clip with no poster is one of these, the same one for the same file.
    private static let palette: [Color] = [
        Color(hex: 0x3b5b73), Color(hex: 0x6d4f3a), Color(hex: 0x3f6b4f), Color(hex: 0x6b3f4a), Color(hex: 0x5a3f6b), Color(hex: 0x47566b),
    ]

    /// A stable colour for a library file id (`String.hashValue` changes every launch, so the sum is done by hand).
    static func clip(for item: String) -> Color {
        var sum = 5381
        for byte in item.utf8 { sum = (sum &* 33) &+ Int(byte) }
        return palette[abs(sum % palette.count)]
    }
}
