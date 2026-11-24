import UIKit
import XCTest

/// The screen pane (apple/CONTRACT-PANE.md section 7), on the preview data (`-previewScenario happy`, Debug build only):
/// for the library, links, booru, swarms and twitch, an item opens in the pane, spans, unspans and closes; a running item
/// (a twitch stream, a running swarm) closes to the bar and the bar opens it again; a relaunch restores the pane.
///
/// iPad runs in landscape (the 440 pt column and `pane.span`), iPhone is compact (a sheet, and no span: apple 04-PHASE4 4.2, so
/// `pane.span` must be ABSENT there). On the iPhone a library tile is not a pane at all: a tap (or a hold and lift) pushes the one
/// `MediaDetail` (`media.detail`) on the tab's stack. Every step is a screenshot, attached to the result and written to
/// `apple/.build/pane-shots/<device>/<area>-<step>.png`.
///
/// The iPhone's hold and select (owner, 2026-11-23; screenshots `hold-*` and `pill-*`): a hold on a library tile previews
/// it and lifting the finger pushes the detail, sliding off first cancels, and in select mode the pill expands (a tap on its
/// count) into the selection sheet at `.medium`, where the grid behind stays tappable and the count follows it, and a swipe
/// down collapses it to the pill with the ticks kept.
///
/// Identifiers: `pane` (the container), `pane.span` (iPad and Mac only), `pane.close`, `pane.bar` (Cobalt/Pane/PaneChrome.swift),
/// `media.detail` (the pushed detail, Cobalt/Screens/Home/MediaDetail.swift), and on the
/// rows `links.row`, `booru.tile`, `swarm.row`, `twitch.search`, `library.tile`, `library.select`,
/// `library.select.count`. `-paneReset YES` starts without a saved
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
        // the iPad's column: a tap opens the post in the pane; the iPhone pushes the one detail instead (04-PHASE4 4.2)
        if !isPad { return try phoneLibraryPushesTheDetail() }
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
            // `-previewSwarm` opens the story swarm in the pane at launch (SwarmsLaunch); on the phone its sheet covers the
            // list, and a tap at the row's place would land on the sheet's stop button
            if self.find(app, "pane").waitForExistence(timeout: 3) { return }
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


    // MARK: hold and select (iPhone)

    /// A hold previews the post, lifting the finger pushes its detail with the action grid (no context menu, no tap).
    func testIPhoneHoldReleaseOpensThePane() throws {
        guard !isPad else { throw XCTSkip("an iPhone gesture: the iPad keeps its context menu") }
        let app = launch(["-previewScenario", "happy", "-previewTab", "library", "-paneReset", "YES"])
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "the library never showed tiles")
        settle()
        let tile = try XCTUnwrap(firstHittableTile(app), "no library tile to hold")
        shot("hold", "0-grid")
        pressWithShot(tile, hold: 2.4, shotAt: 1.4, area: "hold", step: "1-preview")
        XCTAssertTrue(find(app, "media.detail").waitForExistence(timeout: wait), "lifting the finger did not push the post's detail")
        XCTAssertFalse(find(app, "pane").exists, "the iPhone opened a pane sheet over the detail")
        settle()
        shot("hold", "2-open")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'share'")).firstMatch.waitForExistence(timeout: 5),
            "the detail has no share button in its grid")
        // the detail is pushed: back returns to the grid
        backFromDetail(app)
        XCTAssertTrue(waitGone(find(app, "media.detail")), "the detail did not pop")
        settle()
        shot("hold", "3-closed")
        app.terminate()
    }

    /// Holding and sliding off the tile before lifting cancels: the preview goes and nothing opens.
    func testIPhoneHoldThenDragOffCancels() throws {
        guard !isPad else { throw XCTSkip("an iPhone gesture") }
        let app = launch(["-previewScenario", "happy", "-previewTab", "library", "-paneReset", "YES"])
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "the library never showed tiles")
        settle()
        let tile = try XCTUnwrap(firstHittableTile(app), "no library tile to hold")
        let window = app.windows.firstMatch
        // down past the tab bar's edge: well off the tile
        let away = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0, thenDragTo: away)
        settle(2)
        XCTAssertFalse(find(app, "pane").exists || find(app, "media.detail").exists, "a hold dragged off the tile still opened the post")
        shot("hold", "4-dragged-off")
        app.terminate()
    }

    /// In select mode a hold previews and lifting pushes the post's detail; going back returns to the grid with the same
    /// ticks and the pill.
    func testIPhoneHoldInSelectModeKeepsThePicks() throws {
        guard !isPad else { throw XCTSkip("an iPhone gesture") }
        let app = launch(["-previewScenario", "happy", "-previewTab", "library", "-paneReset", "YES"])
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "the library never showed tiles")
        settle()
        find(app, "library.select").tap()
        XCTAssertTrue(find(app, "library.select.count").waitForExistence(timeout: wait), "no select pill")
        let ticked = try tick(app, upTo: 2)
        XCTAssertEqual(ticked, "2 picked")
        let tile = try XCTUnwrap(firstHittableTile(app), "no library tile to hold")
        pressWithShot(tile, hold: 2.4, shotAt: 1.4, area: "hold", step: "5-select-preview")
        XCTAssertTrue(find(app, "media.detail").waitForExistence(timeout: wait), "lifting the finger did not open the post")
        settle()
        shot("hold", "6-select-open")
        backFromDetail(app)
        XCTAssertTrue(waitGone(find(app, "media.detail")), "the detail did not pop")
        let count = find(app, "library.select.count")
        XCTAssertTrue(count.waitForExistence(timeout: wait), "the pill did not come back")
        XCTAssertEqual(count.label, "2 picked", "closing the post changed the picks")
        settle()
        shot("hold", "7-select-back")
        app.terminate()
    }

    /// The pill expands (a tap on its count) into the selection sheet at medium; a tile behind it still ticks and the sheet
    /// follows; a swipe down collapses it to the pill and the picks stay.
    func testIPhoneSelectPillExpandsAndCollapses() throws {
        guard !isPad else { throw XCTSkip("an iPhone layout: the iPad has the pane beside the tab") }
        let app = launch(["-previewScenario", "happy", "-previewTab", "library", "-paneReset", "YES"])
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "the library never showed tiles")
        settle()
        find(app, "library.select").tap()
        XCTAssertTrue(find(app, "library.select.count").waitForExistence(timeout: wait), "no select pill")
        let ticked = try tick(app, upTo: 2)
        XCTAssertEqual(ticked, "2 picked")
        settle()
        shot("pill", "1-collapsed")

        // expand: tap the count
        find(app, "library.select.count").tap()
        let pane = find(app, "pane")
        XCTAssertTrue(pane.waitForExistence(timeout: wait), "tapping the count did not open the selection sheet")
        settle(2)
        shot("pill", "2-expanded")
        let window = app.windows.firstMatch.frame
        let top = pane.frame.minY
        XCTAssertGreaterThan(top, window.height * 0.3, "the sheet opened taller than medium (top \(top) of \(window.height))")
        XCTAssertLessThan(top, window.height * 0.7, "the sheet is not up (top \(top) of \(window.height))")
        XCTAssertTrue(app.staticTexts["2 posts"].waitForExistence(timeout: 5), "the sheet does not say `2 posts`")
        XCTAssertFalse(find(app, "library.select.count").exists, "the pill stayed under the expanded sheet")

        // a tile behind the sheet still ticks, and the sheet's count follows
        let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
        var followed = false
        for index in 0..<min(tiles.count, 24) {
            let tile = tiles.element(boundBy: index)
            guard tile.exists, tile.isHittable, tile.frame.maxY < top - 4, tile.frame.minY > 100, !tile.isSelected else { continue }
            tile.tap()
            // (a gallery cannot be ticked: the next tile then)
            if app.staticTexts["3 posts"].waitForExistence(timeout: 3) { followed = true; break }
        }
        XCTAssertTrue(followed, "the sheet's count did not follow a tick behind it")
        settle()
        shot("pill", "3-ticked-behind")

        // swipe down from the grabber: the pill comes back, nothing is un-picked, select mode stays
        let grabber = pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let bottom = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        grabber.press(forDuration: 0.1, thenDragTo: bottom)
        XCTAssertTrue(waitGone(find(app, "pane")), "swiping down did not collapse the sheet")
        let count = find(app, "library.select.count")
        XCTAssertTrue(count.waitForExistence(timeout: wait), "the pill did not come back")
        XCTAssertEqual(count.label, "3 picked", "collapsing changed the picks")
        settle()
        shot("pill", "4-collapsed-again")
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
        if isPad {
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
        } else {
            // the iPhone's pane is one sheet: no span (a cover stacked over a sheet), so no button and no ⌘⇧F
            XCTAssertFalse(find(app, "pane.span").exists, "\(area): the iPhone offers span")
            shot(area, "2-no-span")
        }

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

    // MARK: the iPhone's one detail

    /// A library tile on the iPhone pushes the unified `MediaDetail` (no pane, no span), and the back button returns to the grid.
    private func phoneLibraryPushesTheDetail() throws {
        let app = launch(["-previewScenario", "happy", "-previewTab", "library", "-paneReset", "YES"])
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "library: the tab never showed its rows")
        settle()
        shot("library", "0-tab")
        let tile = try XCTUnwrap(firstHittableTile(app), "library: no tile to open")
        tile.tap()
        XCTAssertTrue(find(app, "media.detail").waitForExistence(timeout: wait), "library: a tap did not push the detail")
        XCTAssertFalse(find(app, "pane").exists, "library: the iPhone opened a pane sheet")
        XCTAssertFalse(find(app, "pane.span").exists, "library: the iPhone offers span")
        settle()
        shot("library", "1-detail")
        backFromDetail(app)
        XCTAssertTrue(waitGone(find(app, "media.detail")), "library: back did not return to the grid")
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "library: the grid is gone after back")
        settle()
        shot("library", "2-back")
        app.terminate()
    }

    /// The pushed detail's back button (the navigation bar's leading one).
    private func backFromDetail(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: wait), "the detail has no back button")
        back.tap()
    }

    // MARK: helpers

    /// The first library tile on screen that can be touched.
    private func firstHittableTile(_ app: XCUIApplication) -> XCUIElement? {
        let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
        for index in 0..<min(tiles.count, 16) {
            let tile = tiles.element(boundBy: index)
            if tile.exists, tile.isHittable, tile.frame.minY > 120 { return tile }
        }
        return nil
    }

    /// Select mode is on: taps tiles in order until `count` are picked (a gallery cannot be ticked); returns the pill's text.
    private func tick(_ app: XCUIApplication, upTo count: Int) throws -> String {
        let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
        let label = find(app, "library.select.count")
        for index in 0..<min(tiles.count, 16) {
            let tile = tiles.element(boundBy: index)
            guard tile.exists, tile.isHittable, tile.frame.minY > 120 else { continue }
            tile.tap()
            if label.label == "\(count) picked" { return label.label }
        }
        throw XCTSkip("the preview library has fewer than \(count) posts that can be picked on screen (now: \(label.label))")
    }

    /// Presses the tile for `hold` seconds and takes a screenshot `shotAt` seconds into the hold (from another thread: the
    /// press blocks this one), written like `shot`.
    private func pressWithShot(_ tile: XCUIElement, hold: TimeInterval, shotAt: TimeInterval, area: String, step: String) {
        let box = ShotBox()
        DispatchQueue.global().asyncAfter(deadline: .now() + shotAt) { box.take() }
        tile.press(forDuration: hold)
        box.wait()
        if let image = box.image { save(image, area: area, step: step) }
    }

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
        save(image, area: area, step: step)
    }

    private func save(_ image: UIImage, area: String, step: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(device) \(area)-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = Self.shotsRoot.appendingPathComponent(device)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(area)-\(step).png"))
    }
}

/// A screenshot taken off the test's thread while a press holds it (`XCUIScreen` hands a copy; nothing else is touched).
private final class ShotBox: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private(set) var image: UIImage?

    func take() {
        image = XCUIScreen.main.screenshot().image
        done.signal()
    }

    func wait() { _ = done.wait(timeout: .now() + 10) }
}
