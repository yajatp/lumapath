import Foundation
import LumaPathDomain

/// Only nonurgent, producer-validated observations belong here. Hazards have no representation.
public struct AttentionCandidate: Sendable {
    public let id: UUID
    public let envelope: ObservationEnvelope
    public let target: GoalTarget
    public let source: ObservationSource
    public let informationKey: String
    public let bearing: Double?
    public let distance: Double?
    public init(id: UUID, envelope: ObservationEnvelope, target: GoalTarget, source: ObservationSource,
                informationKey: String, bearing: Double? = nil, distance: Double? = nil) {
        self.id = id; self.envelope = envelope; self.target = target; self.source = source
        self.informationKey = informationKey; self.bearing = bearing; self.distance = distance
    }
}

public struct LocalAttention: Sendable {
    private var context: CommandReviewContext?
    private var history: [String: Double] = [:]
    private var lastAnnouncement: Double?
    private var lastNow: Double = 0
    public init() {}
    public mutating func bind(_ context: CommandReviewContext) {
        guard self.context != context else { return }
        self.context = context; history = [:]; lastAnnouncement = nil; lastNow = 0
    }
    public mutating func reset() { context = nil; history = [:]; lastAnnouncement = nil; lastNow = 0 }
    /// A decision consumes a session budget slot, even if output subsequently becomes unavailable.
    /// Rechecking the original envelope at playback is still required.
    public mutating func select(_ candidates: [AttentionCandidate], target: GoalTarget,
        context: CommandReviewContext, interval: Double, at now: Double) -> UUID? {
        guard self.context == context, context.goalRevision != nil, now.isFinite, now >= lastNow,
              interval.isFinite, (5...30).contains(interval) else { return nil }
        lastNow = now
        history = history.filter { now - $0.value < 30 }
        guard lastAnnouncement.map({ now - $0 >= interval }) ?? true else { return nil }
        let supported = candidates.prefix(64).filter {
            $0.target == target && $0.source != .remoteHypothesis
            && $0.envelope.isCurrent(in: context.capture, at: now)
            && !$0.informationKey.isEmpty && $0.informationKey.count <= 128
            && ($0.bearing.map { $0.isFinite && abs($0) <= .pi } ?? true)
            && ($0.distance.map { $0.isFinite && $0 > 0 } ?? true)
        }.sorted { a, b in
            func sourceRank(_ source: ObservationSource) -> Int {
                switch source { case .currentCamera: 0; case .rememberedLandmark: 1; case .map: 2; case .remoteHypothesis: 3 }
            }
            if sourceRank(a.source) != sourceRank(b.source) { return sourceRank(a.source) < sourceRank(b.source) }
            let aNew = history[a.informationKey] == nil, bNew = history[b.informationKey] == nil
            if aNew != bNew { return aNew }
            if abs(a.bearing ?? .infinity) != abs(b.bearing ?? .infinity) { return abs(a.bearing ?? .infinity) < abs(b.bearing ?? .infinity) }
            if a.distance != b.distance { return (a.distance ?? .infinity) < (b.distance ?? .infinity) }
            return a.id.uuidString < b.id.uuidString
        }
        guard let chosen = supported.first, history[chosen.informationKey] == nil else { return nil }
        if history.count >= 64, let oldest = history.min(by: { $0.value < $1.value })?.key { history.removeValue(forKey: oldest) }
        history[chosen.informationKey] = now; lastAnnouncement = now
        return chosen.id
    }
}
