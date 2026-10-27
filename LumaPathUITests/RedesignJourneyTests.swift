import XCTest

final class RedesignJourneyTests: XCTestCase {
    @MainActor func testInterfaceSelectionIsReachableWithoutVolumeOrPermissionsAtLargestText() {
        let app = XCUIApplication()
        app.launchArguments = ["-presentation-testing", "-reset-presentation", "-skip-welcome", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        reveal("Settings", app); app.buttons["Settings"].tap()
        reveal("interface.change", app)
        XCTAssertEqual(app.buttons["interface.change"].label, "Use Developer interface")
        app.buttons["interface.change"].tap()
        XCTAssertTrue(app.staticTexts["interface.developer"].waitForExistence(timeout: 5))
        reveal("Settings", app); app.buttons["Settings"].tap()
        reveal("interface.change", app)
        XCTAssertEqual(app.buttons["interface.change"].label, "Use Standard interface")
        app.buttons["interface.change"].tap()
        XCTAssertTrue(app.buttons["Start live view"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["interface.developer"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }

    @MainActor func testDeveloperSelectionRevealsRecordingButDoesNotEnableResearch() {
        let app = XCUIApplication()
        app.launchArguments = ["-presentation-testing", "-reset-presentation", "-skip-welcome", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        reveal("Settings", app); app.buttons["Settings"].tap()
        reveal("interface.change", app); app.buttons["interface.change"].tap()
        XCTAssertTrue(app.buttons["Start live view"].waitForExistence(timeout: 5))
        app.buttons["Start live view"].tap()
        reveal("Collect research data", app)
        XCTAssertTrue(app.buttons["Collect research data"].isHittable)
        reveal("Research feedback — unvalidated", app); app.buttons["Research feedback — unvalidated"].tap()
        XCTAssertEqual(app.switches["Enable Research overlays and feedback"].value as? String, "0")
        XCTAssertEqual(app.alerts.count, 0)
        app.terminate(); app.launch()
        reveal("Settings", app); app.buttons["Settings"].tap()
        reveal("interface.change", app)
        XCTAssertEqual(app.buttons["interface.change"].label, "Use Developer interface")
    }
    @MainActor func testWelcomeChoicesStayOptionalAndNeverRequestPermissions() {
        let app = XCUIApplication()
        app.launchArguments = ["-presentation-testing", "-reset-presentation", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your view. Your way."].waitForExistence(timeout: 10))
        capture("Welcome-light", app)
        reveal("presentation.voice", app); app.buttons["presentation.voice"].tap()
        app.buttons["Continue"].tap()
        reveal("appearance.dark", app); app.buttons["appearance.dark"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Ready when you are"].waitForExistence(timeout: 5))
        app.buttons["Use these choices"].tap()
        XCTAssertTrue(app.buttons["Start live view"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        reveal("presentation.shortcut", app)
        XCTAssertEqual(app.buttons["presentation.shortcut"].label, "Style: Voice")
        app.terminate(); app.launchArguments.removeAll { $0 == "-reset-presentation" }; app.launch()
        XCTAssertTrue(app.buttons["Start live view"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Skip setup"].exists)
        capture("Home-dark", app)
    }

    @MainActor func testPreviewCancelAndApplyPreservePausedDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["-presentation-testing", "-reset-presentation", "-skip-welcome", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["Start demo"].waitForExistence(timeout: 10))
        capture("Home-light", app)
        app.buttons["Start demo"].tap(); app.buttons["Pause"].tap()
        reveal("presentation.shortcut", app); app.buttons["presentation.shortcut"].tap()
        reveal("presentation.voice", app); app.buttons["presentation.voice"].tap()
        XCTAssertTrue(app.buttons["presentation.voice"].isSelected)
        capture("Style-preview", app)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.buttons["presentation.shortcut"].label, "Style: Combined")
        XCTAssertTrue(app.buttons["Resume"].isHittable)
        app.buttons["presentation.shortcut"].tap()
        reveal("presentation.voice", app); app.buttons["presentation.voice"].tap()
        app.buttons["presentation.apply"].tap()
        XCTAssertEqual(app.buttons["presentation.shortcut"].label, "Style: Voice")
        XCTAssertTrue(app.buttons["Resume"].isHittable)
        XCTAssertFalse(app.buttons["Pause"].exists)
        app.buttons["End demo"].tap()
        reveal("Settings", app); app.buttons["Settings"].tap()
        capture("Settings-light", app)
        app.tabBars.buttons["Find"].tap()
        capture("Find-voice", app)
        XCTAssertTrue(app.buttons["Help"].isHittable)
        XCTAssertTrue(app.buttons["find.stop"].isHittable)
    }

    @MainActor func testLiveUnavailableAndLargestTextRemainUsable() {
        let app = XCUIApplication()
        app.launchArguments = ["-presentation-testing", "-reset-presentation", "-skip-welcome", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        app.buttons["Start live view"].tap()
        XCTAssertTrue(app.buttons["live.assistant"].waitForExistence(timeout: 5))
        capture("Live-light", app)
        XCTAssertTrue(app.staticTexts["live.unsupported"].exists)
        reveal("presentation.shortcut", app); app.buttons["presentation.shortcut"].tap()
        reveal("presentation.voice", app); app.buttons["presentation.voice"].tap()
        app.buttons["presentation.apply"].tap()
        XCTAssertFalse(app.buttons["Start live view"].isEnabled)
        capture("Live-voice", app)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        capture("Home-largest-text", app)
        app.tabBars.buttons["Find"].tap()
        XCTAssertTrue(app.buttons["find.stop"].isHittable)
        XCTAssertTrue(app.buttons["Help"].isHittable)
        capture("Find-largest-text", app)
    }

    @MainActor private func reveal(_ id: String, _ app: XCUIApplication) {
        for _ in 0..<12 {
            let button = app.buttons[id]
            // XCTest can report scroll content beneath the fixed Live footer as hittable.
            // Keep the entire style shortcut above that footer before tapping it.
            let beneathLiveFooter = id == "presentation.shortcut"
                && app.buttons["End live view"].exists
                && button.frame.maxY >= app.buttons["Help"].frame.minY
            if button.isHittable && !beneathLiveFooter { return }
            app.scrollContentUp()
        }
        XCTAssertTrue(app.buttons[id].isHittable, id)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        // The accessibility snapshot can lead the rendered display by a frame after a tap.
        Thread.sleep(forTimeInterval: 0.35)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
