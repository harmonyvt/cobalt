import Foundation

/// A deep link's or a Shortcut's ask for the screen pane: open `item`. `serial` tells two asks for the same item apart
/// (the second one after the owner closed the first still opens it).
public struct PaneRequest: Equatable, Sendable {
    public let item: PaneItem
    public let serial: Int
}

extension AppModel {
    /// Asks the window's screen pane to open `item` (apple/CONTRACT-PANE.md section 3): deep links and Shortcuts that
    /// open a single item call this instead of pushing or switching to a detail. The app's shell (`AppShell`, which owns
    /// the window's `Pane`) watches `paneRequest`, opens it with `pane.open` and clears it with `takePaneRequest()`.
    public func openInPane(_ item: PaneItem) {
        paneRequest = PaneRequest(item: item, serial: (paneRequest?.serial ?? 0) + 1)
    }

    /// The shell took the request: returns its item (once) and clears it.
    @discardableResult
    public func takePaneRequest() -> PaneItem? {
        guard let request = paneRequest else { return nil }
        paneRequest = nil
        return request.item
    }
}
