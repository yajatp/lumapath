import Foundation

public struct OpticalPoint: Codable, Sendable, Equatable {
    public let x: Double, y: Double, z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public var range: Double { (x*x + y*y + z*z).squareRoot() }
    /// Optical: +X right, +Y down, +Z forward. ARKit: +X right, +Y up, -Z forward.
    public var arKitCameraPoint: SIMD3<Double> { SIMD3(x, -y, -z) }
}

public enum FrameGeometry {
    /// Returns nil for missing/invalid calibration or nonpositive/nonfinite axial depth.
    public static func unproject(u: Double, v: Double, axialDepth: Double, frame: FrameDescriptor) -> OpticalPoint? {
        guard (try? frame.validate()) != nil, let size = frame.depthSize, let intrinsics = frame.intrinsics,
              axialDepth.isFinite, axialDepth > 0, u.isFinite, v.isFinite,
              u >= 0, v >= 0, u < Double(size.width), v < Double(size.height) else { return nil }
        let k = intrinsics.scaled(from: frame.imageSize, to: size)
        return OpticalPoint(x: (u-k.cx)*axialDepth/k.fx, y: (v-k.cy)*axialDepth/k.fy, z: axialDepth)
    }
}

public enum SensingQuality: String, Codable, Sendable { case initializing, active, limited, unavailable }
public struct QualityAssessment: Codable, Sendable, Equatable {
    public let state: SensingQuality
    public let reasons: [String]
    /// Unknown coverage stays nil; regional details are additive for older replay fixtures.
    public let usableDepthFraction: Double?
    public let details: QualityDetails?
    public init(state: SensingQuality, reasons: [String], usableDepthFraction: Double? = nil, details: QualityDetails? = nil) {
        self.state = state; self.reasons = reasons; self.usableDepthFraction = usableDepthFraction; self.details = details
    }
}

public struct GeometryObservation: Codable, Sendable, Equatable {
    public let id: UUID
    public let envelope: ObservationEnvelope
    public let opticalPoint: OpticalPoint
    public let axialDepthMeters: Double
    public let rangeMeters: Double
    public let details: GeometryDetails?
    public init(id: UUID, envelope: ObservationEnvelope, opticalPoint: OpticalPoint,
                axialDepthMeters: Double, rangeMeters: Double, details: GeometryDetails? = nil) {
        self.id = id; self.envelope = envelope; self.opticalPoint = opticalPoint
        self.axialDepthMeters = axialDepthMeters; self.rangeMeters = rangeMeters; self.details = details
    }
}
public enum HazardUrgency: String, Codable, Sendable { case information, warning, urgent }
public struct HazardEvent: Codable, Sendable, Equatable {
    public let id: UUID
    public let envelope: ObservationEnvelope
    public let geometryIDs: [UUID]
    public let urgency: HazardUrgency
    public let messageKey: String
    public let corridor: CorridorRelation?
    public let rangeMeters: Double?
    public let bearingRadians: Double?
    public let evidenceReasons: [String]?
    public let deliveryScope: HazardDeliveryScope?
    public let advancedCandidateID: UUID?
    public init(id: UUID, envelope: ObservationEnvelope, geometryIDs: [UUID], urgency: HazardUrgency, messageKey: String,
                corridor: CorridorRelation? = nil, rangeMeters: Double? = nil, bearingRadians: Double? = nil,
                evidenceReasons: [String]? = nil, deliveryScope: HazardDeliveryScope? = nil, advancedCandidateID: UUID? = nil) {
        self.id = id; self.envelope = envelope; self.geometryIDs = geometryIDs
        self.urgency = urgency; self.messageKey = messageKey
        self.corridor = corridor; self.rangeMeters = rangeMeters; self.bearingRadians = bearingRadians
        self.evidenceReasons = evidenceReasons; self.deliveryScope = deliveryScope; self.advancedCandidateID = advancedCandidateID
    }
}
