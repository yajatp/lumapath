import XCTest

final class CaptureAvailabilityTests: XCTestCase {
    @MainActor func testSimulatorExplainsUnavailableCaptureAndKeepsDemoAvailable() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The unsupported-capture assertion is specific to Simulator.")
        #else
        let app = XCUIApplication()
        app.launchArguments += ["-skip-welcome"]; app.launch()
        app.openDeveloperSettings()
        for _ in 0..<6 {
            if app.buttons["capture.diagnostics"].isHittable { break }
            app.scrollContentUp()
        }
        app.buttons["capture.diagnostics"].tap()
        XCTAssertTrue(app.staticTexts["capture.unsupported"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start capture"].isEnabled)
        XCTAssertFalse(app.buttons["Stop capture"].isEnabled)
        // No camera prompt or synthetic live-depth fallback is opened on unsupported hardware.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<6 {
            if app.buttons["Start demo"].isHittable { break }
            app.scrollContentDown()
        }
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 5))
        app.buttons["Start demo"].tap()
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, running")
        #endif
    }
}
