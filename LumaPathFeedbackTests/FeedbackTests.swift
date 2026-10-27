import Foundation
import Testing
import LumaPathDomain
import LumaPathRisk
import LumaPathPerception
import LumaPathFeedback

@MainActor @Test func goalRevisionInvalidationPreservesMandatoryOutput() {
    let (_, sink, coordinator) = setup()
    let mandatory = item(.urgent, priority: 6, key: "mandatory")
    let optional = item(.goal, priority: 1, key: "goal")
    coordinator.enqueue(mandatory); coordinator.enqueue(optional)
    let cancellations = sink.cancellations.count
    coordinator.invalidateOptional()
    #expect(coordinator.current?.id == mandatory.id)
    #expect(coordinator.queued.isEmpty)
    #expect(sink.cancellations.count == cancellations)
    sink.finish(mandatory.id)
    let next = item(.goal, priority: 1, key: "next-goal")
    coordinator.enqueue(next); coordinator.invalidateOptional()
    #expect(coordinator.current == nil)
    #expect(sink.cancellations.last == "optionalRevision")
}

private func advanced(_ family: AdvancedHazardFamily, urgency: HazardUrgency = .warning, candidate: UUID? = UUID(), bearing: Double = 0.1) -> HazardEvent {
    HazardEvent(id: UUID(), envelope: hazard().envelope, geometryIDs: [], urgency: urgency,
        messageKey: "candidate.\(family.rawValue)", rangeMeters: 2, bearingRadians: bearing,
        evidenceReasons: ["uncertainty"], deliveryScope: .research, advancedCandidateID: candidate)
}
@MainActor @Test func everyAdvancedFamilyRetainsProducerUrgencyExpiryAndUncertainty() {
    for family in AdvancedHazardFamily.allCases {
        for urgency in [HazardUrgency.information, .warning, .urgent] {
            let event = advanced(family, urgency: urgency)
            let value = FeedbackCoordinator.item(for: event, context: context())
            #expect(value?.text.contains("Possible") == true && value?.text.contains("uncertain") == true)
            #expect(value?.priority == (urgency == .urgent ? 6 : urgency == .warning ? 5 : 3))
            #expect(value?.expiresAt == event.envelope.expiresAtMonotonic)
            #expect(value?.bearingRadians == event.bearingRadians)
        }
        #expect(FeedbackCoordinator.item(for: advanced(family, candidate: nil), context: context()) == nil)
        #expect(FeedbackCoordinator.item(for: advanced(family, bearing: .nan), context: context()) == nil)
    }
}
@MainActor @Test func advancedHazardsCoexistWithQualityAndDeduplicateWithoutSuppressingUrgency() throws {
    let (clock, sink, coordinator) = setup()
    let quality = QualityLimitationLedger(); quality.start(context: context())
    let limitation = QualityLimitationEvent(context: context(), source: nil, reasons: [.inputUnavailable], at: clock.now())
    try quality.append(limitation, context: context(), at: clock.now()); coordinator.consume(quality)
    let ledger = HazardEventLedger(); ledger.start(context: context())
    let first = advanced(.overhead)
    try ledger.append([first], context: context(), at: clock.now()); coordinator.consume(ledger)
    try ledger.append([advanced(.overhead), advanced(.stepDown, urgency: .urgent)], context: context(), at: clock.now())
    coordinator.consume(ledger)
    #expect(sink.starts.map(\.kind) == [.limitation, .obstacle, .urgent])
    #expect(coordinator.queued.contains { $0.id == limitation.id })
    #expect(coordinator.trace.contains { $0.action == "suppressed:repeat" })
    #expect(ledger.pending(at: clock.now()).isEmpty)
    sink.finish(coordinator.current!.id)
    #expect(coordinator.current?.id == limitation.id)
    clock.advance(1); coordinator.tick(); #expect(coordinator.current == nil)
}
@MainActor @Test func unavailableOrDisconnectedAccessoryDoesNotGatePhone() {
    let phone = RecordingSink(), accessory = RecordingSink(); accessory.accepts = false
    let fanout = IndependentOutputSink(phone: phone, accessories: [accessory])
    let cue = item(.urgent, priority: 6)
    var completed: [UUID] = []; fanout.onCompletion = { completed.append($0) }
    #expect(fanout.play(cue, channels: OutputChannels(speech: true, watch: true)))
    #expect(phone.starts.map(\.id) == [cue.id])
    accessory.finish(cue.id)
    #expect(completed.isEmpty && phone.cancellations == ["replacement"])
    phone.finish(cue.id); #expect(completed == [cue.id])
    accessory.accepts = true
    let next = item(.urgent, priority: 6, key: "next")
    #expect(fanout.play(next, channels: OutputChannels(speech: true, watch: true)))
    accessory.finish(next.id)
    #expect(completed.count == 1)
    fanout.cancel(reason: "pause"); phone.finish(next.id)
    #expect(completed.count == 1 && phone.cancellations.last == "pause" && accessory.cancellations.last == "pause")
}

