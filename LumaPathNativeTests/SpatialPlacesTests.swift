import XCTest
import LumaPathMemory
@testable import LumaPath

final class SpatialPlacesTests: XCTestCase {
    @MainActor func testLibraryLoadsRenamesRollsBackAndRejectsStaleDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PlaceStore(directory: root)
        let scan = try PlaceScan.draft(name: "Test room", appVersion: "test", worldMap: Data([1]),
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])
        try await storage.save(scan)
        let model = SpatialPlacesModel(storage: storage)
        await model.reload()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.places.count, 1)
        let renamed = await model.rename(scan, to: "Renamed")
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.places.first?.name, "Renamed")
        let staleDeletion = await model.delete(scan)
        XCTAssertFalse(staleDeletion)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.places.count, 1)
        let current = try XCTUnwrap(model.places.first)
        let rolledBack = await model.rollback(current)
        XCTAssertTrue(rolledBack)
        XCTAssertEqual(model.places.first?.name, scan.name)
        let restored = try XCTUnwrap(model.places.first)
        let deleted = await model.delete(restored)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.places.isEmpty)
    }

    @MainActor func testCorruptionPreservesFilesAndBlocksMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PlaceStore(directory: root)
        let broken = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("place")
        try Data("broken archive".utf8).write(to: broken)
        let model = SpatialPlacesModel(storage: storage)
        await model.reload()
        XCTAssertFalse(model.loaded)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try Data(contentsOf: broken), Data("broken archive".utf8))
        XCTAssertFalse(model.scanning)
        XCTAssertNil(model.draft)
        model.stopScan()
        XCTAssertNil(model.draft)
    }
}
