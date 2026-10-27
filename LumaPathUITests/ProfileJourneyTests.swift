import XCTest

final class ProfileJourneyTests: XCTestCase {
    @MainActor func testExplicitSaveSurvivesRelaunchAndExerciseSkipIsDistinct() {
        let app = XCUIApplication(); app.launchArguments = ["-profile-testing"]
        app.launchArguments += ["-skip-welcome"]; app.launch(); reveal("Profiles", app); app.buttons["Profiles"].tap()
        app.buttons["profile.new"].tap()
        let name = "B4 " + UUID().uuidString.prefix(8)
        let field = app.textFields["profile.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Replace the entire default value with a unique name without relying on the edit menu.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "New profile".count) + name + "\n")
        reveal("exercise.contrast", app); app.buttons["exercise.contrast"].tap()
        XCTAssertTrue(app.buttons["exercise.skip"].waitForExistence(timeout: 5)); app.buttons["exercise.skip"].tap()
        reveal("exercise.contrast", app)
        XCTAssertTrue(app.buttons["exercise.contrast"].label.contains("Skipped"))
        app.buttons["profile.save"].tap()
        XCTAssertTrue(app.navigationBars["Profiles"].waitForExistence(timeout: 5))
        if app.buttons["Use \(name)"].exists {
            reveal("Use \(name)", app); app.buttons["Use \(name)"].tap()
        }
        app.terminate(); app.launchArguments += ["-skip-welcome"]; app.launch()
        reveal("Profiles", app); app.buttons["Profiles"].tap()
        XCTAssertTrue(app.staticTexts["profile.active"].label.contains(name))
        reveal(name, app); app.buttons[name].tap(); reveal("exercise.contrast", app)
        XCTAssertTrue(app.buttons["exercise.contrast"].label.contains("Skipped"))
    }
    @MainActor func testLargestTextKeepsProfileSaveAndExerciseSkipReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-profile-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch(); reveal("Profiles", app); app.buttons["Profiles"].tap()
        reveal("profile.new", app); app.buttons["profile.new"].tap()
        XCTAssertTrue(app.buttons["profile.save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile.save"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["profile.save"].frame.height, 56)
        reveal("exercise.placement", app); app.buttons["exercise.placement"].tap()
        XCTAssertTrue(app.buttons["exercise.skip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["exercise.skip"].isHittable)
        XCUIDevice.shared.press(.home); app.activate()
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["exercise.skip"])
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 3), .completed)
        app.buttons["exercise.skip"].tap()
        XCTAssertTrue(app.buttons["profile.save"].isHittable)
    }
    @MainActor func testManualPlaceNotesSaveCancelRelaunchAndConfirmedDelete() {
        let app = XCUIApplication(); app.launchArguments = ["-places-testing"]
        app.launchArguments += ["-skip-welcome"]; app.launch()
        openPlaces(app)
        XCTAssertTrue(app.staticTexts["places.scope"].exists)
        app.buttons["places.add"].tap()
        let name = "B7 " + UUID().uuidString.prefix(8)
        let nameField = app.textFields["place.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText(name + "\n")
        let notes = app.textViews["place.notes"]
        notes.tap(); notes.typeText("Ask at the front desk")
        app.buttons["place.save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        app.staticTexts[name].tap()
        nameField.tap(); nameField.typeText(" unsaved\n")
        app.buttons["place.cancel"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments += ["-skip-welcome"]; app.launch(); openPlaces(app)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        app.staticTexts[name].tap()
        XCTAssertEqual(nameField.value as? String, name)
        XCTAssertEqual(notes.value as? String, "Ask at the front desk")
        let renamed = name + " edited"
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: name.count) + renamed + "\n")
        app.buttons["place.save"].tap()
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 5))
        app.staticTexts[renamed].tap()
        for _ in 0..<8 {
            if app.buttons["place.delete"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["place.delete"].tap()
        XCTAssertTrue(app.buttons["Delete note"].waitForExistence(timeout: 5))
        let keep = app.buttons["Keep note"]
        if keep.exists {
            keep.tap()
        } else {
            // Adaptive confirmation popovers omit the cancel action and expose
            // the system dismissal region instead. Both must keep the saved note.
            let dismiss = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Delete note"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Edit place note"].exists)
        app.buttons["place.delete"].tap()
        XCTAssertTrue(app.buttons["Delete note"].waitForExistence(timeout: 5))
        app.buttons["Delete note"].tap()
        XCTAssertTrue(app.navigationBars["Saved places"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[renamed].exists)
        app.terminate(); app.launchArguments += ["-skip-welcome"]; app.launch(); openPlaces(app)
        XCTAssertFalse(app.staticTexts[renamed].exists)
    }

    @MainActor func testManualPlaceLargestTextKeepsSaveAndCancelReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-places-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-skip-welcome"]; app.launch(); openPlaces(app)
        XCTAssertTrue(app.buttons["places.add"].isHittable)
        app.buttons["places.add"].tap()
        let name = app.textFields["place.name"]
        for _ in 0..<8 {
            if name.isHittable { break }
            app.swipeUp()
        }
        name.tap(); name.typeText("Draft only\n")
        for identifier in ["place.save", "place.cancel"] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.height, 56)
        }
        app.buttons["place.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Saved places"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Draft only"].exists)
    }

    @MainActor private func openPlaces(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["Find"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Find"].tap()
        let saved = app.buttons["Saved places"]
        for _ in 0..<8 {
            if saved.isHittable { break }
            app.swipeUp()
        }
        saved.tap()
        XCTAssertTrue(app.buttons["places.add"].waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["places.add"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    }

    @MainActor private func reveal(_ label: String, _ app: XCUIApplication) {
        for _ in 0..<45 {
            let target = app.buttons[label]
            let save = app.buttons["profile.save"]
            // Form may report a partially covered row as hittable while its center is
            // underneath the fixed Save control. Require the whole row above that inset.
            if target.isHittable && (!save.exists || label == "profile.save" || target.frame.maxY < save.frame.minY - 8) { return }
            app.swipeUp()
        }
    }
}
