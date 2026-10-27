import XCTest
@testable import LumaPath

final class PresentationSettingsTests: XCTestCase {
    @MainActor func testExplicitInterfaceSelectionIsIdempotentAndDefaultsToStandard() {
        let interface = InterfaceMode()
        XCTAssertFalse(interface.developer)
        interface.setDeveloper(true)
        XCTAssertTrue(interface.developer)
        interface.setDeveloper(true)
        XCTAssertTrue(interface.developer)
        interface.setDeveloper(false)
        XCTAssertFalse(interface.developer)
        XCTAssertFalse(InterfaceMode().developer)
    }
    @MainActor func testDefaultsAndExplicitChoicesSurviveRelaunch() throws {
        let suite = "LumaPathPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PresentationSettings(defaults: defaults)
        XCTAssertEqual(settings.style, .combined)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.welcomed)
        settings.style = .voice; settings.appearance = .dark; settings.welcomed = true
        let restored = PresentationSettings(defaults: defaults)
        XCTAssertEqual(restored.style, .voice)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertTrue(restored.welcomed)
        // Presentation choices must never opt into microphone, Research or phone output.
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []),
                       Set(["presentation.style", "presentation.appearance", "presentation.welcomed"]))
    }

    @MainActor func testUnknownStoredChoicesRecoverToDefaults() throws {
        let suite = "LumaPathPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("missing-style", forKey: "presentation.style")
        defaults.set("missing-theme", forKey: "presentation.appearance")
        let settings = PresentationSettings(defaults: defaults)
        XCTAssertEqual(settings.style, .combined)
        XCTAssertEqual(settings.appearance, .system)
    }
}
