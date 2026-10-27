import Foundation
import LumaPathDomain
import LumaPathPerception

public enum QualityLedgerError: Error, Equatable { case inactiveContext, invalidEvent, capacityExceeded }

/// Bounded acknowledgments and backpressure, separate from geometry-only hazard events.
@MainActor public final class QualityLimitationLedger {
    public var onEventsAvailable: (@MainActor (CaptureContext) -> Void)?
    private var context: CaptureContext?
    private var entries: [QualityLimitationEvent] = []
    private var acknowledged: [UUID: TimeInterval] = [:]
    private let capacity: Int
    public init(capacity: Int = 64) { precondition((1...64).contains(capacity)); self.capacity = capacity }
    public func start(context: CaptureContext) { stop(); self.context = context }
    public func stop() { context = nil; entries.removeAll(); acknowledged.removeAll() }
    public func pending(at now: TimeInterval) -> [QualityLimitationEvent] {
        guard let context else { return [] }
        entries.removeAll { !$0.isCurrent(in: context, at: now) }
        acknowledged = acknowledged.filter { $0.value > now }
        return entries
    }
    public func append(_ event: QualityLimitationEvent, context: CaptureContext, at now: TimeInterval) throws {
        guard self.context == context else { throw QualityLedgerError.inactiveContext }
        _ = pending(at: now)
        guard event.isCurrent(in: context, at: now) else { throw QualityLedgerError.invalidEvent }
        if let existing = entries.first(where: { $0.id == event.id }) {
            guard existing == event else { throw QualityLedgerError.invalidEvent }; return
        }
        guard acknowledged[event.id] == nil else { return }
        guard entries.count + acknowledged.count < capacity else { throw QualityLedgerError.capacityExceeded }
        entries.append(event); onEventsAvailable?(context)
    }
    @discardableResult public func acknowledge(_ id: UUID, context: CaptureContext, at now: TimeInterval) -> Bool {
        guard self.context == context else { return false }
        _ = pending(at: now)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        acknowledged[id] = entries.remove(at: index).expiresAt; return true
    }
}

/// Shared session quality works without depth or Research geometry activation. No camera or raw retention.
@MainActor public final class QualitySessionPipeline {
    public let ledger = QualityLimitationLedger()
    public var onSnapshot: (@MainActor (SessionSnapshot?) -> Void)?
    public var snapshot: SessionSnapshot? { state?.snapshot }
    private var state: SessionState?
    private var engine = QualityAssessmentEngine()
    private var runID: UUID?
    private var processingRunID: UUID?
    private var previousReasons: [SensingLimitation]?
    private let clock: any MonotonicClock
    public init(clock: any MonotonicClock = SystemMonotonicClock()) { self.clock = clock }
    public func start(context: CaptureContext) {
        stop(); state = SessionState(activeContext: context); runID = UUID()
        engine = QualityAssessmentEngine(); ledger.start(context: context); onSnapshot?(snapshot)
    }
    public func stop() {
        runID = nil; state = nil; previousReasons = nil; ledger.stop(); onSnapshot?(nil)
    }
    @discardableResult public func process(frame: FrameDescriptor, depth: DepthImage?, image: LumaImage?) async throws -> SessionSnapshot? {
        guard let context = state?.context, let token = runID, processingRunID != token,
              state?.canAcceptFrame(frame, at: clock.now()) == true else { return nil }
        processingRunID = token
        defer { if processingRunID == token { processingRunID = nil } }
        let quality = try await engine.evaluate(frame: frame, depth: depth, image: image, context: context, at: clock.now())
        try Task.checkCancellation()
        guard runID == token, state?.accept(frame, quality: quality, at: clock.now()) == true else { return nil }
        try transition(quality, source: frame.envelope, context: context)
        guard runID == token else { return nil }
        onSnapshot?(snapshot)
        return runID == token ? snapshot : nil
    }
    /// Call from the capture watchdog/renderer on loss; this invalidates in-flight recovery.
    public func markUnavailable() throws {
        guard let context = state?.context, runID != nil else { return }
        runID = UUID(); engine = QualityAssessmentEngine()
        state?.markUnavailable(reason: SensingLimitation.inputUnavailable.rawValue)
        try transition(QualityAssessment(state: .unavailable, reasons: [SensingLimitation.inputUnavailable.rawValue]), source: nil, context: context)
        onSnapshot?(snapshot)
    }
    private func transition(_ quality: QualityAssessment, source: ObservationEnvelope?, context: CaptureContext) throws {
        let reasons = SensingLimitation.reasons(for: quality)
        guard previousReasons != reasons else { return }
        let event = QualityLimitationEvent(context: context, source: source,
            reasons: reasons.isEmpty ? [.qualityRecovered] : reasons, at: clock.now())
        // Commit transition state before synchronous delivery; callbacks may stop/restart the session.
        let prior = previousReasons; previousReasons = reasons
        do { try ledger.append(event, context: context, at: clock.now()) }
        catch { previousReasons = prior; throw error }
    }
}
