import UIKit
import XCTest

/// The screen pane (apple/CONTRACT-PANE.md section 7), on the preview data (`-previewScenario happy`, Debug build only):
/// for the library, links, booru, swarms and twitch, an item opens in the pane, spans, unspans and closes; a running item
/// (a twitch stream, a running swarm) closes to the bar and the bar opens it again; a relaunch restores the pane.
///
/// iPad runs in landscape (the 440 pt column), iPhone is compact (a sheet, the cover when spanned). Every step is a
/// screenshot, attached to the result and written to `apple/.build/pane-shots/<device>/<area>-<step>.png`.
///
/// Identifiers: `pane` (the container), `pane.span`, `pane.close`, `pane.bar` (Cobalt/Pane/PaneChrome.swift), and on the
/// rows `links.row`, `booru.tile`, `swarm.row`, `twitch.search`, `library.tile`. `-paneReset YES` starts without a saved
/// pane (PaneHost, DEBUG), so one test's pane is not the next one's.
@MainActor
final class PaneTests: XCTestCase {
    private let wait: TimeInterval = 25

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var device: String { isPad ? "ipad-landscape" : "iphone" }

    /// `apple/.build/pane-shots`, found from this file's place (apple/CobaltUITests/).
    private static let shotsRoot: URL = {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/pane-shots")
    }()

