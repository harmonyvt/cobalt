import UIKit
import XCTest

/// The activity pill and its sheet (apple 03-PHASE3 3.4): the pill is in the top bar of the save, library, links, chat and live stage
/// screens (`activity.pill`), a tap opens the activity and health sheet (`activity.sheet`) with its two segments, and the system
/// segment (`activity.system`) is the health inspector.
///
/// Runs the Debug build over the preview data (`-previewScenario happy`, `CobaltApp.LaunchConfig`). The identifiers are set in
/// `Cobalt/Screens/Activity/` (`activity.pill`, `activity.sheet`, `activity.segments`, `activity.system`, `activity.header`).
@MainActor
final class ActivityPillUITests: XCTestCase {
    private let wait: TimeInterval = 20
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The pill is in the top bar on the save screen and a tap opens the sheet, on the activity segment (the preview is quiet).
    func testPillOpensTheSheet() throws {
        try XCTSkipIf(isPad, "the pill is checked on the iPhone's save screen")
        let app = launch(tab: "save")
        let pill = find(app, "activity.pill")
        XCTAssertTrue(pill.waitForExistence(timeout: wait), "no activity pill in the top bar")
        XCTAssertEqual(pill.label, "activity", "the pill's VoiceOver label")
        pill.tap()
        XCTAssertTrue(find(app, "activity.sheet").waitForExistence(timeout: wait), "the pill did not open the activity sheet")
        XCTAssertTrue(find(app, "activity.header").waitForExistence(timeout: wait), "no header with the count on the activity segment")
    }

    /// The pill is in the library screen's top bar too (checked by existence: the library is busy loading tiles when it appears).
    func testPillIsOnTheLibraryScreen() throws {
        try XCTSkipIf(isPad, "the pill is checked on the iPhone")
        let app = launch(tab: "library")
        XCTAssertTrue(find(app, "activity.pill").waitForExistence(timeout: wait), "no activity pill on the library screen")
    }

    /// The sheet's system segment shows the inspector.
    func testSystemSegmentShowsTheInspector() throws {
        try XCTSkipIf(isPad, "the pill is checked on the iPhone")
        let app = launch(tab: "save")
        let pill = find(app, "activity.pill")
        XCTAssertTrue(pill.waitForExistence(timeout: wait), "no activity pill on the save screen")
        pill.tap()
        XCTAssertTrue(find(app, "activity.sheet").waitForExistence(timeout: wait), "the sheet did not open")
        let system = app.buttons["system"]
        XCTAssertTrue(system.waitForExistence(timeout: wait), "no system segment")
        system.tap()
        XCTAssertTrue(find(app, "activity.system").waitForExistence(timeout: wait), "the health inspector did not show")
        let toggle = find(app, "activity.sync.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: wait),
                      "no library sync switch in the inspector; switches: \(app.switches.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" })")
    }

    /// A pill that says offline (`-previewPill offline`, debug only) opens the sheet on the system segment.
    func testOfflinePillOpensTheSystemSegment() throws {
        try XCTSkipIf(isPad, "the pill is checked on the iPhone")
        let app = launch(tab: "save", extra: ["-previewPill", "offline"])
        let pill = find(app, "activity.pill")
        XCTAssertTrue(pill.waitForExistence(timeout: wait), "no activity pill")
        XCTAssertTrue(pill.value as? String == "offline, 2 changes waiting", "the pill's value: \(String(describing: pill.value))")
        pill.tap()
        XCTAssertTrue(find(app, "activity.system").waitForExistence(timeout: wait), "an offline pill did not open the system segment")
    }

    /// The queue preview has work running and one failed download: the sheet lists it under "needs attention" with retry and dismiss,
    /// and the header counts both (the pill's own count).
    func testAttentionRowOffersRetryAndDismiss() throws {
        try XCTSkipIf(isPad, "the sheet is checked on the iPhone")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-previewQueue", "busy", "-previewTab", "queue", "-paneReset", "YES"]
        app.launch()
        XCTAssertTrue(find(app, "activity.sheet").waitForExistence(timeout: wait), "the queue sheet did not open on the activity sheet")
        let header = find(app, "activity.header")
        XCTAssertTrue(header.waitForExistence(timeout: wait), "no header")
        XCTAssertTrue(header.label.contains("needs attention"), "the header does not count the failed download: \(header.label)")
        let retry = find(app, "activity.retry")
        for _ in 0..<6 where !retry.exists || !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: wait), "the failed download has no retry")
        XCTAssertTrue(find(app, "activity.dismiss").exists, "the failed download has no dismiss")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "activity-sheet-attention"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Offline (`-previewPaneOffline YES`, debug only), a post's detail says in words which actions pause until the server is back
    /// (the note under the grid and "needs network" on the tiles), instead of dimming them alone (apple 03-PHASE3 3.4.3). On the
    /// iPhone the detail is the pushed `MediaDetail` (apple 04-PHASE4 4.2), whose grid is the pane's `PaneActionGrid`.
    func testOfflinePaneExplainsPausedActions() throws {
        try XCTSkipIf(isPad, "the unified detail is the iPhone's (the iPad's pane is covered by PaneTests)")
        let app = launch(tab: "library", extra: ["-previewPaneOffline", "YES"])
        let tiles = app.descendants(matching: .any).matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: wait), "no library tile")
        var opened = false
        for index in 0..<min(tiles.count, 16) {
            let tile = tiles.element(boundBy: index)
            if tile.exists, tile.isHittable { tile.tap(); opened = true; break }
        }
        XCTAssertTrue(opened, "no library tile to open")
        XCTAssertTrue(find(app, "media.detail").waitForExistence(timeout: wait), "the tile did not push the unified detail")
        let note = app.staticTexts["offline. server actions pause until connected"]
        for _ in 0..<6 where !note.exists { app.swipeUp() }
        XCTAssertTrue(note.waitForExistence(timeout: wait), "the grid does not say why its actions are paused")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "pane-grid-offline"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: helpers

    private func launch(tab: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-previewScenario", "happy", "-previewTab", tab, "-paneReset", "YES"] + extra
        app.launch()
        return app
    }

    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
