import XCTest

final class FindJourneyTests: XCTestCase {
    @MainActor func testTypedClarificationConfirmationUnavailableAndStop() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        app.tabBars.buttons["Find"].tap()
        let input = app.textFields["find.input"].exists ? app.textFields["find.input"] : app.textViews["find.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("find door and pause")
        app.buttons["find.review"].tap()
        XCTAssertTrue(app.staticTexts["find.message"].label.contains("one command"))
        XCTAssertFalse(app.buttons["find.confirm"].exists)
        // A second independent user entry after relaunch must still require confirmation.
        app.terminate(); app.launchArguments += ["-skip-welcome"]; app.launch(); app.tabBars.buttons["Find"].tap()
        let fresh = app.textFields["find.input"].exists ? app.textFields["find.input"] : app.textViews["find.input"]
        fresh.tap(); fresh.typeText("find door"); app.buttons["find.review"].tap()
        reveal("find.confirm", app: app); app.buttons["find.confirm"].tap()
        XCTAssertTrue(app.staticTexts["find.message"].label.contains("detector is not installed"))
        app.buttons["find.stop"].tap()
        XCTAssertTrue(app.staticTexts["find.message"].label.contains("Search stopped"))
    }
    @MainActor func testLargestTextKeepsHelpAndStopReachableWithoutSpeechPermission() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch(); app.tabBars.buttons["Find"].tap()
        XCTAssertTrue(app.buttons["find.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["find.stop"].isHittable)
        XCTAssertTrue(app.buttons["Help"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["find.stop"].frame.height, 56)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Find-largest-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Help"].tap()
        XCTAssertTrue(app.staticTexts["Find paused"].waitForExistence(timeout: 5))
        reveal("Close Help", app: app); app.buttons["Close Help"].tap()
        app.buttons["find.stop"].tap()
    }
    @MainActor private func reveal(_ id: String, app: XCUIApplication) {
        for _ in 0..<10 { if app.buttons[id].isHittable { return }; app.scrollContentUp() }
    }
}
