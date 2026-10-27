import XCTest
import Foundation
import LumaPathMemory
import LumaPathSensors

final class MemoryArchiveTests: XCTestCase {
    @MainActor func testWorldMapDecodeRejectsCorruptOversizedAndWrongSecureRoot() throws {
        XCTAssertThrowsError(try WorldMapArchive.decode(Data()))
        XCTAssertThrowsError(try WorldMapArchive.decode(Data("invalid keyed archive".utf8)))
        XCTAssertThrowsError(try WorldMapArchive.decode(Data(repeating: 0,count: 8_388_609)))
        let wrongRoot = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "not a world map"),requiringSecureCoding: true)
        XCTAssertThrowsError(try WorldMapArchive.decode(wrongRoot))
    }
    @MainActor func testStoppedCaptureCannotSaveOrRestoreCorruptWorldMap() async {
        let driver = ARKitDriver()
        do { _ = try await driver.captureWorldMap(); XCTFail("Stopped capture returned a map") } catch {}
        XCTAssertThrowsError(try driver.restore(worldMapData: Data("corrupt".utf8),depthKind: .none))
    }
    func testPlaceFilesUseCompleteProtectionAndRestrictivePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PlaceStore(directory: directory)
        let place = PlaceArchive(name: "Simulator fixture",appVersion: "test",qualitySummary: "No real scan",landmarks: [
            PlaceLandmark(position: SIMD3(0,0,0)),PlaceLandmark(position: SIMD3(1,0,0)),PlaceLandmark(position: SIMD3(0,0,1))])
        try await store.save(place)
        let file = directory.appendingPathComponent(place.id.uuidString+".place")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #if targetEnvironment(simulator)
        // Simulator filesystems may omit data-protection metadata despite accepting the request.
        // Only a physical locked-device trial can verify enforcement.
        if let protection = attributes[.protectionKey] as? FileProtectionType { XCTAssertEqual(protection,.complete) }
        #else
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,.complete)
        #endif
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try await store.delete(place.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
