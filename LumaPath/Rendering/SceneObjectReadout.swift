import Foundation
import LumaPathDomain

public struct SceneObjectReadout: Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let imageBounds: NormalizedBounds
    public let rangeMeters: Double?
    public let envelope: ObservationEnvelope
    public let rangeReasons: [String]
    public var text: String {
        "\(label.capitalized) — " + (rangeMeters.map { String(format: "about %.1f meters to the visible surface", $0) } ?? "distance unknown")
    }
}

/// Conservative short-lived box association for display hysteresis, never a physical identity guarantee.
public struct SceneObjectReadoutTracker: Sendable {
    private var previous: [SceneObjectReadout] = []
    private var previousFrame: FrameDescriptor?
    private var distances = StableDistanceReadout()
    public init() {}
    public mutating func reset() { previous = []; previousFrame = nil; distances.reset() }
    public mutating func update(batch: SemanticBatch, associations: [DepthAssociation], context: CaptureContext, at now: Double) -> [SceneObjectReadout] {
        guard batch.schemaVersion == 1, batch.frame.envelope.isCurrent(in: context, at: now),
              (try? batch.frame.validate()) != nil else { reset(); return [] }
        if let old = previousFrame, old.envelope.isCurrent(in: context, at: now),
           batch.frame.envelope.frameID.sequence <= old.envelope.frameID.sequence { return [] }
        let mayMatch = previousFrame.map { old in
            old.envelope.isCurrent(in: context, at: now) && old.orientation == batch.frame.orientation
                && old.tracking == .normal && batch.frame.tracking == .normal
                && Self.poseNear(old.cameraToWorld, batch.frame.cameraToWorld)
        } ?? false
        let candidates = mayMatch ? previous.filter { $0.envelope.isCurrent(in: context, at: now) } : []
        let order = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) })
        var used = Set<UUID>(), next: [SceneObjectReadout] = []
        let observations = batch.observations.filter {
            $0.envelope == batch.frame.envelope && $0.modelID == batch.modelID && $0.modelVersion == batch.modelVersion
                && $0.source == .currentCamera && $0.visualContextConfirmed && $0.labelScore.isFinite && (0.6...1).contains($0.labelScore)
                && $0.imageBounds.clipped == $0.imageBounds && $0.text?.isEmpty == false && ($0.text?.count ?? 100) <= 40
        }.sorted { $0.labelScore > $1.labelScore }.prefix(16)
        for observation in observations {
            let matches = candidates.filter { $0.label == observation.text && !used.contains($0.id) }
                .map { ($0, Self.iou($0.imageBounds, observation.imageBounds)) }.filter { $0.1 >= 0.6 }.sorted { $0.1 > $1.1 }
            // Ambiguous same-class matches start a new readout; do not borrow another object's history.
            let match = matches.count == 1 || (matches.count > 1 && matches[0].1 - matches[1].1 > 0.15) ? matches.first?.0 : nil
            let id = match?.id ?? UUID(); used.insert(id)
            let paired = associations.filter { $0.observationID == observation.id && $0.frameID == observation.envelope.frameID }
            let association = paired.count == 1 ? paired[0] : nil
            let range = distances.update(key: id.uuidString, rangeMeters: batch.frame.tracking == .normal ? association?.rangeMeters : nil,
                envelope: observation.envelope, context: context, at: now)
            next.append(SceneObjectReadout(id: id, label: observation.text!, imageBounds: observation.imageBounds,
                rangeMeters: range, envelope: observation.envelope, rangeReasons: association?.reasons ?? ["depthAssociationUnavailable"]))
        }
        // One detector miss must not blank a still-current observation. Keep its own source
        // deadline; never stamp it with this newer frame. Conflicting classes remove history.
        let held = candidates.filter { old in
            !used.contains(old.id) && !next.contains { $0.label == old.label || Self.iou(old.imageBounds, $0.imageBounds) >= 0.4 }
        }
        next.append(contentsOf: held)
        next.sort {
            if let a = order[$0.id], let b = order[$1.id] { return a < b }
            if order[$0.id] != nil { return true }
            if order[$1.id] != nil { return false }
            return ($0.rangeMeters ?? .infinity) < ($1.rangeMeters ?? .infinity)
        }
        previous = next; previousFrame = batch.frame
        return next
    }
    private static func poseNear(_ lhs: [Double]?, _ rhs: [Double]?) -> Bool {
        guard let lhs, let rhs, lhs.count == 16, rhs.count == 16,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return false }
        // Bounded translation and rotation; never match across a substantial camera move.
        let translation = sqrt((12...14).reduce(0.0) { $0 + pow(lhs[$1] - rhs[$1], 2) })
        let rotation = [0,1,2,4,5,6,8,9,10].map { abs(lhs[$0] - rhs[$0]) }.max() ?? 1
        return translation <= 0.10 && rotation <= 0.08
    }
    private static func iou(_ a: NormalizedBounds, _ b: NormalizedBounds) -> Double {
        let overlap = max(0, min(a.maxX,b.maxX) - max(a.minX,b.minX)) * max(0, min(a.maxY,b.maxY) - max(a.minY,b.minY))
        let union = (a.maxX-a.minX)*(a.maxY-a.minY) + (b.maxX-b.minX)*(b.maxY-b.minY) - overlap
        return union > 0 ? overlap/union : 0
    }
}
