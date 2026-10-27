import Foundation
import LumaPathDomain
import LumaPathPerception

public struct GeometrySnapshot: Sendable {
    public let geometry: GeometryResult
    /// This copy is for display. Feedback must read/acknowledge the separate ledger.
    public let events: [HazardEvent]
}

@MainActor public final class GeometryPipeline {
    public let ledger: HazardEventLedger
    private let configuration: GeometryConfiguration
    private let advancedResearch: Bool
    private let profile: MobilityGeometryProfile
    private let clock: any MonotonicClock
    private var engine: PerceptionEngine
    private let policy: HazardPolicy
    private var context: CaptureContext?
    private var runID: UUID?
    private var processingRunID: UUID?
    private var lastSequence: UInt64?
    public init(configuration: GeometryConfiguration = .current,advancedResearch: Bool = false,profile: MobilityGeometryProfile = .standard,clock: any MonotonicClock = SystemMonotonicClock()) {
        self.configuration = configuration; self.clock = clock; self.advancedResearch = advancedResearch; self.profile = profile
        engine = PerceptionEngine(configuration: configuration); policy = HazardPolicy(configuration: configuration)
        ledger = HazardEventLedger(capacity: configuration.ledgerCapacity)
    }
    public func start(context: CaptureContext) {
        stop(); self.context = context; runID = UUID(); lastSequence = nil
        engine = PerceptionEngine(configuration: configuration)
        ledger.start(context: context)
    }
    public func stop() { runID = nil; context = nil; lastSequence = nil; ledger.stop() }
    public func expire() { ledger.expire(at: clock.now()) }
    public func process(_ depth: DepthImage, image: LumaImage? = nil) async throws -> GeometrySnapshot? {
        guard let context, let token = runID, processingRunID != token,
              depth.frame.envelope.isCurrent(in: context,at: clock.now()),
              lastSequence.map({ depth.frame.envelope.frameID.sequence > $0 }) ?? true else { return nil }
        processingRunID = token
        defer { if processingRunID == token { processingRunID = nil } }
        let result = try await engine.process(depth,image: image,advancedResearch: advancedResearch,profile: profile,context: context,at: clock.now())
        try Task.checkCancellation()
        guard runID == token, result.frame.envelope.isCurrent(in: context,at: clock.now()) else { return nil }
        var events = policy.evaluate(result,context: context,at: clock.now())
        if let advanced = result.advanced { events += AdvancedHazardPolicy.evaluate(advanced,context: context,profile: profile,at: clock.now()) }
        lastSequence = depth.frame.envelope.frameID.sequence
        try ledger.append(events,context: context,at: clock.now())
        // A synchronous consumer hook may pause/end while events are being appended.
        guard runID == token else { return nil }
        return GeometrySnapshot(geometry: result,events: events)
    }
}
