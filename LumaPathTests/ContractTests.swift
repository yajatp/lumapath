import Foundation
import Testing
@testable import LumaPathDomain

private struct FixedClock: MonotonicClock {
    let time: TimeInterval
    func now() -> TimeInterval { time }
}

private func frame(context: CaptureContext, sequence: UInt64 = 1, capturedAt: Double = 100) throws -> FrameDescriptor {
    let template = try ReplayFixtures.frames()[0]
    return FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context, sequence: sequence), mode: context.mode,
        capturedAt: capturedAt, createdAt: capturedAt, lifetime: 0.3), imageSize: template.imageSize,
        depthSize: context.mode == .cameraOnly ? nil : template.depthSize,
        confidenceSize: context.mode == .cameraOnly ? nil : template.confidenceSize,
        intrinsics: template.intrinsics, cameraToWorld: template.cameraToWorld, orientation: template.orientation,
        viewportSize: template.viewportSize, imageToDisplay: template.imageToDisplay,
        depthKind: context.mode == .cameraOnly ? .none : template.depthKind, tracking: .normal)
}
private let active = QualityAssessment(state: .active, reasons: ["synthetic"])

@Test func envelopeRejectsFutureSchemasAndInvalidClocks() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
    var envelope = ObservationEnvelope(frameID: FrameID(context: context, sequence: 1), mode: .demoReplay,
                                       capturedAt: 10, createdAt: 10, lifetime: 0.3)
    #expect(envelope.isCurrent(in: context, at: 10))
    #expect(!envelope.isCurrent(in: context, at: 9.99))
    #expect(!envelope.isCurrent(in: context, at: 10.3))
    let futureCreation = ObservationEnvelope(frameID: envelope.frameID, mode: .demoReplay,
        capturedAt: 10, createdAt: 10.2, lifetime: 0.3)
    #expect(!futureCreation.isCurrent(in: context, at: 10.1))
    envelope.schemaVersion = 3
    let decoded = try JSONDecoder().decode(ObservationEnvelope.self, from: JSONEncoder().encode(envelope))
    #expect(throws: ContractError.unsupportedSchema(3)) { try decoded.validate() }
    #expect(!decoded.isCurrent(in: context, at: 10))
    let invalid = ObservationEnvelope(frameID: envelope.frameID, mode: .demoReplay,
                                      capturedAt: .nan, createdAt: 10, lifetime: 0.3)
    #expect(throws: ContractError.self) { try invalid.validate() }
}

@Test func lifecycleRejectsStaleWrongSessionWrongModeAndOutOfOrderFrames() throws {
    var state = SessionState(mode: .demoReplay)
    state.start()
    let current = try frame(context: state.context, sequence: 2)
    #expect(state.accept(current, quality: active, at: 101) == false)
    #expect(state.accept(current, quality: active, at: 100) == true)
    #expect(state.accept(current, quality: active, at: 100) == false)
    #expect(state.accept(try frame(context: state.context, sequence: 1), quality: active, at: 100) == false)
    let other = CaptureContext(sessionID: UUID(), generation: state.context.generation, mode: .demoReplay)
    #expect(state.accept(try frame(context: other), quality: active, at: 100) == false)
    let live = CaptureContext(sessionID: state.context.sessionID, generation: state.context.generation, mode: .liveDepth)
    #expect(state.accept(try frame(context: live, sequence: 3), quality: active, at: 100) == false)
    state.pause()
    #expect(state.snapshot.frame == nil)
    #expect(state.snapshot.events.isEmpty)
    #expect(state.accept(current, quality: active, at: 100) == false)
    state.start()
    #expect(state.lifecycle == .preparing)
    #expect(state.accept(current, quality: active, at: 100) == false)
    #expect(state.accept(try frame(context: state.context), quality: active, at: 100) == true)
    state.end()
    let oldID = state.context.sessionID
    state.start()
    #expect(state.context.sessionID != oldID)
    #expect(state.frame == nil)
}

