import Foundation
import LumaPathDomain
import LumaPathRisk

public struct OutputChannels: Equatable, Sendable {
    public var speech: Bool
    public var haptics: Bool
    public var spatial: Bool
    public var watch: Bool
    public init(speech: Bool = false, haptics: Bool = false, spatial: Bool = false, watch: Bool = false) {
        self.speech = speech; self.haptics = haptics; self.spatial = spatial; self.watch = watch
    }
    public var muted: Bool { !speech && !haptics && !spatial && !watch }
}
public struct OutputCapabilities: Sendable {
    public let speech: Bool
    public let haptics: Bool
    public let spatial: Bool
    public let watch: Bool
    public let reason: String?
    public init(speech: Bool, haptics: Bool, reason: String? = nil, spatial: Bool = false, watch: Bool = false) {
        self.speech = speech; self.haptics = haptics; self.reason = reason; self.spatial = spatial; self.watch = watch
    }
}
public enum FeedbackKind: String, Sendable { case urgent, obstacle, limitation, goal, description, preview, paused }
public struct FeedbackItem: Sendable {
    public let id: UUID
    public let context: CaptureContext
    public let createdAt: TimeInterval
    public let expiresAt: TimeInterval
    public let kind: FeedbackKind
    public let priority: Int
    public let text: String
    public let repeatKey: String
    public let source: String
    public let bearingRadians: Double?
    public init(id: UUID = UUID(), context: CaptureContext, createdAt: TimeInterval, expiresAt: TimeInterval,
                kind: FeedbackKind, priority: Int, text: String, repeatKey: String, source: String, bearingRadians: Double? = nil) {
        self.id = id; self.context = context; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.kind = kind; self.priority = priority; self.text = text; self.repeatKey = repeatKey; self.source = source
        self.bearingRadians = bearingRadians
    }
    public func isCurrent(in context: CaptureContext, at now: TimeInterval) -> Bool {
        self.context == context && createdAt.isFinite && expiresAt.isFinite && now.isFinite
        && now >= createdAt && now < expiresAt && expiresAt > createdAt
    }
}
public struct FeedbackTrace: Sendable {
    public let time: TimeInterval
    public let id: UUID
    public let action: String
}

@MainActor public protocol FeedbackOutputSink: AnyObject {
    var capabilities: OutputCapabilities { get }
    var onCompletion: (@MainActor (UUID) -> Void)? { get set }
    /// Return false if neither requested channel starts. Never retain an expired request.
    func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool
    func cancel(reason: String)
}

