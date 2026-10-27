import XCTest

final class ReplayJourneyTests: XCTestCase {
    @MainActor func testHomeToolsSettingsAndUnavailableReturnPath() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start demo"].isHittable)
        capture("Home-standard", app)
        tapScrollable("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("Settings-standard", app)
        app.tabBars.buttons["Routes"].tap()
        XCTAssertTrue(app.buttons["Back to Home"].waitForExistence(timeout: 5))
        app.buttons["Back to Home"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
        app.tabBars.buttons["Find"].tap()
        XCTAssertTrue(app.buttons["find.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["find.stop"].isHittable)
        XCTAssertTrue(app.buttons["Help"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["find.stop"].frame.height, 56)
        capture("Find-standard", app)
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor func testReplayControlsAndRestart() {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-welcome"]; app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        app.buttons["Start demo"].tap()
        XCTAssertTrue(app.staticTexts["Demo — simulated data"].exists)
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, running")
        XCTAssertEqual(app.staticTexts["fixture.name"].label, "Fixture, Ordinary obstacle")
        app.buttons["Pause"].tap()
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, paused")
        XCTAssertFalse(app.staticTexts["Simulated obstacle ahead at 2 meters"].exists)
        app.buttons["Resume"].tap()
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, running")
        XCTAssertEqual(app.staticTexts["fixture.name"].label, "Fixture, Limited coverage")
        tapScrollable("Next fixture", in: app)
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, paused")
        app.buttons["Resume"].tap()
        XCTAssertEqual(app.staticTexts["fixture.name"].label, "Fixture, Unavailable input")
        XCTAssertEqual(app.staticTexts["sensing.quality"].label, "Sensing, unavailable")
        tapScrollable("Next fixture", in: app)
        XCTAssertEqual(app.staticTexts["fixture.name"].label, "Fixture, Ordinary obstacle")
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, running")
        app.buttons["End demo"].tap()
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, ended")
        app.terminate()
        app.launchArguments += ["-skip-welcome"]; app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start demo"].isEnabled)
        XCTAssertFalse(app.staticTexts["session.lifecycle"].exists)
    }

    @MainActor func testTabsRetainPauseHelpAndEndWithoutRestartingSession() {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-welcome"]; app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        app.buttons["Start demo"].tap()
        tapScrollable("Sensing details", in: app)
        XCTAssertTrue(app.buttons["Pause"].isHittable)
        XCTAssertTrue(app.buttons["Help"].isHittable)
        XCTAssertTrue(app.buttons["End demo"].isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for tab in ["Routes", "Community"] {
            XCTAssertTrue(app.tabBars.buttons[tab].isHittable)
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts["Unavailable in this build"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Demo — simulated data"].exists)
            XCTAssertTrue(app.buttons["Pause"].isHittable)
            XCTAssertTrue(app.buttons["Help"].isHittable)
            XCTAssertTrue(app.buttons["End demo"].isHittable)
        }
        app.buttons["Help"].tap()
        XCTAssertTrue(app.staticTexts["Guidance is paused."].waitForExistence(timeout: 5))
        app.buttons["Close Help"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        app.buttons["End demo"].tap()
        XCTAssertFalse(app.buttons["Resume"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, ended")
        app.buttons["Start demo"].tap()
        app.tabBars.buttons["Find"].tap()
        XCTAssertTrue(app.buttons["find.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Help"].isHittable)
        XCTAssertFalse(app.staticTexts["Demo — simulated data"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, ended")
    }

    @MainActor func testBackgroundRequiresExplicitResume() {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-welcome"]; app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        app.buttons["Start demo"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["session.lifecycle"].label, "Session, paused")
        XCTAssertFalse(app.staticTexts["Simulated obstacle ahead at 2 meters"].exists)
    }

    @MainActor func testLargestTextKeepsSessionControlsReachable() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        tapScrollable("Start demo", in: app)
        app.tabBars.buttons["Routes"].tap()
        for label in ["Pause", "Help", "End demo"] {
            XCTAssertTrue(app.buttons[label].isHittable, label)
            XCTAssertGreaterThanOrEqual(app.buttons[label].frame.height, 56)
        }
        capture("Session-controls-largest-text", app)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].isHittable)
        app.buttons["End demo"].tap()
    }

    @MainActor private func tapScrollable(_ label: String, in app: XCUIApplication) {
        for _ in 0..<8 {
            let target = app.buttons[label]
            let footer = app.staticTexts["session.demoLabel"]
            if target.isHittable && (!footer.exists || target.frame.maxY < footer.frame.minY - 8) { break }
            app.scrollContentUp()
        }
        XCTAssertTrue(app.buttons[label].isHittable, label)
        app.buttons[label].tap()
    }
}
