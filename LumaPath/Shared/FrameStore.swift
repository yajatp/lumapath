import Foundation

/// Holds at most capacity values. Leases are IDs, not owning references; eviction invalidates them.
@MainActor public final class FrameStore<Value> {
    private var entries: [(FrameID, Value)] = []
    public let capacity: Int
    public init(capacity: Int = CaptureConfiguration.current.maximumRetainedFrames) {
        precondition(capacity > 0 && capacity <= CaptureConfiguration.current.maximumRetainedFrames)
        self.capacity = capacity
    }
    public var count: Int { entries.count }
    public func insert(_ value: Value, for id: FrameID) {
        entries.removeAll { $0.0 == id }
        entries.append((id, value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
    public func withValue(for id: FrameID, _ body: (Value) -> Void) -> Bool {
        guard let entry = entries.first(where: { $0.0 == id }) else { return false }
        body(entry.1)
        return true
    }
    public func removeAll() { entries.removeAll(keepingCapacity: true) }
}

/// Called independently of capture callbacks. Fires once per outage; recovery requires a fresh frame.
public struct FreshnessWatchdog: Sendable {
    private var lastInput: TimeInterval
    private var reported = false
    public init(startedAt: TimeInterval) { lastInput = startedAt }
    public mutating func received(at time: TimeInterval) { lastInput = time; reported = false }
    public mutating func check(at time: TimeInterval, timeout: TimeInterval = CaptureConfiguration.current.missingFrameInterval) -> Bool {
        guard !reported, time - lastInput >= timeout else { return false }
        reported = true
        return true
    }
}
