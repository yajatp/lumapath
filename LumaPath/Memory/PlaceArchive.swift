import Foundation
import CryptoKit
import LumaPathDomain

public struct PlaceLandmark: Codable, Sendable, Equatable {
    public let id: UUID
    public let label: String?
    public let userConfirmed: Bool
    public let position: SIMD3<Double>
    public init(id: UUID = UUID(), label: String? = nil, userConfirmed: Bool = false, position: SIMD3<Double>) {
        self.id = id; self.label = label; self.userConfirmed = userConfirmed; self.position = position
    }
}
public struct SavedCell: Codable, Sendable, Equatable {
    public let key: VoxelKey
    public let evidence: VolumeEvidence
    public init(key: VoxelKey, evidence: VolumeEvidence) { self.key = key; self.evidence = evidence }
}
/// Coordinates belong only to coordinateFrameID, never to a subsequent AR session implicitly.
public struct PlaceArchive: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public let id: UUID
    public let revision: UUID
    public let coordinateFrameID: UUID
    public let name: String
    public let appVersion: String
    public let createdAt: Date
    public let updatedAt: Date
    public let qualitySummary: String
    public let worldMap: Data?
    public let landmarks: [PlaceLandmark]
    public let voxelSize: Double
    public let cells: [SavedCell]
    public init(id: UUID = UUID(), revision: UUID = UUID(), coordinateFrameID: UUID = UUID(), name: String,
                appVersion: String, createdAt: Date = Date(), updatedAt: Date = Date(), qualitySummary: String,
                worldMap: Data? = nil, landmarks: [PlaceLandmark], voxelSize: Double = 0.2, cells: [SavedCell] = []) {
        self.id = id; self.revision = revision; self.coordinateFrameID = coordinateFrameID; self.name = name
        self.appVersion = appVersion; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.qualitySummary = qualitySummary; self.worldMap = worldMap; self.landmarks = landmarks
        self.voxelSize = voxelSize; self.cells = cells
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ContractError.unsupportedSchema(schemaVersion) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              !appVersion.isEmpty, !qualitySummary.isEmpty, qualitySummary.count <= 2048,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
              worldMap.map({ !$0.isEmpty && $0.count <= 8_388_608 }) ?? true,
              landmarks.count >= 3, landmarks.count <= 512, Set(landmarks.map(\.id)).count == landmarks.count,
              landmarks.allSatisfy({ validPosition($0.position) && ($0.label?.count ?? 0) <= 120 && (!$0.userConfirmed || $0.label?.isEmpty == false) }),
              voxelSize.isFinite, (0.15...0.5).contains(voxelSize), cells.count <= 20_000,
              Set(cells.map(\.key)).count == cells.count,
              cells.allSatisfy({ abs(Double($0.key.x)) < 10_000 && abs(Double($0.key.y)) < 10_000 && abs(Double($0.key.z)) < 10_000 })
        else { throw ContractError.invalidValue("placeArchive") }
    }
}
func validPosition(_ p: SIMD3<Double>) -> Bool { [p.x,p.y,p.z].allSatisfy { $0.isFinite && abs($0) < 1000 } }
func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a-b; return (d.x*d.x+d.y*d.y+d.z*d.z).squareRoot()
}

