import UIKit
import XCTest

/// What the owner chose in the library survives layout and lifecycle changes (the lifecycle audit, rule 4): a rotation,
/// a trip to the background, and on the iPad the screen pane opening and closing beside the library.
///
/// Runs the Debug build over the preview data (`-previewScenario happy -previewTab library`, `CobaltApp.LaunchConfig`;
/// both are DEBUG-only, so this target tests the Debug configuration). Driven by `deploy/apple/layout-checks.sh`.
/// The identifiers it looks for are set in `Cobalt/Screens/Library/` (`library.tile`, `library.select`,
/// `library.select.count`, `library.select.stop`, `library.more`, `library.sort`) and `pane` (`Cobalt/Pane/PaneChrome.swift`).
@MainActor
final class LayoutStateUITests: XCTestCase {
    /// Simulators are slow on a cold boot and the preview data animates in: every wait is generous.
    private let wait: TimeInterval = 20

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: the checks

    /// Two picks, then the device turns: still two picks (the panel may move to the pane on a wide phone or iPad).
    func testSelectionSurvivesRotation() throws {
        let app = launch()
        try pickTwo(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        settle()
        XCTAssertEqual(count(app), "2 picked", "the picks were lost turning to landscape")

        XCUIDevice.shared.orientation = .portrait
        settle()
        XCTAssertEqual(count(app), "2 picked", "the picks were lost turning back to portrait")
    }

    /// Two picks, then home and back: still two picks, and the bar's "…" (iPhone) or its menu (iPad) is still there.
    func testSelectionSurvivesBackground() throws {
        let app = launch()
        try pickTwo(app)
        XCTAssertTrue(barMenu(app).waitForExistence(timeout: wait), "no bar menu before going to the background")

        XCUIDevice.shared.press(.home)
        settle()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: wait), "the app did not come back")
        settle()

        XCTAssertEqual(count(app), "2 picked", "the picks were lost in the background")
        XCTAssertTrue(barMenu(app).waitForExistence(timeout: wait), "the bar menu is gone after the background")
    }

    /// iPad: a post in the screen pane, then select mode puts the select actions in the same pane (`stop selecting` closes it).
    /// The bar is whole again and the select button is back. (Was the 8.27 spread-pane check; the inspector and the spread pane
    /// are the screen pane now: apple/CONTRACT-PANE.md. `PaneTests` covers the pane itself.)
    func testSelectPanesBesideLibrary() throws {
        guard isPad else { throw XCTSkip("the pane beside the library is an iPad check (the phone keeps its overlays)") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()

        let tile = firstHittableTile(app)
        XCTAssertNotNil(tile, "no library tile to open")
        tile?.tap()
        XCTAssertTrue(find(app, "pane").waitForExistence(timeout: wait), "the tapped post did not open in the pane")
        settle()

        // select mode: the select panel takes the pane
        let select = find(app, "library.select")
        XCTAssertTrue(select.waitForExistence(timeout: wait), "no select button")
        select.tap()
        let stop = stopButton(app)
        XCTAssertTrue(stop.waitForExistence(timeout: wait), "the select panel did not open")
        settle()

        // closes it again, then waits out `LibraryController.tierChanged` (600 + 300 + 60 ms) with room to spare
        stop.tap()
        XCTAssertTrue(waitGone(stop), "the select panel did not close")
        settle(3)

        XCTAssertTrue(barMenu(app).waitForExistence(timeout: wait), "the bar's menu is gone after the pane closed")
        XCTAssertTrue(find(app, "library.select").waitForExistence(timeout: wait), "the select button did not come back")

        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: helpers

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-previewScenario", "happy", "-previewTab", "library"]
        app.launch()
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "the library never showed tiles")
        return app
    }

    /// Select mode, then tiles in order until two are picked (a gallery cannot be ticked, so some taps do nothing).
    private func pickTwo(_ app: XCUIApplication) throws {
        let select = find(app, "library.select")
        XCTAssertTrue(select.waitForExistence(timeout: wait), "no select button")
        select.tap()
        XCTAssertNotNil(count(app), "no select panel")

        let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
        for index in 0..<min(tiles.count, 16) {
            let tile = tiles.element(boundBy: index)
            guard tile.exists, tile.isHittable else { continue }
            tile.tap()
            if count(app) == "2 picked" { return }
        }
        throw XCTSkip("the preview library has fewer than two posts that can be picked on screen (now: \(count(app) ?? "none"))")
    }

    /// The select panel's count ("2 picked"), wherever the panel is: the pill's label (one screen), or the title of the
    /// screen pane's select page (the pane's container reads "pane, 2 picked").
    private func count(_ app: XCUIApplication) -> String? {
        let label = find(app, "library.select.count")
        if label.waitForExistence(timeout: 3) { return label.label }
        let pane = find(app, "pane")
        guard pane.waitForExistence(timeout: wait) else { return nil }
        return pane.label.replacingOccurrences(of: "pane, ", with: "")
    }

    /// The button that ends select mode: the pill's x, or the select page's "done selecting" in the pane.
    private func stopButton(_ app: XCUIApplication) -> XCUIElement {
        let pill = find(app, "library.select.stop")
        if pill.waitForExistence(timeout: 3) { return pill }
        return find(app, "pane.action.done selecting")
    }

    /// The bar's menu a stale half-width bar drops: the iPhone's "…" (paste and files), the iPad's sort menu. With the screen
    /// pane open beside the library the tab is laid out for the room it keeps, so the iPad shows a narrow bar then.
    private func barMenu(_ app: XCUIApplication) -> XCUIElement {
        // (the narrow tab beside the pane folds the bar into the system's own "More": `OverflowBarButtonItem`)
        let names = isPad ? ["library.sort", "library.more", "OverflowBarButtonItem"] : ["library.more"]
        for name in names {
            let element = find(app, name)
            if element.waitForExistence(timeout: 6) { return element }
        }
        return find(app, names[0])
    }

    private func firstHittableTile(_ app: XCUIApplication) -> XCUIElement? {
        let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
        for index in 0..<min(tiles.count, 16) {
            let tile = tiles.element(boundBy: index)
            if tile.exists, tile.isHittable { return tile }
        }
        return nil
    }

    /// The first element with this identifier, whatever its type (a menu in a toolbar, a tile, a text).
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: wait) == .completed
    }

    /// Lets a rotation, a pane or a return from the background finish animating.
    private func settle(_ seconds: TimeInterval = 1.5) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }
}
