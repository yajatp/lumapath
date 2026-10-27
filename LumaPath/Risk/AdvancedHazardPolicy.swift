import Foundation
import LumaPathDomain

public enum AdvancedHazardPolicy {
    public static func evaluate(_ result: AdvancedGeometryResult, context: CaptureContext,
                                profile: MobilityGeometryProfile = .standard, at now: Double) -> [HazardEvent] {
        result.candidates.compactMap { candidate in
            guard candidate.envelope.frameID == result.occupancy.frame.envelope.frameID,
                  candidate.envelope.isCurrent(in: context,at: now), candidate.rangeMeters.isFinite,
                  candidate.rangeMeters > 0, candidate.bearingRadians.isFinite,
                  candidate.uncertaintyMeters.isFinite, candidate.uncertaintyMeters >= 0,
                  result.activations.contains(where: { $0.family == candidate.family && $0.researchAvailable }) else { return nil }
            let encounter = candidate.encounterTime
            let urgent = candidate.rangeMeters <= 1 || encounter.map { $0.isFinite && $0 > 0 && $0 <= 1.5 } == true
            let earlyFamily = candidate.family == .overhead || candidate.family == .stepDown
            let warning = earlyFamily || candidate.rangeMeters <= (profile.earlierNotice ? 3 : 2)
                || encounter.map { $0.isFinite && $0 > 0 && $0 <= (profile.earlierNotice ? 5 : 3) } == true
            let e = candidate.envelope
            return HazardEvent(id: UUID(),envelope: ObservationEnvelope(frameID: e.frameID,mode: e.sourceMode,
                capturedAt: e.captureTimeMonotonic,createdAt: now,lifetime: e.expiresAtMonotonic-e.captureTimeMonotonic),
                geometryIDs: [],urgency: urgent ? .urgent : (warning ? .warning : .information),
                messageKey: "candidate.\(candidate.family.rawValue)",rangeMeters: candidate.rangeMeters,
                bearingRadians: candidate.bearingRadians,evidenceReasons: candidate.reasons,
                deliveryScope: .research,advancedCandidateID: candidate.id)
        }
    }
}