@Test func expiryClearsGeometryAndEventsAndKeepsSequenceWatermark() throws {
    var state = SessionState(mode: .demoReplay)
    state.start()
    let input = try frame(context: state.context)
    let point = OpticalPoint(x: 0, y: 0, z: 2)
    let geometry = GeometryObservation(id: UUID(), envelope: input.envelope, opticalPoint: point, axialDepthMeters: 2, rangeMeters: 2)
    let event = HazardEvent(id: UUID(), envelope: input.envelope, geometryIDs: [geometry.id], urgency: .urgent, messageKey: "synthetic")
    #expect(state.accept(input, quality: active, geometry: [geometry], events: [event], at: 100) == true)
    #expect(state.events.count == 1)
    state.expire(at: 100.3)
    #expect(state.frame == nil)
    #expect(state.geometry.isEmpty)
    #expect(state.events.isEmpty)
    #expect(state.quality.state == .unavailable)
    #expect(state.accept(input, quality: active, at: 100.1) == false)
    #expect(state.accept(try frame(context: state.context, sequence: 2, capturedAt: 101), quality: active, at: 101) == true)
}

@Test func unrelatedGeometryCannotEnterPresentationOrSupportAnEvent() throws {
    var state = SessionState(mode: .demoReplay)
    state.start()
    let input = try frame(context: state.context)
    let other = try frame(context: state.context, sequence: 2)
    let geometry = GeometryObservation(id: UUID(), envelope: other.envelope, opticalPoint: OpticalPoint(x: 0, y: 0, z: 2),
                                       axialDepthMeters: 2, rangeMeters: 2)
    let event = HazardEvent(id: UUID(), envelope: input.envelope, geometryIDs: [geometry.id], urgency: .warning, messageKey: "synthetic")
    state.accept(input, quality: active, geometry: [geometry], events: [event], at: 100)
    #expect(state.geometry.isEmpty)
    #expect(state.events.isEmpty)
}

@Test func generatedCalibrationFixturesCoverOrientationsAndUnknownConfidence() throws {
    let frames = try ReplayFixtures.frames()
    #expect(Set(frames.map(\.orientation)).count == 4)
    #expect(frames.contains { $0.confidenceSize == nil })
    #expect(frames.allSatisfy { $0.imageSize != $0.depthSize })
    for input in frames {
        let center = input.imageToDisplay.apply(x: 0.5, y: 0.5)
        #expect(abs(center.x - 0.5) < 1e-9 && abs(center.y - 0.5) < 1e-9)
        let k = input.intrinsics!.scaled(from: input.imageSize, to: input.depthSize!)
        let point = try #require(FrameGeometry.unproject(u: k.cx, v: k.cy, axialDepth: 2, frame: input))
        #expect(point == OpticalPoint(x: 0, y: 0, z: 2))
        #expect(point.arKitCameraPoint == SIMD3(0, 0, -2))
        let offAxis = try #require(FrameGeometry.unproject(u: k.cx + 10, v: k.cy + 5, axialDepth: 2, frame: input))
        #expect(abs(offAxis.x - 0.16) < 1e-9)
        #expect(abs(offAxis.y - 0.08) < 1e-9)
        #expect(offAxis.range > offAxis.z)
        #expect(FrameGeometry.unproject(u: 0, v: 0, axialDepth: .nan, frame: input) == nil)
        #expect(FrameGeometry.unproject(u: 0, v: 0, axialDepth: 0, frame: input) == nil)
        #expect(FrameGeometry.unproject(u: -1, v: 0, axialDepth: 2, frame: input) == nil)
    }
    #expect(frames[1].imageToDisplay.apply(x: 0, y: 0) == SIMD2(1, 0))
    #expect(frames[2].imageToDisplay.apply(x: 0, y: 0) == SIMD2(1, 1))
    #expect(frames[3].imageToDisplay.apply(x: 0, y: 0) == SIMD2(0, 1))
    #expect(!frames[0].matches(frames[1]))
    // PNG IHDR dimensions must match the first descriptor in the static pair.
    let image = try Data(contentsOf: ReplayFixtures.url("synthetic-scene.png"))
    let width = image[16..<20].reduce(0) { ($0 << 8) | Int($1) }
    let height = image[20..<24].reduce(0) { ($0 << 8) | Int($1) }
    #expect(PixelSize(width: width, height: height) == frames[0].imageSize)
}

