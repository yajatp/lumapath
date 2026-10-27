import Foundation
import LumaPathDomain

public enum EventLedgerError: Error, Equatable {
    case inactiveContext
    case invalidEvent
    /// The existing pending batch is preserved. Caller must handle backpressure; no silent eviction.
    case capacityExceeded(rejectedEvents: [HazardEvent])
}

/// Authoritative pending event path, independent of newest-only presentation snapshots.
@MainActor public final class HazardEventLedger {
    public var onEventsAvailable: (@MainActor (CaptureContext) -> Void)?
    private var context: CaptureContext?
    private var entries: [HazardEvent] = []
    private var acknowledged: [UUID: TimeInterval] = [:]
    private let capacity: Int
    public init(capacity: Int = GeometryConfiguration.current.ledgerCapacity) {
        precondition(capacity > 0 && capacity <= GeometryConfiguration.current.ledgerCapacity)
        self.capacity = capacity
    }
    public func start(context: CaptureContext) { clear(); self.context = context }
    public func stop() { context = nil; clear() }
    private func clear() { entries.removeAll(keepingCapacity: true); acknowledged.removeAll(keepingCapacity: true) }
    public func expire(at now: TimeInterval) {
        guard let context else { clear(); return }
        entries.removeAll { !$0.envelope.isCurrent(in: context,at: now) }
        acknowledged = acknowledged.filter { $0.value > now }
    }
    public func pending(at now: TimeInterval) -> [HazardEvent] {
        expire(at: now)
        func rank(_ urgency: HazardUrgency) -> Int { switch urgency { case .urgent: 0; case .warning: 1; case .information: 2 } }
        return entries.sorted {
            if rank($0.urgency) != rank($1.urgency) { return rank($0.urgency) < rank($1.urgency) }
            return $0.envelope.captureTimeMonotonic < $1.envelope.captureTimeMonotonic
        }
    }
    public func append(_ events: [HazardEvent], context expected: CaptureContext, at now: TimeInterval) throws {
        guard context == expected else { throw EventLedgerError.inactiveContext }
        expire(at: now)
        guard events.allSatisfy({ $0.envelope.isCurrent(in: expected,at: now) && $0.deliveryScope == .research
            && (!$0.geometryIDs.isEmpty || $0.advancedCandidateID != nil) && ($0.rangeMeters?.isFinite == true) && ($0.rangeMeters ?? 0) > 0 }) else {
            throw EventLedgerError.invalidEvent
        }
        guard events.allSatisfy({ event in entries.first(where: { $0.id == event.id }).map { $0 == event } ?? true }) else {
            throw EventLedgerError.invalidEvent
        }
        var seen = Set(entries.map(\.id)); seen.formUnion(acknowledged.keys)
        let additions = events.filter { seen.insert($0.id).inserted }
        // Tombstones are bounded too: acknowledgments cannot create an unbounded history.
        guard entries.count+acknowledged.count+additions.count <= capacity else {
            throw EventLedgerError.capacityExceeded(rejectedEvents: additions)
        }
        entries.append(contentsOf: additions)
        if !additions.isEmpty { onEventsAvailable?(expected) }
    }
    @discardableResult public func acknowledge(_ id: UUID, context expected: CaptureContext, at now: TimeInterval) -> Bool {
        guard context == expected else { return false }
        expire(at: now)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        acknowledged[id] = entries[index].envelope.expiresAtMonotonic
        entries.remove(at: index)
        return true
    }
}
