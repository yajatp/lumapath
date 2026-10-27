import Foundation
import LumaPathDomain

/// A saved scan is historical evidence, never proof of current room identity.
public enum PlaceScan {
    public static func draft(name: String, appVersion: String, worldMap: Data,
                             positions: [SIMD3<Double>], at date: Date = Date()) throws -> PlaceArchive {
        // Reject poor scans before offering Save. Matchers also enforce distribution at restoration.
        guard positions.count >= 3, positions.count <= 512, positions.allSatisfy(validPosition),
              let origin = positions.first else { throw ContractError.invalidValue("scanFeatures") }
        let end = positions.max { distance(origin, $0) < distance(origin, $1) }!
        let axis = end - origin, length = distance(end, origin)
        guard length >= 0.5, positions.contains(where: { point in
            let d = point - origin
            let cross = SIMD3(axis.y*d.z-axis.z*d.y, axis.z*d.x-axis.x*d.z, axis.x*d.y-axis.y*d.x)
            return distance(cross, .zero) / length >= 0.25
        }) else { throw ContractError.invalidValue("scanFeatureDistribution") }
        let archive = PlaceArchive(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            appVersion: appVersion, createdAt: date, updatedAt: date,
            qualitySummary: "Research AR scan; mapped tracking and distributed feature points at capture. Physical matching unvalidated.",
            worldMap: worldMap, landmarks: positions.map { PlaceLandmark(position: $0) })
        try archive.validate()
        return archive
    }
}

extension PlaceArchive {
    /// Preserve all map/coordinate identities during a name-only revision.
    public func renamed(_ name: String, at date: Date = Date()) throws -> PlaceArchive {
        let result = PlaceArchive(id: id, coordinateFrameID: coordinateFrameID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), appVersion: appVersion,
            createdAt: createdAt, updatedAt: max(date, updatedAt), qualitySummary: qualitySummary,
            worldMap: worldMap, landmarks: landmarks, voxelSize: voxelSize, cells: cells)
        try result.validate()
        return result
    }

    /// A reviewed rescan replaces the coordinate frame, never mixes old landmarks with the new map.
    public func replacingScan(with scan: PlaceArchive, at date: Date = Date()) throws -> PlaceArchive {
        try scan.validate()
        guard scan.worldMap != nil else { throw ContractError.invalidValue("rescanMapRequired") }
        let result = PlaceArchive(id: id, coordinateFrameID: scan.coordinateFrameID, name: name,
            appVersion: scan.appVersion, createdAt: createdAt, updatedAt: max(date, updatedAt),
            qualitySummary: scan.qualitySummary, worldMap: scan.worldMap, landmarks: scan.landmarks,
            voxelSize: scan.voxelSize, cells: scan.cells)
        try result.validate()
        return result
    }
}
