import Foundation

public enum ResourcePressure: Int, Sendable, Comparable {
    case nominal, elevated, serious, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public enum PerformancePreset: String, Sendable { case balanced, lean }
public struct ResourceDecision: Equatable, Sendable {
    public let preset: PerformancePreset
    public let suspended: Bool
    public let reason: String
    public init(preset: PerformancePreset, suspended: Bool, reason: String) {
        self.preset = preset; self.suspended = suspended; self.reason = reason
    }
    public var allowsExpensiveEffects: Bool { preset == .balanced && !suspended }
}

/// Provisional thresholds. Degrades immediately and requires 30 continuous healthy seconds to restore effects.
/// A critical stop never restarts a capture session; the user must explicitly Start again.
public struct ResourcePolicy: Sendable {
    public private(set) var decision = ResourceDecision(preset: .balanced, suspended: false, reason: "balanced")
    private var healthySince: TimeInterval?
    private var lastTime: TimeInterval?
    public init() {}
    @discardableResult public mutating func update(thermal: ResourcePressure, capture: ResourcePressure,
        lowPower: Bool, memoryWarning: Bool = false, latencyExceeded: Bool = false, at now: TimeInterval) -> ResourceDecision {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else { return decision }
        lastTime = now
        let pressure = max(thermal, capture)
        if pressure == .critical {
            healthySince = nil
            decision = ResourceDecision(preset: .lean, suspended: true, reason: "criticalPressure")
        } else if decision.suspended {
            // Low-power preference reduces effects; it must not prevent recovery forever.
            if pressure == .nominal && !memoryWarning && !latencyExceeded {
                if healthySince == nil { healthySince = now }
                if now - healthySince! >= 30 {
                    decision = ResourceDecision(preset: lowPower ? .lean : .balanced, suspended: false,
                                                reason: lowPower ? "lowPower" : "balanced")
                    healthySince = nil
                }
            } else { healthySince = nil }
        } else if pressure >= .elevated || lowPower || memoryWarning || latencyExceeded {
            healthySince = nil
            decision = ResourceDecision(preset: .lean, suspended: decision.suspended,
                reason: memoryWarning ? "memoryWarning" : lowPower ? "lowPower" : latencyExceeded ? "latencyBudget" : "resourcePressure")
        } else if decision.preset == .lean {
            if healthySince == nil { healthySince = now }
            if now - healthySince! >= 30 {
                decision = ResourceDecision(preset: .balanced, suspended: false, reason: "balanced")
                healthySince = nil
            }
        }
        return decision
    }
}

/// Fixed-memory rolling render latency. These samples are diagnostics, not device acceptance evidence.
public struct LatencyWindow: Sendable {
    private var milliseconds: [Double] = []
    public private(set) var totalSamples = 0
    public private(set) var rejectedSamples = 0
    public init() {}
    public var retainedSamples: Int { milliseconds.count }
    public mutating func record(seconds: TimeInterval, accepted: Bool) {
        guard seconds.isFinite, seconds >= 0 else { return }
        totalSamples += 1
        if !accepted { rejectedSamples += 1 }
        if milliseconds.count == 256 { milliseconds.removeFirst() }
        milliseconds.append(seconds * 1000)
    }
    public func percentile(_ fraction: Double) -> Double? {
        guard fraction.isFinite, (0...1).contains(fraction), !milliseconds.isEmpty else { return nil }
        let sorted = milliseconds.sorted()
        return sorted[max(0, Int(ceil(fraction * Double(sorted.count))) - 1)]
    }
}

/// Per-run producer diagnostics. Counters start after permission and stop with capture.
/// Driver callbacks exclude frames coalesced inside SDK/driver mailboxes and hardware drops.
public struct CaptureDiagnostics: Sendable {
    public enum Outcome: Sendable { case invalid, throttled, published, replacedPending }
    public let startedAt: TimeInterval
    public private(set) var endedAt: TimeInterval?
    public private(set) var callbacks = 0
    public private(set) var invalidFrames = 0
    public private(set) var throttledFrames = 0
    public private(set) var publishedFrames = 0
    public private(set) var replacedPendingFrames = 0
    public private(set) var firstPublishedSeconds: TimeInterval?
    public private(set) var publicationAge = LatencyWindow()
    private var lastTime: TimeInterval

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt; lastTime = startedAt
    }
    public mutating func record(_ outcome: Outcome, capturedAt: TimeInterval, at now: TimeInterval) {
        guard endedAt == nil, startedAt.isFinite, startedAt >= 0,
              now.isFinite, now >= lastTime else { return }
        lastTime = now; callbacks += 1
        switch outcome {
        case .invalid: invalidFrames += 1
        case .throttled: throttledFrames += 1
        case .published, .replacedPending:
            publishedFrames += 1
            if case .replacedPending = outcome { replacedPendingFrames += 1 }
            if firstPublishedSeconds == nil { firstPublishedSeconds = now - startedAt }
            if capturedAt.isFinite, capturedAt >= startedAt, capturedAt <= now {
                publicationAge.record(seconds: now - capturedAt, accepted: true)
            }
        }
    }
    public mutating func stop(at now: TimeInterval) {
        guard endedAt == nil, now.isFinite, now >= lastTime else { return }
        endedAt = now
    }
    /// Includes startup and outages in the denominator; this is producer publication rate, not display fps.
    public func publicationFPS(at now: TimeInterval) -> Double? {
        let end = endedAt ?? now
        guard startedAt.isFinite, startedAt >= 0, end.isFinite, end >= lastTime, end > startedAt else { return nil }
        return Double(publishedFrames) / (end - startedAt)
    }
}
