import Foundation
import Testing
@testable import LumaPathDomain

private func placeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func manualPlacesPersistEditsAndDeleteWithoutResurrectingStaleDrafts() async throws {
    let directory = try placeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ManualPlaceLibrary(directory: directory), id = UUID()
    #expect(try await library.load().isEmpty)
    let first = try await library.save(id: id, expectedRevision: nil, name: "  Library  ", text: "Desk by the entrance", at: Date(timeIntervalSince1970: 100))
    #expect(first.count == 1 && first[0].name == "Library" && first[0].revision == 1)
    let reopened = ManualPlaceLibrary(directory: directory)
    #expect(try await reopened.load() == first)
    let updated = try await library.save(id: id, expectedRevision: 1, name: "Local library", text: "Ask at the desk", at: Date(timeIntervalSince1970: 90))
    #expect(updated[0].revision == 2 && updated[0].createdAt == first[0].createdAt)
    #expect(updated[0].updatedAt == first[0].updatedAt) // Clock rollback cannot reverse update dates.
    await #expect(throws: ManualPlaceError.conflict) {
        try await library.save(id: id, expectedRevision: 1, name: "Old draft", text: "")
    }
    await #expect(throws: ManualPlaceError.conflict) { try await library.delete(id: id, expectedRevision: 1) }
    #expect(try await library.delete(id: id, expectedRevision: 2).isEmpty)
    await #expect(throws: ManualPlaceError.conflict) {
        try await library.save(id: id, expectedRevision: 2, name: "Deleted draft", text: "")
    }
    #expect(try await reopened.load().isEmpty)
    let data = try Data(contentsOf: directory.appendingPathComponent("manual-places.json"))
    #expect(!String(decoding: data, as: UTF8.self).contains("Ask at the desk"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["manual-places.json"])
}

@Test func manualPlacesRejectInvalidDraftsWithoutChangingSavedData() async throws {
    let directory = try placeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ManualPlaceLibrary(directory: directory), id = UUID()
    let saved = try await library.save(id: id, expectedRevision: nil, name: "Cafe", text: "Own note")
    await #expect(throws: ManualPlaceError.invalidName) {
        try await library.save(id: id, expectedRevision: 1, name: " \n ", text: "")
    }
    await #expect(throws: ManualPlaceError.invalidName) {
        try await library.save(id: id, expectedRevision: 1, name: String(repeating: "a", count: 81), text: "")
    }
    await #expect(throws: ManualPlaceError.textTooLong) {
        try await library.save(id: id, expectedRevision: 1, name: "Cafe", text: String(repeating: "a", count: 2001))
    }
    #expect(try await library.load() == saved)
}

@Test func manualPlacesKeepCorruptUnknownAndOversizedArchivesForRecovery() async throws {
    let directory = try placeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ManualPlaceLibrary(directory: directory)
    let file = directory.appendingPathComponent("manual-places.json")
    for data in [Data("not json".utf8), Data(#"{"schemaVersion":99,"places":[]}"#.utf8), Data(repeating: 32, count: 1_048_577)] {
        try data.write(to: file)
        await #expect(throws: ManualPlaceError.invalidArchive) { try await library.load() }
        await #expect(throws: ManualPlaceError.invalidArchive) {
            try await library.save(id: UUID(), expectedRevision: nil, name: "No overwrite", text: "")
        }
        #expect(try Data(contentsOf: file) == data)
    }
}

@Test func manualPlacesRejectDuplicateIDsAndInvalidRecords() async throws {
    let directory = try placeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ManualPlaceLibrary(directory: directory)
    _ = try await library.save(id: UUID(), expectedRevision: nil, name: "Entry", text: "")
    let file = directory.appendingPathComponent("manual-places.json")
    let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let notes = try #require(original["places"] as? [[String: Any]])
    var invalid = notes[0]; invalid["revision"] = 0
    for entries in [[notes[0], notes[0]], [invalid]] {
        var document = original; document["places"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        await #expect(throws: ManualPlaceError.invalidArchive) { try await library.load() }
    }
}

@Test func manualPlacesBoundLibraryAndDoNotCreateSensorEvidence() async throws {
    let directory = try placeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ManualPlaceLibrary(directory: directory)
    for index in 1...ManualPlaceLibrary.maximumPlaces {
        _ = try await library.save(id: UUID(), expectedRevision: nil, name: "Place \(index)", text: "User text")
    }
    await #expect(throws: ManualPlaceError.libraryFull) {
        try await library.save(id: UUID(), expectedRevision: nil, name: "Overflow", text: "")
    }
    #expect(try await library.load().count == 100)
    let data = try Data(contentsOf: directory.appendingPathComponent("manual-places.json"))
    let archive = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entry = try #require((archive["places"] as? [[String: Any]])?.first)
    #expect(Set(entry.keys) == Set(["id", "revision", "name", "text", "createdAt", "updatedAt"]))
}

@Test func manualPlacesSerializeCompetingEditsAndSurfaceStorageFailures() async throws {
    let directory = try placeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ManualPlaceLibrary(directory: directory), id = UUID()
    _ = try await library.save(id: id, expectedRevision: nil, name: "Original", text: "")
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for name in ["First edit", "Second edit"] {
            group.addTask {
                do { _ = try await library.save(id: id, expectedRevision: 1, name: name, text: ""); return true }
                catch { return false }
            }
        }
        var count = 0
        for await result in group { if result { count += 1 } }
        return count
    }
    #expect(successes == 1)
    #expect(try await library.load()[0].revision == 2)
    let blocked = directory.appendingPathComponent("not-a-directory")
    try Data("preserve".utf8).write(to: blocked)
    let unavailable = ManualPlaceLibrary(directory: blocked)
    await #expect(throws: (any Error).self) {
        try await unavailable.save(id: UUID(), expectedRevision: nil, name: "Cannot save", text: "")
    }
    #expect(try Data(contentsOf: blocked) == Data("preserve".utf8))
}