@Test func unknownDepthAndCameraOnlyRemainExplicit() throws {
    var state = SessionState(mode: .cameraOnly)
    state.start()
    let input = try frame(context: state.context)
    try input.validate()
    #expect(input.depthSize == nil && input.confidenceSize == nil && input.depthKind == .none)
    #expect(FrameGeometry.unproject(u: 1, v: 1, axialDepth: 2, frame: input) == nil)
    let limited = QualityAssessment(state: .limited, reasons: ["depthUnavailable"])
    state.accept(input, quality: limited, at: 100)
    #expect(state.quality.usableDepthFraction == nil)
    #expect(state.geometry.isEmpty)
}

@Test func watchdogReportsOnceAndRecoversOnNewInput() {
    var watchdog = FreshnessWatchdog(startedAt: 10)
    #expect(watchdog.check(at: 10.49) == false)
    #expect(watchdog.check(at: 10.5) == true)
    #expect(watchdog.check(at: 11) == false)
    watchdog.received(at: 12)
    #expect(watchdog.check(at: 12.1) == false)
    #expect(watchdog.check(at: 12.5) == true)
}

@Test @MainActor func boundedStoreEvictsAndInvalidatesAllLeasesOnStop() {
    let store = FrameStore<Int>()
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    for i in 1...20 { store.insert(i, for: FrameID(context: context, sequence: UInt64(i))) }
    #expect(store.count == 3)
    #expect(!store.withValue(for: FrameID(context: context, sequence: 17)) { _ in Issue.record("Evicted frame accessed") })
    var value: Int?
    #expect(store.withValue(for: FrameID(context: context, sequence: 20)) { value = $0 })
    #expect(value == 20)
    store.removeAll()
    #expect(store.count == 0)
    #expect(!store.withValue(for: FrameID(context: context, sequence: 20)) { _ in Issue.record("Stopped frame accessed") })
}

@Test @MainActor func replayPublishesRebasedOrdinaryLimitedPausedAndUnavailableSnapshots() async throws {
    let replay = try ReplaySession(clock: FixedClock(time: 900))
    var consumer = replay.snapshots.makeAsyncIterator()
    replay.expire() // Idle polling must not publish a snapshot that blocks Start.
    replay.start()
    let ordinary = try #require(await consumer.next())
    #expect(ordinary.context.mode == .demoReplay && ordinary.quality.state == .active)
    #expect(ordinary.frame?.envelope.captureTimeMonotonic == 900)
    #expect(ordinary.events.count == 1 && ordinary.geometry.count == 1)
    replay.advance()
    let limited = try #require(await consumer.next())
    #expect(limited.quality.state == .limited && limited.events.count == 1)
    replay.advance()
    let paused = try #require(await consumer.next())
    #expect(paused.lifecycle == .paused && paused.events.isEmpty && paused.frame == nil)
    replay.resume()
    let unavailable = try #require(await consumer.next())
    #expect(unavailable.quality.state == .unavailable && unavailable.events.isEmpty && unavailable.frame == nil)
    #expect(unavailable.context.generation > ordinary.context.generation)
    replay.advance()
    let recovered = try #require(await consumer.next())
    #expect(recovered.quality.state == .active)
    replay.end()
    let ended = try #require(await consumer.next())
    #expect(ended.lifecycle == .ended && ended.events.isEmpty)
}

@Test @MainActor func snapshotTransportKeepsNewestAndCancellationDoesNotReplayOldEvents() async throws {
    let replay = try ReplaySession(clock: FixedClock(time: 500))
    replay.start()
    replay.advance()
    replay.pause()
    var consumer = replay.snapshots.makeAsyncIterator()
    let newest = try #require(await consumer.next())
    #expect(newest.lifecycle == .paused && newest.events.isEmpty)
}
