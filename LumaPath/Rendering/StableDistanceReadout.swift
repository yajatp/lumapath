import Foundation
import LumaPathDomain

/// Presentation hysteresis only. Never feed these rounded values into hazard evaluation.
/// The caller supplies a stable identity; a region key represents a region, not a named object.
public struct StableDistanceReadout: Sendable {
    private struct Entry: Sendable {
        let value: Double
        let envelope: ObservationEnvelope
        let changedAt: TimeInterval
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public mutating func reset() { entries.removeAll() }

    public mutating func update(key: String, rangeMeters: Double?, envelope: ObservationEnvelope,
                                context: CaptureContext, at now: TimeInterval) -> Double? {
        entries = entries.filter { $0.value.envelope.isCurrent(in: context, at: now) }
        guard context.mode == .liveDepth, !key.isEmpty, key.count <= 128, envelope.isCurrent(in: context, at: now),
              let range = rangeMeters, range.isFinite, (0.3...4).contains(range) else {
            entries.removeValue(forKey: key); return nil
        }
        let previous = entries[key]
        if let previous, envelope.frameID.sequence <= previous.envelope.frameID.sequence { return nil }
        var displayed = (range / 0.2).rounded() * 0.2
        // A closer transition across the urgent boundary must never be delayed by display hysteresis.
        if range < 1, displayed >= 1 || (previous?.value ?? 0) >= 1 {
            displayed = max(0.3, floor(range / 0.2) * 0.2)
        } else if let previous {
            // Schmitt band wider than half a display bucket prevents boundary chatter.
            // Throttle cosmetic changes, but a substantially closer surface updates immediately.
            let closer = range <= previous.value - 0.5
            if !closer && (abs(range - previous.value) < 0.20 || now - previous.changedAt < 0.25) {
                displayed = previous.value
            }
        }
        if entries[key] == nil, entries.count >= 64 { return nil }
        entries[key] = Entry(value: displayed, envelope: envelope,
            changedAt: previous?.value == displayed ? previous!.changedAt : now)
        return displayed
    }
}
