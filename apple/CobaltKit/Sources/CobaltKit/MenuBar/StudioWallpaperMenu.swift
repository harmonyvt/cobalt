import Foundation

/// View ▸ "studio wallpaper", as plain values.
///
/// The Mac app scene reads this once, then hands it to `.commands`. The commands builder runs
/// inside `Scene.commands` during the app body's update. Reading the live wallpaper object or the
/// server capabilities from in there dirties the graph before that update finishes. A window being
/// miniaturized or closed (the menu bar extra's window at launch, or a restored minimized window)
/// flushes the graph, the flush builds the commands again, and the stack overflows.
public struct StudioWallpaperMenu: Equatable, Sendable {
    public var isOn: Bool
    /// The server has the studio, so the menu is allowed to turn the wallpaper on.
    public var stageAvailable: Bool

    public init(isOn: Bool, stageAvailable: Bool) {
        self.isOn = isOn
        self.stageAvailable = stageAvailable
    }

    /// Off is always allowed, including when the server has no studio. On is allowed only while it does.
    public var canToggle: Bool { isOn || stageAvailable }

    /// The menu writes the checkmark it was just given while the menus are built. That echo is not
    /// the owner choosing. Only a different value turns the wallpaper on or off.
    public func changes(to on: Bool) -> Bool { on != isOn }
}
