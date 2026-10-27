import XCTest

final class AccessoryJourneyTests: XCTestCase {
    @MainActor func testLargestTextSetupAndStopRemainReachableWithoutAccessories() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        reveal("Settings", app); app.buttons["Settings"].tap()
        reveal("Mount and accessory setup", app); app.buttons["Mount and accessory setup"].tap()
        XCTAssertTrue(app.buttons["accessory.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["accessory.stop"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["accessory.stop"].frame.height, 56)
        app.buttons["accessory.stop"].tap()
        for _ in 0..<15 {
            if app.staticTexts["accessory.status"].isHittable { break }; app.swipeUp()
        }
        XCTAssertEqual(app.staticTexts["accessory.status"].label, "Preview stopped.")
        XCTAssertTrue(app.buttons["accessory.stop"].isHittable)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["accessory.stop"].waitForExistence(timeout: 5))
    }
    @MainActor private func reveal(_ label: String, _ app: XCUIApplication) {
        for _ in 0..<15 { if app.buttons[label].isHittable { return }; app.swipeUp() }
    }
}
