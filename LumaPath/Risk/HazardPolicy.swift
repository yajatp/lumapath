import Foundation
import LumaPathDomain

/// Generic obstacle relevance only. No steps, overhead, motion, free-space, or traversability claims.
public struct HazardPolicy: Sendable {
    private let configuration: GeometryConfiguration
    public init(configuration: GeometryConfiguration = .current) { self.configuration = configuration }
    public func evaluate(_ result: GeometryResult, context: CaptureContext, at now: TimeInterval) -> [HazardEvent] {
        guard result.frame.envelope.isCurrent(in: context,at: now) else { return [] }
        return result.observations.compactMap { observation in
            guard let details = observation.details, observation.rangeMeters.isFinite, observation.rangeMeters > 0,
                  observation.envelope.isCurrent(in: context,at: now),
                  observation.envelope.frameID == result.frame.envelope.frameID else { return nil }
            let close = observation.rangeMeters <= configuration.urgentRange
            let urgency: HazardUrgency
            switch details.corridor {
            case .ahead, .unknown: urgency = close ? .urgent : .warning
            case .left, .right: urgency = close ? .warning : .information
            }
            let original = observation.envelope
            let envelope = ObservationEnvelope(frameID: original.frameID,mode: original.sourceMode,
                capturedAt: original.captureTimeMonotonic,createdAt: now,
                lifetime: original.expiresAtMonotonic-original.captureTimeMonotonic)
            return HazardEvent(id: UUID(),envelope: envelope,geometryIDs: [observation.id],urgency: urgency,
                messageKey: "obstacle.\(details.corridor.rawValue)",corridor: details.corridor,rangeMeters: observation.rangeMeters,
                bearingRadians: details.bearingRadians,
                evidenceReasons: [details.evidence.rawValue,details.groundRelation.rawValue,"unvalidatedGeometry"],deliveryScope: .research)
        }
    }
}
