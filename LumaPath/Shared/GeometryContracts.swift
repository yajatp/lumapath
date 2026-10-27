import Foundation

/// Engineering hypotheses, not measured sensing limits. All A3 output remains Research-only.
public struct GeometryConfiguration: Sendable, Equatable {
    public static let current = GeometryConfiguration()
    public let configurationVersion = 2
    public let minimumDepth: Double = 0.3
    public let maximumDepth: Double = 4.0
    public let maximumDepthPixels = 262_144
    public let tileSize = 2
    public let minimumTileSupport = 2
    public let depthDiscontinuity: Double = 0.20
    public let neighborDistance: Double = 0.25
    public let minimumComponentSupport = 8
    public let maximumComponents = 32
    public let corridorWidth: Double = 1.0
    public let urgentRange: Double = 1.0
    public let groundResidual: Double = 0.03
    public let groundHeightTolerance: Double = 0.10
    public let groundMinimumSupport = 100
    public let groundMinimumSpan: Double = 0.50
    public let groundConfirmationFrames = 2
    public let ledgerCapacity = 256
    /// Measured camera height above a level floor for a calibrated rig. Never inferred from user height.
    /// Nil disables floor suppression. Arbitrary handheld operation must use nil.
    public let calibratedCameraHeight: Double?
    public init(calibratedCameraHeight: Double? = nil) { self.calibratedCameraHeight = calibratedCameraHeight }
}

/// A bounded, owned copy of the source frame's depth/confidence values; safe to send to perception.
public struct DepthImage: Sendable {
    public let frame: FrameDescriptor
    public let values: [Float]
    public let confidence: [UInt8]?
    public init(frame: FrameDescriptor, values: [Float], confidence: [UInt8]?) throws {
        try frame.validate()
        guard let size = frame.depthSize, frame.depthKind != .none else { throw ContractError.invalidValue("depthUnavailable") }
        let (count, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        guard !overflow, count <= GeometryConfiguration.current.maximumDepthPixels, count == values.count,
              confidence == nil || confidence?.count == count,
              (confidence == nil) == (frame.confidenceSize == nil) else { throw ContractError.invalidValue("depthShapeOrBudget") }
        self.frame = frame; self.values = values; self.confidence = confidence
    }
}

public enum CorridorRelation: String, Codable, Sendable { case ahead, left, right, unknown }
public enum ViewRegion: String, Codable, Sendable, CaseIterable { case left, center, right }
public enum GroundRelation: String, Codable, Sendable { case raised, unclassified }
public enum DepthEvidence: String, Codable, Sendable { case confidenceBacked, confidenceUnknown }
public enum GroundStatus: String, Codable, Sendable { case unknown, candidate, confirmed }
public enum HazardDeliveryScope: String, Codable, Sendable { case research }

public struct NormalizedBounds: Codable, Sendable, Equatable {
    public let minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public var clipped: NormalizedBounds? {
        let x0 = max(0, minX), x1 = min(1, maxX), y0 = max(0, minY), y1 = min(1, maxY)
        return x1 > x0 && y1 > y0 ? NormalizedBounds(minX: x0, minY: y0, maxX: x1, maxY: y1) : nil
    }
}

public struct GeometryDetails: Codable, Sendable, Equatable {
    public let imageBounds: NormalizedBounds
    public let displayBounds: NormalizedBounds?
    public let corridor: CorridorRelation
    public let bearingRadians: Double?
    public let supportCount: Int
    public let groundRelation: GroundRelation
    public let heightAboveGroundMeters: Double?
    public let evidence: DepthEvidence
    public init(imageBounds: NormalizedBounds, displayBounds: NormalizedBounds?, corridor: CorridorRelation,
                bearingRadians: Double?, supportCount: Int, groundRelation: GroundRelation,
                heightAboveGroundMeters: Double?, evidence: DepthEvidence) {
        self.imageBounds = imageBounds; self.displayBounds = displayBounds; self.corridor = corridor
        self.bearingRadians = bearingRadians; self.supportCount = supportCount; self.groundRelation = groundRelation
        self.heightAboveGroundMeters = heightAboveGroundMeters; self.evidence = evidence
    }
}

public struct GroundEstimate: Sendable, Equatable {
    public let status: GroundStatus
    public let worldHeightMeters: Double?
    public let supportingSamples: Int
    public let reason: String
    public init(status: GroundStatus, worldHeightMeters: Double?, supportingSamples: Int, reason: String) {
        self.status = status; self.worldHeightMeters = worldHeightMeters; self.supportingSamples = supportingSamples; self.reason = reason
    }
}
public struct RegionSummary: Sendable, Equatable {
    public let region: ViewRegion
    public let sampledPixels: Int
    public let usablePixels: Int
    public let nearestRangeMeters: Double?
    public init(region: ViewRegion, sampledPixels: Int, usablePixels: Int, nearestRangeMeters: Double?) {
        self.region = region; self.sampledPixels = sampledPixels; self.usablePixels = usablePixels; self.nearestRangeMeters = nearestRangeMeters
    }
    public var coverage: Double? { sampledPixels > 0 ? Double(usablePixels) / Double(sampledPixels) : nil }
}
public struct GeometryResult: Sendable {
    public let frame: FrameDescriptor
    public let observations: [GeometryObservation]
    public let regions: [RegionSummary]
    public let ground: GroundEstimate
    public let quality: QualityAssessment
    public let discardedSmallComponents: Int
    public let advanced: AdvancedGeometryResult?
    public init(frame: FrameDescriptor, observations: [GeometryObservation], regions: [RegionSummary],
                ground: GroundEstimate, quality: QualityAssessment, discardedSmallComponents: Int, advanced: AdvancedGeometryResult? = nil) {
        self.frame = frame; self.observations = observations; self.regions = regions; self.ground = ground
        self.quality = quality; self.discardedSmallComponents = discardedSmallComponents; self.advanced = advanced
    }
}