    override func setUp() async throws {
        continueAfterFailure = false
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() async throws {
        if isPad { XCUIDevice.shared.orientation = .portrait }
    }

    // MARK: the areas

    func testLibrary() throws {
        guard isPad else {
            throw XCTSkip("the library on the one-screen phone layout keeps its push and overlays (LibraryPaneBridge `beside`): no pane to test")
        }
        try run(area: "library", tab: "library", ready: "library.tile", running: false) { app in
            let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
            for index in 0..<min(tiles.count, 16) {
                let tile = tiles.element(boundBy: index)
                if tile.exists, tile.isHittable { tile.tap(); return }
            }
            XCTFail("no library tile to open")
        }
    }

    func testLinks() throws {
        try run(area: "links", tab: "links", ready: "links.row", running: false) { app in
            self.find(app, "links.row").tap()
        }
    }

    func testBooru() throws {
        try run(area: "booru", tab: "booru", ready: "booru.tile", running: false) { app in
            self.find(app, "booru.tile").tap()
        }
    }

    func testSwarms() throws {
        try run(area: "swarms", tab: "swarms", ready: "swarm.row", running: true, extra: ["-previewSwarm", "running"]) { app in
            // the story swarm is the running one
            let rows = app.descendants(matching: .any).matching(identifier: "swarm.row")
            let story = rows.matching(NSPredicate(format: "label CONTAINS[c] 'emotes'")).firstMatch
            (story.exists ? story : rows.firstMatch).tap()
        }
    }

    func testTwitch() throws {
        try run(area: "twitch", tab: "twitch", ready: "twitch.search", running: true) { app in
            let field = self.find(app, "twitch.search")
            field.tap()
            field.typeText("ninja\n")
        }
    }

    // MARK: the fix pass (PR #232 review)

    /// An iPhone on its side is one screen: the pane is the sheet, never split down the middle (item 4).
    func testIPhoneLandscapeIsCompact() throws {
        guard !isPad else { throw XCTSkip("an iPhone layout") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(["-previewScenario", "happy", "-previewTab", "links", "-paneReset", "YES"])
        XCTAssertTrue(find(app, "links.row").waitForExistence(timeout: wait), "the links tab never showed its rows")
        find(app, "links.row").tap()
        let pane = find(app, "pane")
        XCTAssertTrue(pane.waitForExistence(timeout: wait), "the link did not open in the pane")
        settle()
        shot("landscape", "1-open")
        let window = app.windows.firstMatch.frame
        // beside the tab it would be half the window; the sheet is (nearly) all of it
        XCTAssertGreaterThan(pane.frame.width, window.width * 0.7, "landscape iPhone split the pane beside the tab")
        app.terminate()
    }

    /// Escape typed in a text field is the field's, not the pane's (item 8): the pane stays open.
    func testEscapeInASearchFieldKeepsThePane() throws {
        guard isPad else { throw XCTSkip("needs the column, where the tab's search field is beside the pane") }
        let app = launch(["-previewScenario", "happy", "-previewTab", "twitch", "-paneReset", "YES"])
        let field = find(app, "twitch.search")
        XCTAssertTrue(field.waitForExistence(timeout: wait), "the twitch tab never showed its search")
        field.tap()
        field.typeText("ninja\n")
        XCTAssertTrue(find(app, "pane").waitForExistence(timeout: wait), "the stream did not open in the pane")
        settle()
        field.tap()
        field.typeText("abc")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        settle()
        shot("escape", "1-in-field")
        XCTAssertTrue(find(app, "pane").exists, "Escape in a search field closed the pane")
        app.terminate()
    }

    /// A running stream survives another item opening over it (item 5): it goes to the bar, keeps playing there, and the
    /// bar brings it back.
    func testARunningStreamSurvivesBeingReplaced() throws {
        guard isPad else { throw XCTSkip("needs the column: on the phone the pane sheet covers the tabs") }
        let app = launch(["-previewScenario", "happy", "-previewTab", "twitch", "-paneReset", "YES"])
        let field = find(app, "twitch.search")
        XCTAssertTrue(field.waitForExistence(timeout: wait), "the twitch tab never showed its search")
        field.tap()
        field.typeText("ninja\n")
        XCTAssertTrue(find(app, "pane").waitForExistence(timeout: wait), "the stream did not open in the pane")
        settle(3)
        // another tab's item opens over it
        tab(app, "links").tap()
        XCTAssertTrue(find(app, "links.row").waitForExistence(timeout: wait), "the links tab never showed its rows")
        find(app, "links.row").tap()
        let bar = find(app, "pane.bar")
        XCTAssertTrue(bar.waitForExistence(timeout: wait), "the replaced stream did not go to the bar")
        XCTAssertTrue(find(app, "pane").exists, "the link is not in the pane")
        settle()
        shot("replace", "1-link-over-stream")
        bar.tap()
        XCTAssertTrue(waitGone(find(app, "pane.bar")), "the bar stayed after bringing the stream back")
        XCTAssertTrue(find(app, "pane").exists, "the stream did not come back in the pane")
        settle()
        shot("replace", "2-stream-back")
        app.terminate()
    }

    // MARK: the flow

    private func run(
        area: String, tab: String, ready: String, running: Bool, extra: [String] = [],
        open: (XCUIApplication) -> Void
    ) throws {
        let args = ["-previewScenario", "happy", "-previewTab", tab] + extra
        var app = launch(args + ["-paneReset", "YES"])
        XCTAssertTrue(find(app, ready).waitForExistence(timeout: wait), "\(area): the tab never showed its rows")
        shot(area, "0-tab")

        // open
        open(app)
        let pane = find(app, "pane")
        XCTAssertTrue(pane.waitForExistence(timeout: wait), "\(area): the item did not open in the pane")
        settle()
        shot(area, "1-open")
        XCTAssertEqual(find(app, "pane.span").label, "fill the window", "\(area): span button should offer to span")

        // span, unspan
        find(app, "pane.span").tap()
        XCTAssertTrue(waitLabel(find(app, "pane.span"), "back beside the tab"), "\(area): did not span")
        settle()
        shot(area, "2-span")
        find(app, "pane.span").tap()
        XCTAssertTrue(waitLabel(find(app, "pane.span"), "fill the window"), "\(area): did not unspan")
        settle()
        shot(area, "3-unspan")

        // close
        find(app, "pane.close").tap()
        XCTAssertTrue(waitGone(find(app, "pane")), "\(area): the pane did not close")
        if running {
            let bar = find(app, "pane.bar")
            XCTAssertTrue(bar.waitForExistence(timeout: wait), "\(area): a running item did not close to the bar")
            settle()
            shot(area, "4-bar")
            bar.tap()
            XCTAssertTrue(find(app, "pane").waitForExistence(timeout: wait), "\(area): the bar did not reopen the item")
            XCTAssertTrue(waitGone(find(app, "pane.bar")), "\(area): the bar stayed after reopening")
            settle()
            shot(area, "5-reopen")
        } else {
            XCTAssertFalse(find(app, "pane.bar").exists, "\(area): an item that is not running left a bar")
            settle()
            shot(area, "4-closed")
            open(app)
            XCTAssertTrue(find(app, "pane").waitForExistence(timeout: wait), "\(area): the item did not open again")
            settle()
        }

        // relaunch restores the pane: home saves the scene, then the app goes and comes back without the reset
        XCUIDevice.shared.press(.home)
        settle(5)                                           // the scene's saved state is written a moment after it backgrounds
        app.terminate()
        app = launch(args)
        XCTAssertTrue(find(app, "pane").waitForExistence(timeout: wait), "\(area): the pane was not restored after a relaunch")
        settle(2.5)
        shot(area, running ? "6-relaunch" : "5-relaunch")
        app.terminate()
    }

    // MARK: helpers

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += args
        app.launch()
        return app
    }

    /// A tab's button (the iPad's top bar or its sidebar).
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[name]
        return inBar.exists ? inBar : app.buttons[name].firstMatch
    }

    /// The first element with this identifier, whatever its type.
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: wait) == .completed
    }

    private func waitLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [match], timeout: wait) == .completed
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    /// A screenshot of the whole screen, upright: attached to the result, and written to
    /// `.build/pane-shots/<device>/<area>-<step>.png`. (`XCUIScreen` hands the panel's own portrait frame, so a landscape iPad
    /// comes back turned a quarter; it is turned back here.)
    private func shot(_ area: String, _ step: String) {
        let shot = XCUIScreen.main.screenshot()
        var image = shot.image
        // the panel's own pixels, whatever orientation the image claims
        if isPad, let cg = image.cgImage ?? UIImage(data: shot.pngRepresentation)?.cgImage, cg.width < cg.height {
            let size = CGSize(width: cg.height, height: cg.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let upright = UIImage(cgImage: cg, scale: 1, orientation: .up)
            image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let c = context.cgContext
                c.translateBy(x: 0, y: size.height)
                c.rotate(by: -.pi / 2)
                upright.draw(at: .zero)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(device) \(area)-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = Self.shotsRoot.appendingPathComponent(device)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(area)-\(step).png"))
    }
}
