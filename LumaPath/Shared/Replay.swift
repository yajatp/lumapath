import Foundation

public struct ReplayStep: Codable, Sendable {
    public let name: String
    public let lifecycle: SessionLifecycle
    public let quality: SensingQuality
    public let reasons: [String]
    public let includeObstacle: Bool
}
public struct ReplayScenario: Codable, Sendable {
    public let schemaVersion: Int
    public let sourceMode: SourceMode
    public let imageFilename: String
    public let steps: [ReplayStep]
    public func validate() throws {
        guard schemaVersion == 2 else { throw ContractError.unsupportedSchema(schemaVersion) }
        guard sourceMode == .demoReplay, !steps.isEmpty,
              steps.allSatisfy({ $0.lifecycle == .running || $0.lifecycle == .paused }),
              steps.allSatisfy({ !$0.includeObstacle || ($0.lifecycle == .running && $0.quality != .unavailable) }) else {
            throw ContractError.invalidValue("replay scenario")
        }
    }
}

public enum ReplayFixtures {
    public static func url(_ filename: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures") else {
            throw ContractError.invalidValue("missing fixture: \(filename)")
        }
        return url
    }
    public static func scenario() throws -> ReplayScenario {
        let scenario = try JSONDecoder().decode(ReplayScenario.self, from: Data(contentsOf: url("ordinary-to-unavailable.json")))
        try scenario.validate()
        return scenario
    }
    public static func frames() throws -> [FrameDescriptor] {
        let frames = try JSONDecoder().decode([FrameDescriptor].self, from: Data(contentsOf: url("frames.json")))
        guard !frames.isEmpty else { throw ContractError.invalidValue("empty frame fixture") }
        try frames.forEach { try $0.validate() }
        return frames
    }
}

/// Deterministic manual stepping; time comes from the injected clock, never a saved uptime.
/// Each active step refreshes the fixture's envelope. The publisher is the same lightweight snapshot
/// transport Aarav can consume; it deliberately cannot deliver mandatory live feedback.
@MainActor public final class ReplaySession {
    public let snapshots: AsyncStream<SessionSnapshot>
    private let continuation: AsyncStream<SessionSnapshot>.Continuation
    private let scenario: ReplayScenario
    private let template: FrameDescriptor
    private let clock: any MonotonicClock
    private var stepIndex = 0
    private var sequence: UInt64 = 0
    public private(set) var state: SessionState
    public private(set) var stepName = "Ready"

    public init(clock: any MonotonicClock = SystemMonotonicClock(), sessionID: UUID = UUID()) throws {
        scenario = try ReplayFixtures.scenario()
        template = try ReplayFixtures.frames()[0]
        self.clock = clock
        state = SessionState(sessionID: sessionID, mode: .demoReplay)
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { continuation.finish() }

    public func start() {
        guard state.lifecycle == .idle || state.lifecycle == .ended else { return }
        stepIndex = 0; sequence = 0
        state.start()
        advance()
    }
    public func advance() {
        guard state.lifecycle == .running || state.lifecycle == .preparing else { return }
        let step = scenario.steps[stepIndex % scenario.steps.count]
        stepIndex += 1
        stepName = step.name
        if step.lifecycle == .paused {
            state.pause()
        } else if step.quality == .unavailable {
            state.markUnavailable(reason: step.reasons.first ?? "fixtureUnavailable")
        } else {
            sequence += 1
            let now = clock.now()
            let envelope = ObservationEnvelope(frameID: FrameID(context: state.context, sequence: sequence), mode: .demoReplay,
                                               capturedAt: now, createdAt: now, lifetime: CaptureConfiguration.current.maximumFrameAge)
            let frame = FrameDescriptor(envelope: envelope, imageSize: template.imageSize, depthSize: template.depthSize,
                confidenceSize: template.confidenceSize, intrinsics: template.intrinsics, cameraToWorld: template.cameraToWorld,
                orientation: template.orientation, viewportSize: template.viewportSize, imageToDisplay: template.imageToDisplay,
                depthKind: template.depthKind, tracking: template.tracking)
            let point = OpticalPoint(x: 0, y: 0, z: 2)
            let geometry = GeometryObservation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, envelope: envelope,
                                              opticalPoint: point, axialDepthMeters: 2, rangeMeters: 2)
            let event = HazardEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, envelope: envelope,
                                    geometryIDs: [geometry.id], urgency: .warning, messageKey: "demo.obstacleAhead")
            state.accept(frame, quality: QualityAssessment(state: step.quality, reasons: step.reasons),
                         geometry: step.includeObstacle ? [geometry] : [], events: step.includeObstacle ? [event] : [], at: now)
        }
        continuation.yield(state.snapshot)
    }
    public func pause() { state.pause(); continuation.yield(state.snapshot) }
    public func resume() {
        guard state.lifecycle == .paused else { return }
        state.start()
        advance()
    }
    public func end() { state.end(); stepName = "Ended"; continuation.yield(state.snapshot) }
    public func expire() {
        let before = state.snapshot
        state.expire(at: clock.now())
        if state.snapshot != before { continuation.yield(state.snapshot) }
    }
}
