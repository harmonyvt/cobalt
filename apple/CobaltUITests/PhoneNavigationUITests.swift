import UIKit
import XCTest

/// The iPhone's four tabs and header (apple 04-PHASE4 4.1, 4.5), on the preview data (`-previewScenario`, Debug build only).
///
/// - `testPhoneNavigation4TabsAndSettingsGear`: capture, library, live (stage | twitch | 7tv) and tools are the only tabs ("more" is
///   gone); each root screen has the activity pill and the settings gear, once each; the gear opens settings in a sheet where a
///   group page pushes and `done` closes it; the tools list pushes its rows; the live picker switches screens.
/// - `testPhoneActivityPillAndHealthInspector`: on a cold start the pill opens the sheet, and its system segment is the health
///   inspector (containers, library sync).
///
/// Identifiers: `phone.settings` (the gear), `phone.settings.done`, `settings.group.<name>` (Cobalt/Screens/Settings),
/// `live.segments`, `tools.row.<name>`, `tools.assistants.segments` (Cobalt/Screens/Live, Cobalt/Screens/Tools),
/// `activity.pill`, `activity.sheet`, `activity.system`, `activity.sync.toggle` (Cobalt/Screens/Activity).
@MainActor
final class PhoneNavigationUITests: XCTestCase {
    private let wait: TimeInterval = 30
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func testPhoneNavigation4TabsAndSettingsGear() throws {
        try XCTSkipIf(isPad, "the four tabs are the iPhone's (the iPad keeps its sidebar)")
        let app = launch(tab: "save")
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: wait), "no tab bar")
        for name in ["capture", "library", "live", "tools"] {
            XCTAssertTrue(bar.buttons[name].exists, "no \(name) tab")
        }
        XCTAssertFalse(bar.buttons["more"].exists, "the more tab is back")
        XCTAssertEqual(bar.buttons.count, 4, "the tab bar has \(bar.buttons.count) buttons: \(bar.buttons.allElementsBoundByIndex.map(\.label))")

        // capture: the pill and the gear (once each), then the gear's sheet; a group pushes inside it and done closes it
        assertHeader(app, "capture")
        openSettings(app)
        let group = find(app, "settings.group.account")
        XCTAssertTrue(group.waitForExistence(timeout: wait), "the settings hub shows no groups")
        group.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: wait), "the group page did not push inside the sheet")
        // the page replaces the hub inside the sheet (so the hub's rows and its `done` are behind it); back returns to the hub
        XCTAssertFalse(find(app, "settings.group.downloads").exists, "the hub is still showing under the pushed group page")
        XCTAssertTrue(app.navigationBars.count > 0 && !find(app, "phone.settings").isHittable, "the group page is not in the sheet over the tab")
        app.navigationBars.buttons.firstMatch.tap()        // back to the hub
        XCTAssertTrue(find(app, "settings.group.downloads").waitForExistence(timeout: wait), "back from a group did not return to the hub")
        closeSettings(app)

        // library: native bar (the ⋯ menu, the pill, the gear), the gear's sheet from here too
        bar.buttons["library"].tap()
        XCTAssertTrue(find(app, "library.tile").waitForExistence(timeout: wait), "the library never showed tiles")
        assertHeader(app, "library")
        XCTAssertTrue(find(app, "library.more").exists, "no ⋯ menu in the library's bar")
        openSettings(app)
        closeSettings(app)

        // live: stage | twitch | 7tv, one at a time under the same bar
        bar.buttons["live"].tap()
        let segments = find(app, "live.segments")
        XCTAssertTrue(segments.waitForExistence(timeout: wait), "no live picker")
        assertHeader(app, "live (stage)")
        for name in ["twitch", "7tv", "stage"] {
            let button = segments.buttons[name]
            XCTAssertTrue(button.exists, "no \(name) segment; have \(segments.buttons.allElementsBoundByIndex.map(\.label))")
            button.tap()
            settle(1.5)
            assertHeader(app, "live (\(name))")
        }
        openSettings(app)
        closeSettings(app)

        // tools: a list whose rows push, with the gear from the list
        bar.buttons["tools"].tap()
        XCTAssertTrue(find(app, "tools.row.links").waitForExistence(timeout: wait), "the tools list has no links row")
        assertHeader(app, "tools")
        openSettings(app)
        closeSettings(app)
        find(app, "tools.row.assistants").tap()
        XCTAssertTrue(find(app, "tools.assistants.segments").waitForExistence(timeout: wait), "no chat | swarms picker")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(find(app, "tools.row.links").waitForExistence(timeout: wait), "back from chat did not return to the tools list")

        // back on capture (`model.selectedTab` follows the screen really showing; `-debugHooks 1` logs `phone.active=`)
        bar.buttons["capture"].tap()
        assertHeader(app, "capture (again)")
        app.terminate()
    }

    func testPhoneActivityPillAndHealthInspector() throws {
        try XCTSkipIf(isPad, "the pill is checked on the iPhone")
        let app = launch(tab: "save", scenario: "coldStart")
        let pill = find(app, "activity.pill")
        XCTAssertTrue(pill.waitForExistence(timeout: wait), "no activity pill on the capture screen")
        pill.tap()
        XCTAssertTrue(find(app, "activity.sheet").waitForExistence(timeout: wait), "the pill did not open the activity sheet")
        let system = app.buttons["system"]
        XCTAssertTrue(system.waitForExistence(timeout: wait), "no system segment")
        system.tap()
        XCTAssertTrue(find(app, "activity.system").waitForExistence(timeout: wait), "the health inspector did not show")
        // the containers card (what woke, what is warm) and the library sync card (its switch) are both in it
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'containers'")).firstMatch.waitForExistence(timeout: wait),
            "the inspector has no containers card; texts: \(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))")
        XCTAssertTrue(find(app, "activity.sync.toggle").waitForExistence(timeout: wait), "the inspector has no library sync switch")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "health-inspector-cold-start"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    // MARK: helpers

    /// One pill and one gear in the bar, and the gear last (rightmost).
    private func assertHeader(_ app: XCUIApplication, _ where_: String) {
        let gear = app.buttons.matching(identifier: "phone.settings")
        let pill = app.buttons.matching(identifier: "activity.pill")
        XCTAssertTrue(gear.firstMatch.waitForExistence(timeout: wait), "\(where_): no settings gear")
        XCTAssertTrue(pill.firstMatch.waitForExistence(timeout: wait), "\(where_): no activity pill")
        XCTAssertEqual(gear.count, 1, "\(where_): \(gear.count) gears")
        XCTAssertEqual(pill.count, 1, "\(where_): \(pill.count) pills")
        XCTAssertGreaterThan(gear.firstMatch.frame.minX, pill.firstMatch.frame.minX, "\(where_): the gear is not after the pill")
    }

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons.matching(identifier: "phone.settings").firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: wait), "no gear to tap")
        gear.tap()
        XCTAssertTrue(find(app, "phone.settings.done").waitForExistence(timeout: wait), "the gear did not open settings")
    }

    private func closeSettings(_ app: XCUIApplication) {
        let done = find(app, "phone.settings.done")
        done.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: wait), .completed, "done did not close settings")
    }

    private func launch(tab: String, scenario: String = "happy") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-previewScenario", scenario, "-previewTab", tab, "-paneReset", "YES"]
        app.launch()
        return app
    }

    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }
}
