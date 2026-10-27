import Foundation
import LumaPathDomain

public struct WatchSession: Codable, Sendable, Equatable {
    public let context: CaptureContext
    public let epoch: UUID
    public init(context: CaptureContext, epoch: UUID = UUID()) { self.context = context; self.epoch = epoch }
}
public enum WatchCueKind: String, Codable, Sendable, CaseIterable { case obstacle, urgent, limitation, goal, paused }
public struct WatchCue: Codable, Sendable, Equatable {
    public let nonce: UUID
    public let session: WatchSession
    public let sequence: UInt64
    public let eventID: UUID
    public let createdAt: Double
    public let expiresAt: Double
    public let kind: WatchCueKind
    public let text: String
    public init(nonce: UUID, session: WatchSession, sequence: UInt64, eventID: UUID, createdAt: Double,
                expiresAt: Double, kind: WatchCueKind, text: String) {
        self.nonce = nonce; self.session = session; self.sequence = sequence; self.eventID = eventID
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.kind = kind; self.text = text
    }
}
public enum WatchWire: Codable, Sendable {
    case probe(nonce: UUID)
    case probeReply(nonce: UUID, session: WatchSession?, phoneTime: Double)
    case ready(nonce: UUID, session: WatchSession)
    case cue(WatchCue)
    case cancel(nonce: UUID, session: WatchSession, sequence: UInt64)
    case stop(session: WatchSession)
    case pause(nonce: UUID, session: WatchSession)
    case acknowledgement(eventID: UUID, accepted: Bool)
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8192 else { throw ContractError.invalidValue("watchPacketBudget") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 8192 else { throw ContractError.invalidValue("watchPacketBudget") }
        return data
    }
}

/// Watch-initiated round trip bounds the offset between unrelated monotonic clocks.
/// If phone replies at t and watch sends/receives at p/r, phone-watch offset is in [t-r,t-p].
/// Use the upper bound to expire EARLY; never subtract device clocks without this bound.
public struct WatchReceiver: Sendable {
    public static let maximumRoundTrip = 0.20
    public static let handshakeLifetime = 2.0
    public static let maximumCueLifetime = 0.30
    public static let driftMargin = 0.01
    public private(set) var nonce: UUID?
    public private(set) var session: WatchSession?
    public private(set) var handshakeExpiresAt = 0.0
    public private(set) var current: WatchCue?
    public private(set) var currentDeadline = 0.0
    private var probeStartedAt: Double?
    private var offsetUpper = 0.0
    private var lastSequence: UInt64 = 0
    private var seen: Set<UUID> = []
    public init() {}
    public mutating func beginProbe(at now: Double) -> UUID {
        disconnect()
        let id = UUID(); nonce = id; probeStartedAt = now
        return id
    }
    @discardableResult public mutating func completeProbe(nonce: UUID, session: WatchSession?, phoneTime: Double, at now: Double) -> Bool {
        guard self.nonce == nonce, let start = probeStartedAt, let session,
              [start, now, phoneTime].allSatisfy(\.isFinite), phoneTime >= 0, now >= start,
              now-start <= Self.maximumRoundTrip else { return false }
        self.session = session; probeStartedAt = nil; offsetUpper = phoneTime-start
        handshakeExpiresAt = now + Self.handshakeLifetime; return true
    }
    public func isArmed(at now: Double) -> Bool {
        session != nil && now.isFinite && now < handshakeExpiresAt && now >= handshakeExpiresAt-Self.handshakeLifetime
    }
    @discardableResult public mutating func receive(_ cue: WatchCue, at now: Double) -> Bool {
        expire(at: now)
        guard isArmed(at: now), cue.session == session, cue.nonce == nonce,
              cue.sequence > lastSequence, !seen.contains(cue.eventID), seen.count < 128,
              [cue.createdAt, cue.expiresAt].allSatisfy(\.isFinite), cue.createdAt >= 0,
              cue.expiresAt > cue.createdAt, cue.expiresAt-cue.createdAt <= Self.maximumCueLifetime + 0.000001,
              !cue.text.isEmpty, cue.text.count <= 512 else { return false }
        let latestPhoneNow = now + offsetUpper + Self.driftMargin
        guard latestPhoneNow >= cue.createdAt, latestPhoneNow < cue.expiresAt else { return false }
        lastSequence = cue.sequence; seen.insert(cue.eventID)
        current = cue; currentDeadline = cue.expiresAt-offsetUpper-Self.driftMargin
        return true
    }
    @discardableResult public mutating func cancel(nonce: UUID, session: WatchSession, sequence: UInt64) -> Bool {
        guard self.nonce == nonce, self.session == session, sequence > lastSequence else { return false }
        lastSequence = sequence; current = nil; currentDeadline = 0; return true
    }
    public mutating func expire(at now: Double) {
        if !isArmed(at: now) { disconnect() }
        else if !now.isFinite || now >= currentDeadline { current = nil; currentDeadline = 0 }
    }
    public mutating func disconnect() {
        nonce = nil; session = nil; probeStartedAt = nil; handshakeExpiresAt = 0
        current = nil; currentDeadline = 0; lastSequence = 0; seen.removeAll()
    }
}
