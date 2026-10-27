import Foundation

public struct AdvancedConfiguration: Sendable {
    public static let current = AdvancedConfiguration()
    public let configurationVersion = 1
    public let voxelSize = 0.10
    public let maximumVoxels = 20_000
    public let maximumRays = 2_048
    public let memoryLifetime = 0.75
    public let minimumSurfaceSupport = 3
    public let confirmationFrames = 2
    public let minimumStepHeight = 0.08
    public let maximumStepHeight = 0.30
    public let maximumTracks = 32
    public let associationDistance = 0.60
    public let maximumTrackAge = 0.50
    public let positionUncertainty = 0.05
    public let maximumVelocityUncertainty = 0.60
    public let maximumTurnRadians = 0.35
    public init() {}
}
public struct MobilityGeometryProfile: Sendable, Equatable {
    public let requiredWidth: Double
    public let clearanceHeight: Double
    public let earlierNotice: Bool
    public init(requiredWidth: Double = 0.8, clearanceHeight: Double = 1.8, earlierNotice: Bool = false) throws {
        guard requiredWidth.isFinite, clearanceHeight.isFinite, (0.3...2).contains(requiredWidth),
              (0.8...2.5).contains(clearanceHeight) else { throw ContractError.invalidValue("geometryProfile") }
        self.requiredWidth = requiredWidth; self.clearanceHeight = clearanceHeight; self.earlierNotice = earlierNotice
    }
    public static let standard = try! MobilityGeometryProfile()
}
public enum AdvancedHazardFamily: String, Codable, Sendable, CaseIterable {
    case overhead, narrowPassage, stepUp, stepDown, stairs, movingObstacle
}
public struct FeatureActivation: Codable, Sendable, Equatable {
    public let family: AdvancedHazardFamily
    public let implementationVersion: Int
    public let researchAvailable: Bool
    public let ordinaryLiveAvailable: Bool
    public let reasons: [String]
    public init(family: AdvancedHazardFamily, researchAvailable: Bool, reasons: [String]) {
        self.family = family; implementationVersion = 1; self.researchAvailable = researchAvailable
        ordinaryLiveAvailable = false; self.reasons = reasons
    }
    public static var researchOnly: [FeatureActivation] {
        AdvancedHazardFamily.allCases.map {
            FeatureActivation(family: $0,researchAvailable: true,reasons: ["physicalValidationPending","consumerReviewPending"])
        }
    }
}
public struct VoxelKey: Hashable, Codable, Sendable {
    public let x: Int, y: Int, z: Int
    public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
}
public enum VolumeEvidence: String, Codable, Sendable { case unknown, observedFree, occupied }
public struct VoxelObservation: Sendable {
    public let key: VoxelKey
    public let evidence: VolumeEvidence
    public let lastObservedAt: TimeInterval
    public let support: Int
    public init(key: VoxelKey, evidence: VolumeEvidence, lastObservedAt: TimeInterval, support: Int) {
        self.key = key; self.evidence = evidence; self.lastObservedAt = lastObservedAt; self.support = support
    }
}
public struct OccupancySnapshot: Sendable {
    public let frame: FrameDescriptor
    public let voxelSize: Double
    public let cells: [VoxelKey: VoxelObservation]
    public let truncated: Bool
    public init(frame: FrameDescriptor, voxelSize: Double, cells: [VoxelKey: VoxelObservation], truncated: Bool) {
        self.frame = frame; self.voxelSize = voxelSize; self.cells = cells; self.truncated = truncated
    }
    public func evidence(at key: VoxelKey) -> VolumeEvidence { cells[key]?.evidence ?? .unknown }
}
public struct AdvancedHazardCandidate: Sendable, Equatable {
    public let id: UUID
    public let envelope: ObservationEnvelope
    public let family: AdvancedHazardFamily
    public let rangeMeters: Double
    public let bearingRadians: Double
    public let measuredWidth: Double?
    public let heightChange: Double?
    public let encounterTime: Double?
    public let uncertaintyMeters: Double
    public let reasons: [String]
    public init(id: UUID = UUID(), envelope: ObservationEnvelope, family: AdvancedHazardFamily,
                rangeMeters: Double, bearingRadians: Double, measuredWidth: Double? = nil,
                heightChange: Double? = nil, encounterTime: Double? = nil, uncertaintyMeters: Double, reasons: [String]) {
        self.id = id; self.envelope = envelope; self.family = family; self.rangeMeters = rangeMeters
        self.bearingRadians = bearingRadians; self.measuredWidth = measuredWidth; self.heightChange = heightChange
        self.encounterTime = encounterTime; self.uncertaintyMeters = uncertaintyMeters; self.reasons = reasons
    }
}
public struct MotionTrack: Sendable {
    public let id: UUID
    public let observationID: UUID
    public let worldPosition: SIMD3<Double>
    public let worldVelocity: SIMD3<Double>?
    public let velocityUncertainty: Double?
    public let positionResidual: Double?
    public let encounterTime: Double?
    public let closestApproach: Double?
    public let reasons: [String]
    public init(id: UUID, observationID: UUID, worldPosition: SIMD3<Double>, worldVelocity: SIMD3<Double>?,
                velocityUncertainty: Double?, encounterTime: Double?, closestApproach: Double?, reasons: [String], positionResidual: Double? = nil) {
        self.id = id; self.observationID = observationID; self.worldPosition = worldPosition; self.worldVelocity = worldVelocity
        self.velocityUncertainty = velocityUncertainty; self.positionResidual = positionResidual; self.encounterTime = encounterTime; self.closestApproach = closestApproach; self.reasons = reasons
    }
}
public struct AdvancedGeometryResult: Sendable {
    public let occupancy: OccupancySnapshot
    public let candidates: [AdvancedHazardCandidate]
    public let tracks: [MotionTrack]
    public let activations: [FeatureActivation]
    public let reasons: [String]
    public init(occupancy: OccupancySnapshot, candidates: [AdvancedHazardCandidate], tracks: [MotionTrack],
                activations: [FeatureActivation], reasons: [String]) {
        self.occupancy = occupancy; self.candidates = candidates; self.tracks = tracks; self.activations = activations; self.reasons = reasons
    }
}