/// Mandatory events are consumed from the acknowledged ledger, never the coalesced UI snapshot.
/// There is no range-to-risk policy here: urgency comes only from A3.
@MainActor public final class FeedbackCoordinator {
    public private(set) var current: FeedbackItem?
    public private(set) var queued: [FeedbackItem] = []
    public private(set) var trace: [FeedbackTrace] = []
    public private(set) var channels = OutputChannels()
    public var onChange: (@MainActor () -> Void)?
    private let sink: any FeedbackOutputSink
    private let clock: any MonotonicClock
    private let capacity: Int
    private var context: CaptureContext?
    private var researchAllowed = false
    private var recent: [String: (time: TimeInterval, priority: Int)] = [:]
    private var handled: [UUID: TimeInterval] = [:]
    private var suspendedLimitation: FeedbackItem?
    private var lastDescription: TimeInterval?
    public private(set) var descriptionInterval: TimeInterval = 10
    /// Only optional descriptions use this limit. Existing mandatory output is untouched.
    public func setDescriptionInterval(_ seconds: TimeInterval) {
        guard seconds.isFinite, (5...30).contains(seconds) else { return }
        descriptionInterval = seconds
    }
    private var revision: UInt64 = 0
    public init(sink: any FeedbackOutputSink, clock: any MonotonicClock = SystemMonotonicClock(), capacity: Int = 16) {
        precondition((1...32).contains(capacity))
        self.sink = sink; self.clock = clock; self.capacity = capacity
        sink.onCompletion = { [weak self] id in self?.completed(id) }
    }
    public var capabilities: OutputCapabilities { sink.capabilities }
    public func start(context: CaptureContext, allowResearch: Bool) {
        cancel(reason: "newContext"); self.context = context; researchAllowed = allowResearch
    }
    public func setChannels(_ value: OutputChannels) {
        guard channels != value else { return }
        clearOutput(reason: "channelsChanged"); channels = value; onChange?()
    }
    public func cancel(reason: String) {
        clearOutput(reason: reason); context = nil; researchAllowed = false
        recent.removeAll(); handled.removeAll(); lastDescription = nil; onChange?()
    }
    /// Clears scene output while retaining the bound generation, e.g. on frame/viewport loss.
    public func invalidateScene(reason: String) { clearOutput(reason: reason); recent.removeAll(); onChange?() }
    /// Goal/profile changes remove only optional decisions. Mandatory hazards/limitations keep their order.
    public func invalidateOptional() {
        queued.removeAll { $0.kind == .goal || $0.kind == .description }
        if let current, current.kind == .goal || current.kind == .description {
            record(current.id, "cancel:optionalRevision"); self.current = nil; sink.cancel(reason: "optionalRevision")
        }
        pump(); onChange?()
    }
    private func clearOutput(reason: String) {
        if let current { record(current.id, "cancel:\(reason)") }
        for item in queued { record(item.id, "discard:\(reason)") }
        if let suspendedLimitation { record(suspendedLimitation.id, "discard:\(reason)") }
        suspendedLimitation = nil
        current = nil; queued.removeAll(); sink.cancel(reason: reason)
    }
    public func consume(_ ledger: HazardEventLedger) {
        tick()
        guard let context else { return }
        for event in ledger.pending(at: clock.now()) {
            guard event.envelope.isCurrent(in: context, at: clock.now()) else { continue }
            guard researchAllowed, event.deliveryScope == .research,
                  let item = Self.item(for: event, context: context) else {
                record(event.id, "rejected:scopeOrMeaning")
                ledger.acknowledge(event.id, context: context, at: clock.now()); continue
            }
            if enqueue(item) { ledger.acknowledge(event.id, context: context, at: clock.now()) }
            // A full queue leaves the event pending. The caller drains again on completion/tick.
        }
    }
    /// Consume acknowledged sensing transitions; never cancel or suppress obstacle output.
    public func consume(_ ledger: QualityLimitationLedger) {
        tick()
        guard let context else { return }
        for event in ledger.pending(at: clock.now()) {
            guard event.isCurrent(in: context, at: clock.now()) else { continue }
            guard researchAllowed else {
                ledger.acknowledge(event.id, context: context, at: clock.now()); continue
            }
            // New conditions supersede an older limitation, including one suspended by an urgent cue.
            invalidateLimitations()
            let item = FeedbackItem(id: event.id, context: context, createdAt: event.createdAt, expiresAt: event.expiresAt,
                kind: .limitation, priority: 4, text: event.reasons.map(\.message).prefix(3).joined(separator: " "),
                repeatKey: "quality." + event.reasons.map(\.rawValue).joined(separator: "."), source: context.mode.rawValue)
            if enqueue(item) { ledger.acknowledge(event.id, context: context, at: clock.now()) }
        }
    }
    private func invalidateLimitations() {
        if let current, current.kind == .limitation {
            record(current.id, "cancel:qualityChanged"); self.current = nil; sink.cancel(reason: "qualityChanged")
        }
        for item in queued where item.kind == .limitation { record(item.id, "discard:qualityChanged") }
        queued.removeAll { $0.kind == .limitation }
        if let suspendedLimitation { record(suspendedLimitation.id, "discard:qualityChanged") }
        suspendedLimitation = nil
    }
    /// Explicit UI previews/optional requests only. Untrusted OCR/report text must not call this API.
    @discardableResult public func enqueue(_ item: FeedbackItem) -> Bool {
        guard let context, item.isCurrent(in: context, at: clock.now()) else { record(item.id, "rejected:staleContext"); return true }
        if handled[item.id] != nil { return true }
        guard handled.count < 512 else { record(item.id, "backpressure:history"); return false }
        let now = clock.now()
        if item.kind == .description, let lastDescription, now - lastDescription < descriptionInterval {
            handled[item.id] = item.expiresAt; record(item.id, "suppressed:optionalInterval"); return true
        }
        if let previous = recent[item.repeatKey], item.priority <= previous.priority,
           now - previous.time < (item.kind == .description ? 10 : 3) {
            handled[item.id] = item.expiresAt; record(item.id, "suppressed:repeat"); return true
        }
        if queued.contains(where: { $0.repeatKey == item.repeatKey && $0.priority >= item.priority }) {
            handled[item.id] = item.expiresAt; record(item.id, "suppressed:queuedRepeat"); return true
        }
        if channels.muted {
            handled[item.id] = item.expiresAt; record(item.id, "muted"); onChange?(); return true
        }
        if let active = current, item.priority > active.priority {
            record(active.id, "interrupted:priority"); current = nil; sink.cancel(reason: "priority")
            // A limitation remains eligible after interruption; optional speech is discarded.
            if active.kind == .limitation {
                if queued.count < capacity { queued.append(active) } else { suspendedLimitation = active }
            }
        }
        // The current-output slot is separate from the pending queue: a full queue cannot block urgent interruption.
        if current == nil && item.priority >= (queued.map(\.priority).max() ?? 0)
            && item.priority >= (suspendedLimitation?.priority ?? 0) {
            handled[item.id] = item.expiresAt; startPlayback(item); onChange?(); return true
        }
        guard queued.count < capacity else { record(item.id, "backpressure"); return false }
        handled[item.id] = item.expiresAt
        queued.removeAll { $0.repeatKey == item.repeatKey && $0.priority < item.priority }
        queued.append(item); record(item.id, "queued"); pump(); onChange?(); return true
    }
    public func tick() {
        let before = revision
        let now = clock.now()
        handled = handled.filter { $0.value > now }
        recent = recent.filter { now - $0.value.time < 10 }
        guard let context else { return }
        if let suspendedLimitation, !suspendedLimitation.isCurrent(in: context, at: now) {
            record(suspendedLimitation.id, "expired:suspended"); self.suspendedLimitation = nil
        }
        queued.removeAll { item in
            if !item.isCurrent(in: context, at: now) { record(item.id, "expired:queued"); return true }
            return false
        }
        if let current, !current.isCurrent(in: context, at: now) {
            record(current.id, "expired:playing"); self.current = nil; sink.cancel(reason: "expired")
        }
        pump(); if revision != before { onChange?() }
    }
    private func pump() {
        guard current == nil, let context else { return }
        queued.sort { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority > $1.priority }
        while (!queued.isEmpty || suspendedLimitation != nil) && current == nil {
            let item: FeedbackItem
            if let suspendedLimitation, suspendedLimitation.priority >= (queued.first?.priority ?? 0) {
                item = suspendedLimitation; self.suspendedLimitation = nil
            } else { item = queued.removeFirst() }
            guard item.isCurrent(in: context, at: clock.now()) else { record(item.id, "expired:beforePlayback"); continue }
            startPlayback(item)
        }
    }
    private func startPlayback(_ item: FeedbackItem) {
        guard let context, item.isCurrent(in: context, at: clock.now()) else { record(item.id, "expired:beforePlayback"); return }
        if item.kind == .description, let lastDescription, clock.now() - lastDescription < descriptionInterval {
            record(item.id, "suppressed:optionalInterval"); return
        }
        current = item
        if sink.play(item, channels: channels) {
            if item.kind == .description { lastDescription = clock.now() }
            if recent.count >= 128, let oldest = recent.min(by: { $0.value.time < $1.value.time })?.key { recent.removeValue(forKey: oldest) }
            recent[item.repeatKey] = (clock.now(), item.priority); record(item.id, "started")
        } else { current = nil; record(item.id, "unavailable:output") }
    }
    private func completed(_ id: UUID) {
        guard current?.id == id else { return }
        record(id, clock.now() >= (current?.expiresAt ?? 0) ? "expired:playing" : "completed"); current = nil; tick(); onChange?()
    }
    private func record(_ id: UUID, _ action: String) {
        revision &+= 1
        trace.append(FeedbackTrace(time: clock.now(), id: id, action: action))
        if trace.count > 128 { trace.removeFirst(trace.count - 128) }
    }
    public static func item(for event: HazardEvent, context: CaptureContext) -> FeedbackItem? {
        let directions = ["obstacle.ahead": "ahead", "obstacle.left": "on your left", "obstacle.right": "on your right", "obstacle.unknown": "nearby"]
        guard let range = event.rangeMeters, range.isFinite, range > 0 else { return nil }
        let urgent = event.urgency == .urgent
        let text: String
        if let direction = directions[event.messageKey] {
            text = urgent ? "Close obstacle \(direction)." : String(format: "Obstacle %@, about %.1f meters.", direction, range)
        } else {
            let meanings = ["candidate.overhead": "overhead obstacle", "candidate.narrowPassage": "narrow passage",
                "candidate.stepUp": "step up", "candidate.stepDown": "step down", "candidate.stairs": "stairs",
                "candidate.movingObstacle": "moving obstacle"]
            guard let meaning = meanings[event.messageKey], event.advancedCandidateID != nil,
                  let bearing = event.bearingRadians, bearing.isFinite, abs(bearing) <= .pi else { return nil }
            let direction = bearing < -0.2 ? "left of the phone" : bearing > 0.2 ? "right of the phone" : "ahead of the phone"
            text = "Possible \(meaning) \(direction)." + (urgent ? " Urgent." : "") + " Research estimate; uncertain."
        }
        let priority = event.urgency == .urgent ? 6 : event.urgency == .warning ? 5 : 3
        return FeedbackItem(id: event.id, context: context, createdAt: event.envelope.createdTimeMonotonic,
            expiresAt: event.envelope.expiresAtMonotonic, kind: urgent ? .urgent : .obstacle,
            priority: priority, text: text, repeatKey: event.messageKey, source: event.envelope.sourceMode.rawValue,
            bearingRadians: event.bearingRadians)
    }
}
