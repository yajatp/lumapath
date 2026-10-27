import XCTest

final class SpatialPlacesJourneyTests: XCTestCase {
    @MainActor func testSimulatorExplainsSpatialLimitsAndPreservesManualNotesAtLargestText() {
        let app = XCUIApplication()
        app.launchArguments += ["-spatial-places-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        tap("Saved places", in: app)
        tap("places.spatial", in: app)
        for _ in 0..<10 where !app.staticTexts["spatial.unsupported"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["spatial.unsupported"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["spatial.scan"].isEnabled)
        XCTAssertFalse(app.buttons["Stop scan"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["places.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["places.add"].isEnabled)
    }
    @MainActor private func tap(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name]
        for _ in 0..<10 where !button.exists || !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.tap()
    }
}