@MainActor @Test func synchronousPhoneCompletionFinishesWhenRemainingAccessoriesDecline() {
    for accessoryAccepts in [false, true] {
        let phone = RecordingSink(), accessory = RecordingSink()
        phone.completesImmediately = true
        accessory.accepts = accessoryAccepts
        accessory.completesImmediately = true
        let fanout = IndependentOutputSink(phone: phone, accessories: [accessory])
        var completed: [UUID] = []
        fanout.onCompletion = { completed.append($0) }
        let cue = item(.urgent, priority: 6)
        #expect(fanout.play(cue, channels: OutputChannels(speech: true, watch: true)))
        #expect(completed == [cue.id])
        phone.finish(cue.id); accessory.finish(cue.id)
        #expect(completed == [cue.id])
    }
}

@MainActor @Test func profileIntervalOnlyThrottlesOptionalDescriptions() {
    let (clock, sink, coordinator) = setup()
    coordinator.setDescriptionInterval(5)
    let first = item(key: "first", lifetime: 40)
    coordinator.enqueue(first); sink.finish(first.id)
    clock.advance(4.9)
    coordinator.enqueue(item(key: "tooSoon", at: clock.now(), lifetime: 40))
    #expect(sink.starts.count == 1)
    clock.advance(0.1)
    let next = item(key: "eligible", at: clock.now(), lifetime: 40)
    coordinator.enqueue(next); sink.finish(next.id)
    #expect(sink.starts.count == 2)
    coordinator.setDescriptionInterval(30)
    coordinator.enqueue(item(key: "nowLimited", at: clock.now(), lifetime: 40))
    coordinator.enqueue(item(.urgent, priority: 6, key: "mandatory", at: clock.now()))
    #expect(sink.starts.last?.kind == .urgent && sink.starts.count == 3)
    coordinator.setDescriptionInterval(31)
    #expect(coordinator.descriptionInterval == 30 && coordinator.current?.kind == .urgent)
}

