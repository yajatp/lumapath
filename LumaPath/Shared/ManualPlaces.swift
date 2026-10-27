import Foundation

/// User-entered reference only. Never a spatial archive, current observation, or goal detection.
public struct ManualPlaceNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: UInt64
    public let name: String
    public let text: String
    public let createdAt: Date
    public let updatedAt: Date
}

public enum ManualPlaceError: Error, Equatable, Sendable {
    case invalidName, textTooLong, libraryFull, conflict, invalidArchive
}

/// One shared instance per library. Revision checks prevent stale editors from resurrecting deleted notes.
/// This separate namespace has no world maps, camera images, coordinates, output queues, or network path.
public actor ManualPlaceLibrary {
    public static let maximumPlaces = 100
    public static let maximumNameLength = 80
    public static let maximumTextLength = 2000
    private static let maximumBytes = 1_048_576
    private struct Archive: Codable { let schemaVersion: Int; var places: [ManualPlaceNote] }
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("manual-places.json") }
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> [ManualPlaceNote] { try read().places }

    /// nil revision creates only; edits require the exact revision shown to the user.
    @discardableResult public func save(id: UUID, expectedRevision: UInt64?, name: String, text: String,
                                       at now: Date = Date()) throws -> [ManualPlaceNote] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maximumNameLength else { throw ManualPlaceError.invalidName }
        guard text.count <= Self.maximumTextLength else { throw ManualPlaceError.textTooLong }
        guard now.timeIntervalSince1970.isFinite else { throw ManualPlaceError.invalidArchive }
        var archive = try read()
        let index = archive.places.firstIndex { $0.id == id }
        let existing = index.map { archive.places[$0] }
        guard existing?.revision == expectedRevision else { throw ManualPlaceError.conflict }
        guard existing?.revision != UInt64.max else { throw ManualPlaceError.conflict }
        guard existing != nil || archive.places.count < Self.maximumPlaces else { throw ManualPlaceError.libraryFull }
        let note = ManualPlaceNote(id: id, revision: (existing?.revision ?? 0) + 1, name: name, text: text,
            createdAt: existing?.createdAt ?? now, updatedAt: max(existing?.updatedAt ?? now, now))
        if let index { archive.places[index] = note } else { archive.places.append(note) }
        try write(archive)
        return sorted(archive.places)
    }

    @discardableResult public func delete(id: UUID, expectedRevision: UInt64) throws -> [ManualPlaceNote] {
        var archive = try read()
        guard let index = archive.places.firstIndex(where: { $0.id == id }),
              archive.places[index].revision == expectedRevision else { throw ManualPlaceError.conflict }
        archive.places.remove(at: index)
        try write(archive)
        return sorted(archive.places)
    }

    private func read() throws -> Archive {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Archive(schemaVersion: 1, places: [])
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else {
            throw ManualPlaceError.invalidArchive
        }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumBytes else { throw ManualPlaceError.invalidArchive }
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: data) }
        catch { throw ManualPlaceError.invalidArchive }
        guard archive.schemaVersion == 1, archive.places.count <= Self.maximumPlaces,
              Set(archive.places.map(\.id)).count == archive.places.count,
              archive.places.allSatisfy({ note in
                  note.revision > 0 && !note.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && note.name.count <= Self.maximumNameLength && note.text.count <= Self.maximumTextLength
                  && note.createdAt.timeIntervalSince1970.isFinite && note.updatedAt.timeIntervalSince1970.isFinite
                  && note.updatedAt >= note.createdAt
              }) else { throw ManualPlaceError.invalidArchive }
        return Archive(schemaVersion: 1, places: sorted(archive.places))
    }
    private func write(_ archive: Archive) throws {
        let data = try JSONEncoder().encode(archive)
        guard data.count <= Self.maximumBytes else { throw ManualPlaceError.libraryFull }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func sorted(_ places: [ManualPlaceNote]) -> [ManualPlaceNote] {
        places.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }
}
