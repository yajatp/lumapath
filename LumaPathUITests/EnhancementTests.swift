import XCTest

final class EnhancementTests: XCTestCase {
    @MainActor func testStaticPreviewOriginalToggleAndResetWithoutCameraPermission() {
        let app = XCUIApplication()
        // Isolate this coordinate-based control journey from preceding largest-text launches.
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        reveal("Enhancement preview", in: app)
        app.buttons["Enhancement preview"].tap()
        XCTAssertTrue(app.staticTexts["Static synthetic fixture — not a current observation"].waitForExistence(timeout: 5))
        let toggle = app.switches["render.enhanced"]
        for _ in 0..<5 { if toggle.isHittable { break }; app.scrollContentUp() }
        // Tap the switch control, rather than the center of its full-width labeled row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let original = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Original — all enhancement bypassed"),
                                                object: app.staticTexts["render.mode"])
        XCTAssertEqual(XCTWaiter.wait(for: [original], timeout: 5), .completed)
        reveal("Reset enhancement", in: app); app.buttons["Reset enhancement"].tap()
        for _ in 0..<5 { if app.staticTexts["render.mode"].isHittable { break }; app.scrollContentDown() }
        XCTAssertEqual(app.staticTexts["render.mode"].label, "Enhanced")
    }
    @MainActor func testSimulatorLiveViewIsUnavailableAndCannotStart() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Simulator capability check")
        #else
        let app = XCUIApplication(); app.launchArguments += ["-skip-welcome"]; app.launch()
        reveal("Start live view", in: app); app.buttons["Start live view"].tap()
        XCTAssertTrue(app.staticTexts["live.unsupported"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start live view"].isEnabled)
        XCTAssertTrue(app.staticTexts["No current camera image"].exists)
        #endif
    }
    @MainActor private func reveal(_ title: String, in app: XCUIApplication) {
        for _ in 0..<8 { if app.buttons[title].isHittable { return }; app.scrollContentUp() }
    }
}