/// One atomic, checksummed envelope contains current and one rollback revision. No scene uptime is persisted.
public actor PlaceStore {
    private struct Contents: Codable { let current: PlaceArchive; let rollback: PlaceArchive? }
    private struct Envelope: Codable { let schemaVersion: Int; let payload: Data; let sha256: String }
    private let root: URL
    private let maximumBytes: Int
    private let maximumPlaces: Int
    private let maximumFileBytes = 24_000_000
    public init(directory: URL, maximumBytes: Int = 100_000_000, maximumPlaces: Int = 20) throws {
        guard directory.isFileURL, maximumBytes > 0, maximumPlaces > 0 else { throw ContractError.invalidValue("placeStorageBudget") }
        root = directory.standardizedFileURL; self.maximumBytes = maximumBytes; self.maximumPlaces = maximumPlaces
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              root.resolvingSymlinksInPath().path == root.path else { throw ContractError.invalidValue("placeStorageSymlink") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var excluded = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
    }
    public func load(_ id: UUID) throws -> PlaceArchive { try read(id).current }
    public func hasRollback(_ id: UUID) throws -> Bool { try read(id).rollback != nil }
    public func list() throws -> [PlaceArchive] {
        try files().map { try read($0).current }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }
    public func save(_ place: PlaceArchive) throws {
        try place.validate()
        guard !FileManager.default.fileExists(atPath: url(place.id).path) else { throw ContractError.invalidValue("placeAlreadyExists") }
        try write(Contents(current: place, rollback: nil))
    }
    /// A concrete user-reviewed revision is mandatory. No automatic memory rewrite from change candidates.
    public func update(_ place: PlaceArchive, reviewedRevision: UUID) throws {
        try place.validate(); let old = try read(place.id).current
        guard old.revision == reviewedRevision, place.revision != old.revision,
              place.createdAt == old.createdAt, place.updatedAt >= old.updatedAt else { throw ContractError.invalidValue("placeRevisionConflict") }
        try write(Contents(current: place, rollback: old))
    }
    @discardableResult public func rollback(_ id: UUID, reviewedRevision: UUID) throws -> PlaceArchive {
        let contents = try read(id)
        guard contents.current.revision == reviewedRevision, let old = contents.rollback else { throw ContractError.invalidValue("placeRollbackUnavailable") }
        // Consume rollback; a new revision prevents stale review tokens from matching after an undo.
        let restored = PlaceArchive(id: old.id, coordinateFrameID: old.coordinateFrameID, name: old.name,
            appVersion: old.appVersion, createdAt: old.createdAt, updatedAt: max(Date(),contents.current.updatedAt),
            qualitySummary: old.qualitySummary, worldMap: old.worldMap, landmarks: old.landmarks, voxelSize: old.voxelSize, cells: old.cells)
        try write(Contents(current: restored,rollback: nil)); return restored
    }
    public func delete(_ id: UUID) throws {
        // All supported derivatives, including map and rollback, live in this single file.
        let file = url(id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    /// Product deletion must confirm the exact revision shown to the user.
    public func delete(_ id: UUID, reviewedRevision: UUID) throws {
        guard try read(id).current.revision == reviewedRevision else {
            throw ContractError.invalidValue("placeRevisionConflict")
        }
        try delete(id)
    }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathExtension("place") }
    private func files() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap {
            $0.pathExtension == "place" ? UUID(uuidString: $0.deletingPathExtension().lastPathComponent) : nil
        }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func read(_ id: UUID) throws -> Contents {
        let file = url(id), values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumFileBytes else {
            throw ContractError.invalidValue("placeFileBudgetOrType")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        guard envelope.schemaVersion == 1, digest(envelope.payload) == envelope.sha256 else { throw ContractError.invalidValue("placeIntegrity") }
        let contents = try JSONDecoder().decode(Contents.self,from: envelope.payload)
        try contents.current.validate(); try contents.rollback?.validate()
        guard contents.current.id == id, contents.rollback == nil || contents.rollback?.id == id else { throw ContractError.invalidValue("placeIdentity") }
        return contents
    }
    private func write(_ contents: Contents) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(contents)
        let data = try encoder.encode(Envelope(schemaVersion: 1,payload: payload,sha256: digest(payload)))
        let ids = try files()
        guard ids.contains(contents.current.id) || ids.count < maximumPlaces else { throw ContractError.invalidValue("placeCountCap") }
        let otherBytes = try ids.filter { $0 != contents.current.id }.reduce(0) { total, id in
            let size = try url(id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes
            guard size <= maximumBytes-total else { throw ContractError.invalidValue("placeStorageCap") }; return total+size
        }
        guard data.count <= maximumFileBytes, data.count <= maximumBytes-otherBytes else { throw ContractError.invalidValue("placeStorageCap") }
        #if os(iOS)
        try data.write(to: url(contents.current.id), options: [.atomic,.completeFileProtection])
        #else
        try data.write(to: url(contents.current.id), options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: url(contents.current.id).path)
    }
}