private final class FeedbackClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ delta: TimeInterval) { lock.withLock { value += delta } }
}
@MainActor private final class RecordingSink: FeedbackOutputSink {
    var capabilities = OutputCapabilities(speech: true, haptics: true)
    var onCompletion: (@MainActor (UUID) -> Void)?
    var starts: [FeedbackItem] = []
    var cancellations: [String] = []
    var accepts = true
    var completesImmediately = false
    func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool {
        if accepts {
            starts.append(item)
            if completesImmediately { onCompletion?(item.id) }
        }
        return accepts
    }
    func cancel(reason: String) { cancellations.append(reason) }
    func finish(_ id: UUID) { onCompletion?(id) }
}
private func context(_ generation: UInt64 = 1) -> CaptureContext {
    CaptureContext(sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000b3")!, generation: generation, mode: .demoReplay)
}
private func item(_ kind: FeedbackKind = .description, priority: Int = 1, key: String = "optional", at: Double = 100, lifetime: Double = 5, generation: UInt64 = 1) -> FeedbackItem {
    FeedbackItem(context: context(generation), createdAt: at, expiresAt: at+lifetime, kind: kind, priority: priority, text: "Test \(key)", repeatKey: key, source: "test")
}
private func hazard(_ urgency: HazardUrgency = .warning, key: String = "obstacle.ahead", at: Double = 100, sequence: UInt64 = 1) -> HazardEvent {
    HazardEvent(id: UUID(), envelope: ObservationEnvelope(frameID: FrameID(context: context(), sequence: sequence), mode: .demoReplay,
        capturedAt: at, createdAt: at, lifetime: 0.3), geometryIDs: [UUID()], urgency: urgency, messageKey: key,
        corridor: .ahead, rangeMeters: 2, deliveryScope: .research)
}
@MainActor private func setup(capacity: Int = 16) -> (FeedbackClock, RecordingSink, FeedbackCoordinator) {
    let clock = FeedbackClock(), sink = RecordingSink()
    let coordinator = FeedbackCoordinator(sink: sink, clock: clock, capacity: capacity)
    coordinator.start(context: context(), allowResearch: true)
    coordinator.setChannels(OutputChannels(speech: true, haptics: true))
    return (clock, sink, coordinator)
}

@MainActor @Test func realGeometryLedgerDeliversFirstEventWithoutPresentationConsumption() async throws {
    let (clock, sink, coordinator) = setup()
    let pipeline = GeometryPipeline(clock: clock)
    pipeline.start(context: context())
    pipeline.ledger.onEventsAvailable = { _ in coordinator.consume(pipeline.ledger) }
    let depth = try GeometryFixture.load()[0].image(context: context(), sequence: 1, at: clock.now())
    _ = try await pipeline.process(depth) // Deliberately discard the newest-only presentation snapshot.
    #expect(sink.starts.count == 1)
    #expect(sink.starts.first?.kind == .obstacle)
    #expect(sink.starts.first?.expiresAt == 100.3)
    #expect(pipeline.ledger.pending(at: clock.now()).isEmpty)
    #expect(coordinator.trace.contains { $0.action == "started" && $0.time == 100 })
    clock.advance(0.3); coordinator.tick()
    #expect(coordinator.current == nil)
    #expect(sink.cancellations.last == "expired")
}

@MainActor @Test func producerUrgencyOrdersSideAheadAndUrgentWithoutNewDistancePolicy() throws {
    let (clock, sink, coordinator) = setup()
    var processor = GeometryProcessor()
    let fixtures = try GeometryFixture.load()
    var events: [HazardEvent] = []
    for i in 0..<3 {
        let depth = try fixtures[i].image(context: context(), sequence: UInt64(i+1), at: clock.now())
        let result = try processor.process(depth, context: context(), at: clock.now())
        events += HazardPolicy().evaluate(result, context: context(), at: clock.now())
    }
    #expect(events.map(\.urgency) == [.warning, .information, .urgent])
    let ledger = HazardEventLedger(); ledger.start(context: context())
    try ledger.append(events, context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(sink.starts.first?.kind == .urgent)
    #expect(coordinator.queued.first?.text.contains("right") == true)
    #expect(ledger.pending(at: clock.now()).isEmpty)
}

@MainActor @Test func urgentInterruptsOptionalAndLimitationSurvivesCompetingHazard() {
    let (_, sink, coordinator) = setup()
    coordinator.enqueue(item())
    coordinator.enqueue(item(.limitation, priority: 4, key: "limited"))
    let limitationID = coordinator.current!.id
    coordinator.enqueue(item(.urgent, priority: 6, key: "urgent"))
    #expect(sink.starts.map(\.kind) == [.description, .limitation, .urgent])
    #expect(coordinator.queued.map(\.id) == [limitationID])
    sink.finish(coordinator.current!.id)
    #expect(coordinator.current?.id == limitationID)
    #expect(sink.cancellations.contains("priority"))
}

@MainActor @Test func repeatSuppressionUsesMeaningAndSeverityIncreaseBypassesIt() throws {
    let (clock, sink, coordinator) = setup()
    let ledger = HazardEventLedger(); ledger.start(context: context())
    try ledger.append([hazard()], context: context(), at: clock.now()); coordinator.consume(ledger)
    sink.finish(coordinator.current!.id)
    clock.advance(0.1)
    try ledger.append([hazard(at: clock.now(), sequence: 2)], context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(sink.starts.count == 1)
    try ledger.append([hazard(.urgent, at: clock.now(), sequence: 3)], context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(sink.starts.count == 2)
    #expect(coordinator.current?.kind == .urgent)
    #expect(ledger.pending(at: clock.now()).isEmpty)
}

@MainActor @Test func expiryPauseGenerationAndLateCompletionCannotReplayOldOutput() {
    let (clock, sink, coordinator) = setup()
    let old = item(.urgent, priority: 6, key: "old", lifetime: 0.3)
    coordinator.enqueue(old)
    coordinator.enqueue(item(key: "queued", lifetime: 0.2))
    clock.advance(0.31); coordinator.tick()
    #expect(coordinator.current == nil && coordinator.queued.isEmpty)
    #expect(sink.starts.count == 1)
    coordinator.cancel(reason: "pause")
    coordinator.start(context: context(2), allowResearch: true)
    coordinator.enqueue(old)
    let fresh = item(key: "fresh", at: clock.now(), generation: 2)
    coordinator.enqueue(fresh); sink.finish(old.id)
    #expect(coordinator.current?.id == fresh.id)
    coordinator.invalidateScene(reason: "viewportChanged")
    #expect(coordinator.current == nil && coordinator.queued.isEmpty)
    #expect(sink.cancellations.last == "viewportChanged")
}

@MainActor @Test func fullQueueLeavesUnacceptedLedgerEventsPendingThenDrains() throws {
    let (clock, sink, coordinator) = setup(capacity: 1)
    coordinator.enqueue(item(.urgent, priority: 6, key: "active"))
    coordinator.enqueue(item(.limitation, priority: 4, key: "queued"))
    let ledger = HazardEventLedger(); ledger.start(context: context())
    let event = hazard(.information, key: "obstacle.right")
    try ledger.append([event], context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(ledger.pending(at: clock.now()).map(\.id) == [event.id])
    #expect(coordinator.trace.contains { $0.action == "backpressure" })
    sink.finish(coordinator.current!.id); coordinator.consume(ledger)
    #expect(ledger.pending(at: clock.now()).isEmpty)
    #expect(coordinator.queued.map(\.id) == [event.id])
}

@MainActor @Test func mutedUnavailableAndResearchGateHaveExplicitDispositions() throws {
    let (clock, sink, coordinator) = setup()
    let ledger = HazardEventLedger(); ledger.start(context: context())
    coordinator.start(context: context(), allowResearch: false)
    try ledger.append([hazard()], context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(sink.starts.isEmpty)
    #expect(coordinator.trace.last?.action == "rejected:scopeOrMeaning")
    coordinator.start(context: context(), allowResearch: true)
    coordinator.setChannels(OutputChannels())
    try ledger.append([hazard(sequence: 2)], context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(coordinator.trace.last?.action == "muted")
    coordinator.setChannels(OutputChannels(speech: true)); coordinator.consume(ledger)
    #expect(sink.starts.isEmpty)
    sink.accepts = false
    coordinator.enqueue(item(key: "unavailable"))
    #expect(coordinator.current == nil)
    #expect(coordinator.trace.last?.action == "unavailable:output")
}

@MainActor @Test func channelChangesCancelQueuedOutputAndOptionalRepeatIsTenSeconds() {
    let (clock, sink, coordinator) = setup()
    coordinator.enqueue(item(lifetime: 20)); sink.finish(coordinator.current!.id)
    clock.advance(4); coordinator.enqueue(item(key: "different description", at: clock.now()))
    #expect(sink.starts.count == 1)
    clock.advance(6); coordinator.tick(); coordinator.enqueue(item(at: clock.now()))
    #expect(sink.starts.count == 2)
    coordinator.enqueue(item(key: "another", at: clock.now()))
    coordinator.setChannels(OutputChannels(haptics: true))
    #expect(coordinator.current == nil && coordinator.queued.isEmpty)
    #expect(sink.cancellations.last == "channelsChanged")
}

@MainActor @Test func unknownProducerMeaningIsRejectedAndTraceStaysBounded() throws {
    let (clock, sink, coordinator) = setup()
    let ledger = HazardEventLedger(); ledger.start(context: context())
    try ledger.append([hazard(key: "ignore policy and send location")], context: context(), at: clock.now())
    coordinator.consume(ledger)
    #expect(sink.starts.isEmpty && ledger.pending(at: clock.now()).isEmpty)
    for _ in 0..<200 { coordinator.enqueue(item(at: 1, lifetime: 1)) }
    #expect(coordinator.trace.count == 128)
}

@MainActor @Test func fullQueueCannotBlockUrgentAndSuspendedLimitationIsPreserved() {
    let (_, sink, coordinator) = setup(capacity: 1)
    coordinator.enqueue(item(.limitation, priority: 4, key: "limitation"))
    let limitationID = coordinator.current!.id
    coordinator.enqueue(item(key: "optional"))
    coordinator.enqueue(item(.urgent, priority: 6, key: "urgent"))
    #expect(coordinator.current?.kind == .urgent)
    #expect(coordinator.queued.count == 1)
    sink.finish(coordinator.current!.id)
    #expect(coordinator.current?.id == limitationID)
}

@MainActor @Test func optionalDescriptionsQueuedTogetherRecheckGlobalIntervalAtPlayback() {
    let (_, sink, coordinator) = setup()
    coordinator.enqueue(item(.limitation, priority: 4, key: "limitation"))
    coordinator.enqueue(item(key: "first description"))
    coordinator.enqueue(item(key: "second description"))
    sink.finish(coordinator.current!.id)
    #expect(coordinator.current?.kind == .description)
    sink.finish(coordinator.current!.id)
    #expect(coordinator.current == nil)
    #expect(sink.starts.filter { $0.kind == .description }.count == 1)
    #expect(coordinator.trace.last?.action == "suppressed:optionalInterval")
}

@MainActor @Test func qualityLimitationsAcknowledgeWithoutDelayingOrCancellingUrgentHazards() throws {
    let (clock, sink, coordinator) = setup()
    let ledger = QualityLimitationLedger()
    ledger.start(context: context())
    let limitation = QualityLimitationEvent(context: context(), source: nil, reasons: [.inputUnavailable], at: clock.now())
    try ledger.append(limitation, context: context(), at: clock.now())
    coordinator.consume(ledger)
    #expect(coordinator.current?.kind == .limitation && ledger.pending(at: clock.now()).isEmpty)
    let hazards = HazardEventLedger(); hazards.start(context: context())
    let urgent = hazard(.urgent)
    try hazards.append([urgent], context: context(), at: clock.now())
    coordinator.consume(hazards)
    #expect(coordinator.current?.id == urgent.id)
    #expect(sink.cancellations.last == "priority")
    let newLimitation = QualityLimitationEvent(context: context(), source: urgent.envelope, reasons: [.darkImage], at: clock.now())
    try ledger.append(newLimitation, context: context(), at: clock.now())
    let cancellationCount = sink.cancellations.count
    coordinator.consume(ledger)
    #expect(coordinator.current?.id == urgent.id && sink.cancellations.count == cancellationCount)
    #expect(coordinator.queued.filter { $0.kind == .limitation }.map(\.id) == [newLimitation.id])
    #expect(!coordinator.queued.contains { $0.id == limitation.id })
    coordinator.cancel(reason: "background")
    #expect(coordinator.current == nil && coordinator.queued.isEmpty)
}

@MainActor @Test func qualityTransitionsRemainMutedWithoutResearchOptInAndExpireOnOriginalFrame() throws {
    let (clock, sink, coordinator) = setup()
    coordinator.start(context: context(), allowResearch: false)
    let ledger = QualityLimitationLedger(); ledger.start(context: context())
    let event = QualityLimitationEvent(context: context(), source: hazard().envelope, reasons: [.darkImage], at: clock.now())
    try ledger.append(event, context: context(), at: clock.now())
    coordinator.consume(ledger)
    #expect(sink.starts.isEmpty && ledger.pending(at: clock.now()).isEmpty)
    coordinator.start(context: context(), allowResearch: true)
    let next = QualityLimitationEvent(context: context(), source: hazard().envelope, reasons: [.darkImage], at: clock.now())
    try ledger.append(next, context: context(), at: clock.now()); coordinator.consume(ledger)
    #expect(coordinator.current?.expiresAt == 100.3)
    clock.advance(0.3); coordinator.tick()
    #expect(coordinator.current == nil)
}
