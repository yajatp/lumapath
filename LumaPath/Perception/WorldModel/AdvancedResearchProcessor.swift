import Foundation
import LumaPathDomain

public struct AdvancedResearchProcessor: Sendable {
    private var occupancy = RollingOccupancy()
    private var detector = AdvancedDetector()
    private var motion = MotionTracker()
    private let enabledFamilies: Set<AdvancedHazardFamily>
    public init(enabledFamilies: Set<AdvancedHazardFamily> = Set(AdvancedHazardFamily.allCases)) { self.enabledFamilies = enabledFamilies }
    public mutating func process(_ depth: DepthImage, geometry: GeometryResult, context: CaptureContext,
                                 profile: MobilityGeometryProfile = .standard, at now: Double) throws -> AdvancedGeometryResult {
        guard depth.frame == geometry.frame else { throw ContractError.invalidValue("advancedFrameMismatch") }
        let model = try occupancy.integrate(depth,context: context,at: now)
        var candidates = try detector.detect(model,ground: geometry.ground,context: context,profile: profile,at: now)
        let tracks = try motion.update(depth,geometry: geometry,context: context,profile: profile,at: now)
        for track in tracks {
            guard let encounter = track.encounterTime, let uncertainty = track.velocityUncertainty,
                  let observation = geometry.observations.first(where: { $0.id == track.observationID }) else { continue }
            candidates.append(AdvancedHazardCandidate(envelope: depth.frame.envelope,family: .movingObstacle,
                rangeMeters: observation.rangeMeters,bearingRadians: observation.details?.bearingRadians ?? 0,
                encounterTime: encounter,uncertaintyMeters: 0.05+uncertainty*encounter,
                reasons: ["cameraCompensatedAssociation","boundedVelocityUncertainty","researchOnly"]))
        }
        var reasons = ["researchOnly","sampledVolumeNotTraversability"]
        if geometry.ground.status != .confirmed { reasons.append("advancedGroundCategoriesUnavailable") }
        if PoseBasis(frame: depth.frame) == nil { reasons.append("worldModelAndMotionUnavailable") }
        if depth.confidence == nil { reasons.append("advancedConfidenceUnavailable") }
        if model.truncated { reasons.append("occupancyBudgetExceeded") }
        let gates = FeatureActivation.researchOnly.map {
            FeatureActivation(family: $0.family,researchAvailable: enabledFamilies.contains($0.family),
                reasons: enabledFamilies.contains($0.family) ? $0.reasons : ["categoryDisabled"])
        }
        return AdvancedGeometryResult(occupancy: model,candidates: candidates.filter { enabledFamilies.contains($0.family) },tracks: tracks,
            activations: gates,reasons: reasons)
    }
}
