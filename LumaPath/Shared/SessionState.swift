import Foundation

public enum SessionLifecycle: String, Codable, Sendable { case idle, preparing, running, paused, ended, blocked }

public struct SessionSnapshot: Sendable, Equatable {
    public let context: CaptureContext
    public let lifecycle: SessionLifecycle
    public let quality: QualityAssessment
    public let frame: FrameDescriptor?
    public let geometry: [GeometryObservation]
    /// Presentation copy only. A3/B3 must deliver mandatory events on a separate acknowledged ledger.
    public let events: [HazardEvent]
}

/// Producer boundary for Aarav's presentation store. Raw pixel bytes never enter snapshots.
public struct SessionState: Sendable {
    public private(set) var context: CaptureContext
    public private(set) var lifecycle: SessionLifecycle = .idle
    public private(set) var quality = QualityAssessment(state: .initializing, reasons: [])
    public private(set) var frame: FrameDescriptor?
    public private(set) var geometry: [GeometryObservation] = []
    public private(set) var events: [HazardEvent] = []
    private var lastSequence: UInt64?

    public init(sessionID: UUID = UUID(), mode: SourceMode) {
        context = CaptureContext(sessionID: sessionID, generation: 0, mode: mode)
    }
    /// Bind quality to the exact context already issued by the capture owner.
    public init(activeContext: CaptureContext) {
        context = activeContext; lifecycle = .preparing
    }
    public var snapshot: SessionSnapshot {
        SessionSnapshot(context: context, lifecycle: lifecycle, quality: quality, frame: frame, geometry: geometry, events: events)
    }
    public mutating func start() {
        guard lifecycle == .idle || lifecycle == .paused || lifecycle == .ended || lifecycle == .blocked else { return }
        let id = lifecycle == .ended ? UUID() : context.sessionID
        context = CaptureContext(sessionID: id, generation: context.generation + 1, mode: context.mode)
        lifecycle = .preparing
        clearObservations()
        quality = QualityAssessment(state: .initializing, reasons: [])
    }
    public mutating func pause() {
        guard lifecycle == .preparing || lifecycle == .running else { return }
        invalidate(as: .paused)
    }
    public mutating func end() { invalidate(as: .ended) }
    public mutating func block(reason: String) {
        invalidate(as: .blocked)
        quality = QualityAssessment(state: .unavailable, reasons: [reason])
    }
    private mutating func invalidate(as next: SessionLifecycle) {
        context = CaptureContext(sessionID: context.sessionID, generation: context.generation + 1, mode: context.mode)
        lifecycle = next
        clearObservations()
        quality = QualityAssessment(state: .initializing, reasons: [])
    }
    private mutating func clearObservations() { frame = nil; geometry = []; events = []; lastSequence = nil }

    /// Preflight asynchronous producer work without advancing the sequence watermark or recovery state.
    public func canAcceptFrame(_ incoming: FrameDescriptor, at now: TimeInterval) -> Bool {
        (lifecycle == .preparing || lifecycle == .running)
        && (try? incoming.validate()) != nil && incoming.envelope.isCurrent(in: context, at: now)
        && (lastSequence.map { incoming.envelope.frameID.sequence > $0 } ?? true)
    }
    @discardableResult public mutating func accept(
        _ incoming: FrameDescriptor, quality: QualityAssessment, geometry: [GeometryObservation] = [],
        events: [HazardEvent] = [], at now: TimeInterval
    ) -> Bool {
        guard canAcceptFrame(incoming, at: now) else { return false }
        frame = incoming; self.quality = quality; lifecycle = .running
        lastSequence = incoming.envelope.frameID.sequence
        self.geometry = geometry.filter { $0.envelope.frameID == incoming.envelope.frameID && $0.envelope.isCurrent(in: context, at: now) }
        let acceptedGeometryIDs = Set(self.geometry.map(\.id))
        self.events = events.filter {
            $0.envelope.frameID == incoming.envelope.frameID && $0.envelope.isCurrent(in: context, at: now)
            && Set($0.geometryIDs).isSubset(of: acceptedGeometryIDs)
        }
        return true
    }
    public mutating func expire(at now: TimeInterval) {
        guard lifecycle == .running || lifecycle == .preparing else { return }
        if let frame, !frame.envelope.isCurrent(in: context, at: now) {
            self.frame = nil; geometry = []; events = []
            quality = QualityAssessment(state: .unavailable, reasons: ["frameExpired"])
        }
        geometry.removeAll { !$0.envelope.isCurrent(in: context, at: now) }
        events.removeAll { !$0.envelope.isCurrent(in: context, at: now) }
    }
    public mutating func markUnavailable(reason: String) {
        guard lifecycle == .running || lifecycle == .preparing else { return }
        // Keep the sequence watermark so an old frame cannot recover an outage.
        frame = nil; geometry = []; events = []
        quality = QualityAssessment(state: .unavailable, reasons: [reason])
    }
}
