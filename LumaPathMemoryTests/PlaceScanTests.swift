import Foundation
import Testing
import LumaPathDomain
import LumaPathMemory

private func scanFixture(name: String = "Room", offset: Double = 0) throws -> PlaceArchive {
    try PlaceScan.draft(name: name, appVersion: "test", worldMap: Data([1, 2, 3]),
        positions: [SIMD3(offset, 0, 0), SIMD3(offset + 1, 0, 0), SIMD3(offset, 0, 1)])
}

@Test func scanDraftRequiresBoundedDistributedCurrentFeaturesAndNeverLabelsThem() throws {
    let scan = try scanFixture(name: " Room ")
    #expect(scan.name == "Room")
    #expect(scan.landmarks.allSatisfy { !$0.userConfirmed && $0.label == nil })
    #expect(scan.cells.isEmpty)
    let cases: [[SIMD3<Double>]] = [[], [SIMD3.zero],
        [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)],
        [SIMD3(0, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0, 0.1)],
        [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(Double.nan, 0, 1)],
        Array(repeating: SIMD3(0, 0, 0), count: 513)]
    for positions in cases {
        #expect(throws: ContractError.self) {
            try PlaceScan.draft(name: "Room", appVersion: "test", worldMap: Data([1]), positions: positions)
        }
    }
    #expect(throws: ContractError.self) {
        try PlaceScan.draft(name: "Room", appVersion: "test", worldMap: Data(), positions: scan.landmarks.map(\.position))
    }
    #expect(throws: ContractError.self) { try scanFixture(name: "   ") }
}

@Test func reviewedRenameAndRescanPreserveIdentityButNeverMixCoordinateFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PlaceStore(directory: root)
    let original = try scanFixture()
    try await store.save(original)
    let renamed = try original.renamed("New name")
    try await store.update(renamed, reviewedRevision: original.revision)
    #expect(renamed.revision != original.revision)
    #expect(renamed.coordinateFrameID == original.coordinateFrameID)
    #expect(renamed.worldMap == original.worldMap)
    #expect(renamed.landmarks == original.landmarks)
    #expect(try await store.hasRollback(original.id))
    let newScan = try scanFixture(name: "Draft", offset: 10)
    let replacement = try renamed.replacingScan(with: newScan)
    #expect(replacement.id == original.id && replacement.name == "New name")
    #expect(replacement.coordinateFrameID == newScan.coordinateFrameID)
    #expect(replacement.landmarks == newScan.landmarks)
    #expect(replacement.landmarks != original.landmarks)
    try await store.update(replacement, reviewedRevision: renamed.revision)
    let restored = try await store.rollback(original.id, reviewedRevision: replacement.revision)
    #expect(restored.coordinateFrameID == original.coordinateFrameID)
    #expect(restored.landmarks == original.landmarks)
    #expect(restored.name == "New name")
    #expect(restored.revision != renamed.revision)
    #expect(try await !store.hasRollback(original.id))
}

@Test func staleReviewCannotDeleteOrOverwriteAReplacedScanAndDeletionRemovesRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PlaceStore(directory: root), original = try scanFixture()
    try await store.save(original)
    let update = try original.renamed("Revised")
    try await store.update(update, reviewedRevision: original.revision)
    await #expect(throws: ContractError.self) { try await store.delete(original.id, reviewedRevision: original.revision) }
    await #expect(throws: ContractError.self) { try await store.update(original.renamed("Stale"), reviewedRevision: original.revision) }
    #expect(try await store.load(original.id).revision == update.revision)
    try await store.delete(original.id, reviewedRevision: update.revision)
    #expect(try await store.list().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    await #expect(throws: (any Error).self) { try await store.rollback(original.id, reviewedRevision: update.revision) }
}
