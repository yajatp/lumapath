import XCTest

final class FeedbackJourneyTests: XCTestCase {
    @MainActor func testCuePreviewStartsMutedAndStopAndBackgroundCancel() {
        let app = XCUIApplication(); app.launchArguments += ["-skip-welcome"]; app.launch()
        reveal("Settings", in: app); app.buttons["Settings"].tap()
        reveal("Phone cue preview", in: app); app.buttons["Phone cue preview"].tap()
        XCTAssertTrue(app.staticTexts["Stationary cue preview — no live sensing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Play selected cue"].isEnabled)
        let speech = app.switches["Preview phone speech"]
        if speech.isEnabled {
            speech.tap(); reveal("Play selected cue", in: app); app.buttons["Play selected cue"].tap()
            XCTAssertTrue(app.staticTexts["feedback.previewStatus"].label.contains("Preview:"))
        }
        app.buttons["Stop preview"].tap()
        XCTAssertEqual(app.staticTexts["feedback.previewStatus"].label, "Preview stopped")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertEqual(app.staticTexts["feedback.previewStatus"].label, "Preview stopped")
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["Stop preview"])
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 3), .completed)
    }
    @MainActor func testLiveResearchStartsOffAndKeepsControlsReachable() {
        let app = XCUIApplication(); app.launchArguments += ["-skip-welcome"]; app.launch()
        reveal("Start live view", in: app); app.buttons["Start live view"].tap()
        XCTAssertTrue(app.staticTexts["feedback.channels"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["feedback.channels"].label, "Visual view only; alerts muted")
        reveal("Sensing status: not started", in: app); app.buttons["Sensing status: not started"].tap()
        XCTAssertEqual(app.staticTexts["quality.summary"].label, "Sensing has not started.")
        XCTAssertTrue(app.buttons["Help"].isHittable)
        XCTAssertTrue(app.buttons["End live view"].isHittable)
        app.buttons["Help"].tap()
        XCTAssertTrue(app.staticTexts["Live view paused"].waitForExistence(timeout: 5))
        app.buttons["Close Help"].tap()
    }
    @MainActor private func reveal(_ title: String, in app: XCUIApplication) {
        for _ in 0..<10 { if app.buttons[title].isHittable { return }; app.scrollContentUp() }
    }
    @MainActor func testLargeTextLiveAssistantReviewsTypedCommandWithoutMicrophone() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        app.buttons["Start live view"].tap()
        XCTAssertTrue(app.buttons["Help"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Help"].isHittable)
        reveal("live.assistant", in: app); app.buttons["live.assistant"].tap()
        let input = app.textFields["live.assistant.input"].exists ? app.textFields["live.assistant.input"] : app.textViews["live.assistant.input"]
        for _ in 0..<10 { if input.isHittable { break }; app.scrollContentUp() }
        input.tap(); input.typeText("pause")
        reveal("Review typed command", in: app); app.buttons["Review typed command"].tap()
        reveal("Confirm command", in: app)
        XCTAssertTrue(app.staticTexts["Pause the camera"].exists)
        app.buttons["Confirm command"].tap()
        for _ in 0..<10 { if app.staticTexts["Camera paused."].isHittable { break }; app.scrollContentUp() }
        XCTAssertTrue(app.staticTexts["Camera paused."].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Help"].isHittable)
    }
}
