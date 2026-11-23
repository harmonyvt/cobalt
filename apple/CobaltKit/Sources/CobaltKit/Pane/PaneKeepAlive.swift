import Foundation

/// An object a pane page keeps alive across its own rebuilds (`PaneKeepAlive`) that wants to hear when the pane lets go
/// of it: pause a player, close a connection. Called once, on the main actor, after the store has dropped it.
@MainActor
public protocol PaneKeptObject: AnyObject {
    func paneReleased()
}

/// What pane pages keep across their rebuilds (apple/CONTRACT-PANE.md section 4).
///
/// A page is a different view each time the pane changes how it draws it: the sheet and the full-screen cover on one
/// narrow screen are two presentations, the column beside the tab and the sheet are two hosts, and `PanePage` arranges
/// its hero anew for each shape (tall, wide, split, bar). SwiftUI cannot carry one view's identity across those, so a
/// page keeps what must survive (a post's player and its playhead, a chat connection) here instead of in `@State`:
///
///     let player = pane.keepAlive("player", for: item) { PostPlayer(url) }
///
/// The object lives exactly as long as the pane holds its item (`PaneMachine.heldItems`: on screen, in the bar, under a
/// peek, or in the background slot), whatever shape it is drawn in; when the pane lets go of the item the object is
/// dropped and, if it adopts `PaneKeptObject`, told so. `Pane` owns one per window and calls `retain(only:)` after every
/// change.
@MainActor
public final class PaneKeepAlive {
    private struct Key: Hashable {
        let item: PaneItem
        let name: String
    }

    private var objects: [Key: AnyObject] = [:]

    public init() {}

    /// The object kept as `name` for `item`, made by `make` the first time it is asked for. `T` must stay the same for a
    /// name: asked for as another type, the old object is dropped (and told) and a new one made.
    public func object<T: AnyObject>(_ name: String, for item: PaneItem, make: () -> T) -> T {
        let key = Key(item: item, name: name)
        if let found = objects[key] {
            if let kept = found as? T { return kept }
            objects[key] = nil
            (found as? PaneKeptObject)?.paneReleased()
        }
        let made = make()
        objects[key] = made
        return made
    }

    /// Whether an object is kept as `name` for `item`.
    public func contains(_ name: String, for item: PaneItem) -> Bool {
        objects[Key(item: item, name: name)] != nil
    }

    /// How many objects are kept (tests).
    public var count: Int { objects.count }

    /// Drops every object whose item is not in `held`, telling the ones that adopt `PaneKeptObject`.
    public func retain(only held: Set<PaneItem>) {
        let dropped = objects.filter { !held.contains($0.key.item) }
        guard !dropped.isEmpty else { return }
        for key in dropped.keys { objects[key] = nil }
        for object in dropped.values { (object as? PaneKeptObject)?.paneReleased() }
    }

    /// Drops everything (the window went away).
    public func removeAll() {
        retain(only: [])
    }
}
