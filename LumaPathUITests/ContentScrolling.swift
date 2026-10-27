import XCTest

extension XCUIApplication {
    /// Reach Research tools through the same explicit selector available on a physical phone.
    @MainActor func openDeveloperSettings() {
        for _ in 0..<12 { if buttons["Settings"].isHittable { break }; scrollContentUp() }
        buttons["Settings"].tap()
        let change = buttons["interface.change"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        if change.label == "Use Developer interface" {
            change.tap()
            XCTAssertTrue(staticTexts["interface.developer"].waitForExistence(timeout: 5))
            for _ in 0..<12 { if buttons["Settings"].isHittable { break }; scrollContentUp() }
            buttons["Settings"].tap()
        }
    }
    /// SwiftUI forms/lists expose native collection/table containers, while camera pages scroll.
    @MainActor func scrollContentUp() { contentScroller.swipeUp() }
    @MainActor func scrollContentDown() { contentScroller.swipeDown() }
    @MainActor private var contentScroller: XCUIElement {
        for query in [scrollViews, collectionViews, tables] {
            if let candidate = query.allElementsBoundByIndex.last(where: { $0.isHittable }) { return candidate }
        }
        return self
    }
}
