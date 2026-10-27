import Foundation
import LumaPathDomain

public enum SemanticMeaning: String, Sendable { case obstacle, floor, doorway, exit }
/// A6 supplies actual licensed models and association. A label alone cannot supply range.
public struct SemanticEvidence: Sendable {
    public let envelope: ObservationEnvelope
    public let meaning: SemanticMeaning
    public let associatedGeometryID: UUID?
    public init(envelope: ObservationEnvelope, meaning: SemanticMeaning, associatedGeometryID: UUID? = nil) {
        self.envelope = envelope; self.meaning = meaning; self.associatedGeometryID = associatedGeometryID
    }
}
public struct DisagreementDecision: Sendable {
    public let retainedGeometryIDs: [UUID]
    public let reasons: [String]
    public let worldDependentFunctionsSupported: Bool
}

/// Describes disagreements without filtering credible geometry or creating clearance/distance claims.
public enum DisagreementPolicy {
    public static func evaluate(_ result: GeometryResult, labels: [SemanticEvidence],
                                context: CaptureContext, at now: TimeInterval) -> DisagreementDecision {
        guard result.frame.envelope.isCurrent(in: context,at: now) else {
            return DisagreementDecision(retainedGeometryIDs: [],reasons: ["staleGeometry"],worldDependentFunctionsSupported: false)
        }
        let geometry = result.observations.filter {
            $0.envelope.frameID == result.frame.envelope.frameID && $0.envelope.isCurrent(in: context,at: now)
        }
        let freshLabels = labels.filter {
            $0.envelope.frameID == result.frame.envelope.frameID && $0.envelope.isCurrent(in: context,at: now)
        }
        var reasons: [String] = []
        if !geometry.isEmpty && freshLabels.isEmpty { reasons.append("genericGeometryWithoutLabel") }
        for label in freshLabels {
            let associated = geometry.first { $0.id == label.associatedGeometryID }
            if associated == nil { reasons.append("labelDistanceUnknown") }
            if label.meaning == .floor, associated?.details?.groundRelation == .raised { reasons.append("floorLabelConflictsWithRaisedGeometry") }
            if label.meaning == .doorway || label.meaning == .exit { reasons.append("candidateTraversabilityUnknown") }
        }
        if result.quality.details?.regions.contains(where: { $0.coverage == .sparse || $0.coverage == .unknown }) == true {
            reasons.append("unobservedRegionNotClearOrHole")
        }
        if result.quality.details?.regions.contains(where: { $0.temporalRangeChanged == true }) == true {
            reasons.append("geometryChangedAssociationUnknown")
        }
        if PoseBasis(frame: result.frame) == nil { reasons.append("worldMemoryAndPredictionDisabled") }
        var seen = Set<String>()
        return DisagreementDecision(retainedGeometryIDs: geometry.map(\.id),reasons: reasons.filter { seen.insert($0).inserted },
            worldDependentFunctionsSupported: PoseBasis(frame: result.frame) != nil)
    }
}
