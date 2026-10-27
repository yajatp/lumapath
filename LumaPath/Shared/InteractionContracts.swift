import Foundation

/// Additive B1 consumer contracts. Capture/schema/configuration remain version 2.
public enum AppTab: String, CaseIterable, Sendable { case home, find, routes, community }
public enum ShellCommand: Sendable { case startDemo, nextFixture, pause, resume, end }
public enum VisualFocus: String, CaseIterable, Sendable { case wholeScene, centralSummary, wideSceneSummary }
public enum SpeechDetail: String, CaseIterable, Sendable { case minimal, standard, descriptive }

/// A transient preview, not the B4 persisted profile schema or an input to hazard policy.
public struct PresentationPreferences: Equatable, Sendable {
    public var focus: VisualFocus = .wholeScene
    public var speechDetail: SpeechDetail = .minimal
    public init() {}
}

public enum ShellFeature: Sendable { case liveView, find, places, routes, community }
public protocol ShellAvailabilityProviding: Sendable {
    func unavailableReason(for feature: ShellFeature) -> String
}

/// Explicit fixture adapter: no service request, camera authorization, or target search occurs.
/// Replaced per package as real consumer integrations become available.
public struct B1FixtureServices: ShellAvailabilityProviding {
    public init() {}
    public func unavailableReason(for feature: ShellFeature) -> String {
        switch feature {
        case .liveView: "Live view is unavailable in this build. Camera rendering and phone alerts are still being integrated. You can try the labeled demo."
        case .find: "Finding targets is unavailable in this build. Target models and the Find interaction still need integration and validation. No search is running."
        case .places: "Manual place names and notes are available on this device. Spatial scanning, alignment, and remembered guidance are not connected."
        case .routes: "Route planning is unavailable in this build. A surveyed graph and location integration are required. No route is being calculated."
        case .community: "Community reports are unavailable in this build. The report service and client are not connected. Nothing is uploaded."
        }
    }
}

/// Commands are user actions only. OCR/report text must never enter this boundary.
@MainActor public protocol ShellSessionService: AnyObject {
    var snapshots: AsyncStream<SessionSnapshot> { get }
    var snapshot: SessionSnapshot { get }
    var stepName: String { get }
    func perform(_ command: ShellCommand)
    func expire()
}

/// Uses A1's real transport and domain lifecycle; it is not a second session engine.
@MainActor public final class ReplayShellService: ShellSessionService {
    private let replay: ReplaySession
    public var snapshots: AsyncStream<SessionSnapshot> { replay.snapshots }
    public var snapshot: SessionSnapshot { replay.state.snapshot }
    public var stepName: String { replay.stepName }
    public init(clock: any MonotonicClock = SystemMonotonicClock(), sessionID: UUID = UUID()) throws {
        replay = try ReplaySession(clock: clock, sessionID: sessionID)
    }
    public func perform(_ command: ShellCommand) {
        switch command {
        case .startDemo: replay.start()
        case .nextFixture: replay.advance()
        case .pause: replay.pause()
        case .resume: replay.resume()
        case .end: replay.end()
        }
    }
    public func expire() { replay.expire() }
}

