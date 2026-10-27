import XCTest

final class GeometryResearchTests: XCTestCase {
    @MainActor func testSyntheticGeometryShowsAheadSideAndImmediateCloseHazards() {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-welcome"]; app.launch()
        app.openDeveloperSettings()
        for _ in 0..<6 {
            if app.buttons["geometry.research"].isHittable { break }
            app.scrollContentUp()
        }
        app.buttons["geometry.research"].tap()
        XCTAssertTrue(app.staticTexts["Research — synthetic depth"].waitForExistence(timeout: 5))
        app.buttons["Next depth fixture"].tap()
        XCTAssertTrue(app.staticTexts["obstacle.ahead · warning"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["geometry.components"].label,"Components, 1")
        app.buttons["Next depth fixture"].tap()
        XCTAssertTrue(app.staticTexts["obstacle.right · information"].waitForExistence(timeout: 5))
        app.buttons["Next depth fixture"].tap()
        XCTAssertTrue(app.staticTexts["obstacle.ahead · urgent"].waitForExistence(timeout: 5))
        app.buttons["Next depth fixture"].tap()
        XCTAssertEqual(app.staticTexts["geometry.components"].label,"Components, 0")
    }
}