/// Presentation reducer. Only the owning service may bind a new context, synchronously
/// after a user action; buffered snapshots cannot change session/generation/mode.
public struct ShellState: Sendable {
    public var tab: AppTab = .home
    public private(set) var snapshot: SessionSnapshot?
    public private(set) var context: CaptureContext?
    public private(set) var preferences = PresentationPreferences()
    public private(set) var profileRevision: UInt64 = 0
    private var sequence: UInt64?
    public init() {}
    public mutating func bind(to context: CaptureContext) {
        guard self.context != context else { return }
        self.context = context
        snapshot = nil
        sequence = nil
    }
    @discardableResult public mutating func receive(_ incoming: SessionSnapshot, at now: TimeInterval) -> Bool {
        guard now.isFinite, incoming.context == context else { return false }
        if let frame = incoming.frame {
            guard (try? frame.validate()) != nil,
                  frame.envelope.isCurrent(in: incoming.context, at: now),
                  sequence.map({ frame.envelope.frameID.sequence >= $0 }) ?? true,
                  !(snapshot?.frame == nil && sequence == frame.envelope.frameID.sequence)
            else { return false }
            sequence = frame.envelope.frameID.sequence
        }
        snapshot = sanitized(incoming, at: now)
        return true
    }
    public mutating func expire(at now: TimeInterval) {
        guard let snapshot else { return }
        self.snapshot = sanitized(snapshot, at: now)
    }
    public mutating func apply(_ preferences: PresentationPreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        profileRevision += 1
    }
    public var isSessionOpen: Bool {
        guard let lifecycle = snapshot?.lifecycle else { return false }
        return lifecycle != .idle && lifecycle != .ended
    }
    public func allows(_ command: ShellCommand) -> Bool {
        guard let lifecycle = snapshot?.lifecycle else { return false }
        switch command {
        case .startDemo: return lifecycle == .idle || lifecycle == .ended
        case .nextFixture, .pause: return lifecycle == .running || lifecycle == .preparing
        case .resume: return lifecycle == .paused
        case .end: return isSessionOpen
        }
    }
    private func sanitized(_ value: SessionSnapshot, at now: TimeInterval) -> SessionSnapshot {
        let active = value.lifecycle == .running || value.lifecycle == .preparing
        let frame = active && value.frame?.envelope.isCurrent(in: value.context, at: now) == true ? value.frame : nil
        let geometry = value.geometry.filter {
            frame != nil && $0.envelope.frameID == frame?.envelope.frameID && $0.envelope.isCurrent(in: value.context, at: now)
        }
        let ids = Set(geometry.map(\.id))
        let events = value.events.filter {
            frame != nil && $0.envelope.frameID == frame?.envelope.frameID
            && $0.envelope.isCurrent(in: value.context, at: now) && Set($0.geometryIDs).isSubset(of: ids)
        }
        let quality = active && value.frame != nil && frame == nil
            ? QualityAssessment(state: .unavailable, reasons: ["frameExpired"]) : value.quality
        return SessionSnapshot(context: value.context, lifecycle: value.lifecycle, quality: quality,
                               frame: frame, geometry: geometry, events: events)
    }
}

/// B2 composition input. This owns metadata only, never a native buffer or a camera.
/// The renderer still acquires/revalidates A2's lease synchronously at actual rendering.
public struct RendererRequest: Sendable {
    public let frame: FrameDescriptor
    public let geometry: [GeometryObservation]
    /// For an active B3 consumer after asynchronous perception. Caller owns lifecycle cancellation;
    /// the output layer still matches this request against the exact displayed descriptor.
    public init?(frame: FrameDescriptor, geometry: [GeometryObservation], context: CaptureContext, at now: TimeInterval) {
        guard (try? frame.validate()) != nil, frame.envelope.isCurrent(in: context, at: now) else { return nil }
        self.frame = frame
        self.geometry = geometry.filter { $0.envelope.frameID == frame.envelope.frameID && $0.envelope.isCurrent(in: context, at: now) }
    }
    public init?(snapshot: SessionSnapshot, displayedFrame: FrameDescriptor,
                 orientation: ImageOrientation, viewport: PixelSize, at now: TimeInterval) {
        guard snapshot.lifecycle == .running, let frame = snapshot.frame,
              frame == displayedFrame, frame.orientation == orientation, frame.viewportSize == viewport,
              (try? frame.validate()) != nil, frame.envelope.isCurrent(in: snapshot.context, at: now) else { return nil }
        self.frame = frame
        geometry = snapshot.geometry.filter {
            $0.envelope.frameID == frame.envelope.frameID && $0.envelope.isCurrent(in: snapshot.context, at: now)
        }
    }
}

/// Draft vocabulary only. B3 implements playback; B5 adds spatial/watch validation.
public enum CuePreview: String, CaseIterable, Sendable {
    case obstacle, urgent, limitation, goal, paused
    public var title: String {
        switch self {
        case .obstacle: "Nearby obstacle"
        case .urgent: "Urgent proximity"
        case .limitation: "Sensing limitation"
        case .goal: "Requested goal candidate"
        case .paused: "Session paused"
        }
    }
    public var example: String {
        switch self {
        case .obstacle: "Obstacle ahead, about two meters."
        case .urgent: "Close obstacle ahead."
        case .limitation: "Ground sensing limited."
        case .goal: "Possible elevator sign on your left."
        case .paused: "Guidance paused."
        }
    }
    public var pattern: String {
        switch self {
        case .obstacle: "Two short pulses"
        case .urgent: "Three short pulses"
        case .limitation: "One longer pulse, pause, short pulse"
        case .goal: "Single soft pulse"
        case .paused: "Distinct confirmation tap"
        }
    }
}
