import Foundation
import Testing
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk

private let qualitySession = UUID()
private func qualityContext(_ generation: UInt64 = 1, mode: SourceMode = .demoReplay) -> CaptureContext {
    CaptureContext(sessionID: qualitySession,generation: generation,mode: mode)
}
private func qualityFrame(sequence: UInt64 = 1, time: Double = 100, generation: UInt64 = 1,
                          tracking: TrackingQuality = .normal, cameraOnly: Bool = false,
                          transform: DisplayTransform = .identity) throws -> FrameDescriptor {
    let template = try GeometryFixture.load()[0].image(context: qualityContext(),sequence: 1,at: 100).frame
    let context = qualityContext(generation,mode: cameraOnly ? .cameraOnly : .demoReplay)
    return FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context,sequence: sequence),mode: context.mode,
        capturedAt: time,createdAt: time,lifetime: 0.3),imageSize: template.imageSize,
        depthSize: cameraOnly ? nil : template.depthSize,confidenceSize: cameraOnly ? nil : template.confidenceSize,
        intrinsics: template.intrinsics,cameraToWorld: template.cameraToWorld,orientation: template.orientation,
        viewportSize: template.viewportSize,imageToDisplay: transform,depthKind: cameraOnly ? .none : .sceneDepth,tracking: tracking)
}
private func fullDepth(_ frame: FrameDescriptor, value: Float = 1, confidence: UInt8 = 2) throws -> DepthImage {
    try DepthImage(frame: frame,values: [Float](repeating: value,count: 64*48),confidence: [UInt8](repeating: confidence,count: 64*48))
}
private func luma(_ frame: FrameDescriptor, value: UInt8? = nil) throws -> LumaImage {
    try LumaImage(frame: frame,size: PixelSize(width: 12,height: 9),
        values: (0..<108).map { value ?? ($0%2 == 0 ? 70 : 180) })
}

@Test func qualityGridUsesDisplayTransformAndKeepsCroppedRegionsUnknown() throws {
    let frame = try qualityFrame(transform: DisplayTransform(a: 1.0/3,b: 0,c: 0,d: 1,tx: 0,ty: 0))
    var evaluator = QualityEvaluator()
    let assessment = try evaluator.evaluate(frame: frame,depth: fullDepth(frame),image: luma(frame),context: qualityContext(),at: 100)
    let regions = try #require(assessment.details?.regions)
    #expect(regions.count == 9)
    #expect(regions.filter { $0.region == .left }.allSatisfy { $0.coverage == .high })
    #expect(regions.filter { $0.region != .left }.allSatisfy { $0.coverage == .unknown && $0.usableDepthFraction == nil && $0.image == nil })
    #expect(assessment.state == .limited)
}

@Test func qualityRecoveryNeedsTwoConsecutiveHealthyFramesAndRestartsAfterOutageOrGenerationChange() throws {
    var evaluator = QualityEvaluator()
    func assess(sequence: UInt64, time: Double, generation: UInt64 = 1, confidence: UInt8 = 2) throws -> QualityAssessment {
        let f = try qualityFrame(sequence: sequence,time: time,generation: generation)
        return try evaluator.evaluate(frame: f,depth: fullDepth(f,confidence: confidence),image: luma(f),context: qualityContext(generation),at: time)
    }
    #expect(try assess(sequence: 1,time: 100).state == .initializing)
    #expect(try assess(sequence: 2,time: 100.1).state == .active)
    #expect(try assess(sequence: 3,time: 100.2,confidence: 0).state == .unavailable)
    #expect(try assess(sequence: 4,time: 100.3).state == .initializing)
    #expect(try assess(sequence: 5,time: 100.4).state == .active)
    #expect(try assess(sequence: 6,time: 101).state == .initializing)
    #expect(try assess(sequence: 1,time: 101.1,generation: 2).state == .initializing)
}

@Test func darkClippedAndFlatImagesAreExplicitWhileDepthHazardsSurvive() async throws {
    for value: UInt8 in [0,255,128] {
        let depth = try fullDepth(qualityFrame())
        let engine = PerceptionEngine()
        let result = try await engine.process(depth,image: luma(depth.frame,value: value),context: qualityContext(),at: 100)
        #expect(result.quality.reasons.contains(value == 0 ? "darkImage" : (value == 255 ? "clippedImage" : "lowImageContrast")))
        #expect(result.quality.details?.regions.allSatisfy { $0.coverage == .high } == true)
        #expect(!result.observations.isEmpty)
        #expect(!HazardPolicy().evaluate(result,context: qualityContext(),at: 100).isEmpty)
    }
}

@Test func cameraOnlyAndMissingImageNeverClaimDepthCoverageOrActiveGeometry() throws {
    let frame = try qualityFrame(tracking: .unavailable,cameraOnly: true)
    var evaluator = QualityEvaluator()
    let result = try evaluator.evaluate(frame: frame,depth: nil,image: nil,context: qualityContext(mode: .cameraOnly),at: 100)
    #expect(result.state == .limited && result.usableDepthFraction == nil)
    #expect(result.reasons.contains("cameraOnlyNoDepth") && result.reasons.contains("imageConditionsUnknown"))
    #expect(result.details?.worldDependentFunctionsSupported == false)
    #expect(result.details?.regions.allSatisfy { $0.coverage == .unknown && !$0.confidenceKnown } == true)
    // One measured image cell cannot establish image conditions for the entire viewport.
    let depthFrame = try qualityFrame(sequence: 2,time: 100.1)
    let partialImage = try LumaImage(frame: depthFrame,size: PixelSize(width: 1,height: 1),values: [128])
    let partial = try evaluator.evaluate(frame: depthFrame,depth: fullDepth(depthFrame),image: partialImage,context: qualityContext(),at: 100.1)
    #expect(partial.state == .limited && partial.reasons.contains("imageConditionsUnknown"))
}

@Test func qualityRejectsStaleMixedDuplicateAndPreviousGenerationInputs() throws {
    var evaluator = QualityEvaluator()
    let frame = try qualityFrame(), other = try qualityFrame(sequence: 2)
    #expect(throws: ContractError.self) { try evaluator.evaluate(frame: frame,depth: fullDepth(frame),image: luma(other),context: qualityContext(),at: 100) }
    _ = try evaluator.evaluate(frame: frame,depth: fullDepth(frame),image: nil,context: qualityContext(),at: 100)
    #expect(throws: ContractError.self) { try evaluator.evaluate(frame: frame,depth: fullDepth(frame),image: nil,context: qualityContext(),at: 100) }
    #expect(throws: ContractError.self) { try evaluator.evaluate(frame: other,depth: fullDepth(other),image: nil,context: qualityContext(),at: 100.3) }
    #expect(throws: ContractError.self) { try evaluator.evaluate(frame: other,depth: fullDepth(other),image: nil,context: qualityContext(2),at: 100) }
}

@Test func changedRangeRecordsUncertaintyWithoutSuppressingCloseGeometry() async throws {
    let engine = PerceptionEngine()
    let first = try fullDepth(qualityFrame(),value: 2)
    _ = try await engine.process(first,context: qualityContext(),at: 100)
    let close = try fullDepth(qualityFrame(sequence: 2,time: 100.1),value: 0.8)
    let result = try await engine.process(close,context: qualityContext(),at: 100.1)
    #expect(result.quality.reasons.contains("geometryChangedAssociationUnknown"))
    #expect(HazardPolicy().evaluate(result,context: qualityContext(),at: 100.1).contains { $0.urgency == .urgent })
    let decision = DisagreementPolicy.evaluate(result,labels: [],context: qualityContext(),at: 100.1)
    #expect(decision.retainedGeometryIDs == result.observations.map(\.id))
    #expect(decision.reasons.contains("geometryChangedAssociationUnknown"))
}

@Test func labelsCannotRemoveRaisedGeometryOrDeclareAnExitTraversable() async throws {
    let depth = try fullDepth(qualityFrame(tracking: .limited))
    let result = try await PerceptionEngine().process(depth,context: qualityContext(),at: 100)
    let original = try #require(result.observations.first), d = try #require(original.details)
    let raised = GeometryObservation(id: original.id,envelope: original.envelope,opticalPoint: original.opticalPoint,
        axialDepthMeters: original.axialDepthMeters,rangeMeters: original.rangeMeters,
        details: GeometryDetails(imageBounds: d.imageBounds,displayBounds: d.displayBounds,corridor: d.corridor,
            bearingRadians: d.bearingRadians,supportCount: d.supportCount,groundRelation: .raised,heightAboveGroundMeters: 0.4,evidence: d.evidence))
    let input = GeometryResult(frame: result.frame,observations: [raised],regions: result.regions,ground: result.ground,quality: result.quality,discardedSmallComponents: 0)
    let decision = DisagreementPolicy.evaluate(input,labels: [
        SemanticEvidence(envelope: depth.frame.envelope,meaning: .floor,associatedGeometryID: raised.id),
        SemanticEvidence(envelope: depth.frame.envelope,meaning: .exit)
    ],context: qualityContext(),at: 100)
    #expect(decision.retainedGeometryIDs == [raised.id])
    #expect(decision.reasons.contains("floorLabelConflictsWithRaisedGeometry"))
    #expect(decision.reasons.contains("candidateTraversabilityUnknown") && decision.reasons.contains("labelDistanceUnknown"))
    #expect(!decision.worldDependentFunctionsSupported)
    #expect(DisagreementPolicy.evaluate(input,labels: [],context: qualityContext(),at: 100.3).retainedGeometryIDs.isEmpty)
}

@Test func qualityDetailsAreOptionalForOldFixturesAndLumaBudgetIsEnforced() throws {
    let old = Data(#"{"state":"limited","reasons":["synthetic"]}"#.utf8)
    #expect(try JSONDecoder().decode(QualityAssessment.self,from: old).details == nil)
    let frame = try qualityFrame()
    #expect(throws: ContractError.self) { try LumaImage(frame: frame,size: PixelSize(width: Int.max,height: 3),values: []) }
    #expect(throws: ContractError.self) { try LumaImage(frame: frame,size: PixelSize(width: 129,height: 129),values: [UInt8](repeating: 0,count: 129*129)) }
}

@Test func coverageThresholdsAreRegionalAndDoNotAverageAwayASparseSector() throws {
    let template = try qualityFrame()
    let size = PixelSize(width: 30,height: 30)
    let frame = FrameDescriptor(envelope: template.envelope,imageSize: template.imageSize,depthSize: size,confidenceSize: size,
        intrinsics: template.intrinsics,cameraToWorld: template.cameraToWorld,orientation: template.orientation,
        viewportSize: template.viewportSize,imageToDisplay: .identity,depthKind: .sceneDepth,tracking: .normal)
    for (count, expected): (Int,CoverageCategory) in [(29,.sparse),(30,.limited),(69,.limited),(70,.high)] {
        var values = [Float](repeating: 1,count: 900), confidence = [UInt8](repeating: 1,count: 900)
        for y in 0..<10 { for x in 0..<10 {
            if y*10+x >= count { values[y*30+x] = 0; confidence[y*30+x] = 0 }
        } }
        var evaluator = QualityEvaluator()
        let depth = try DepthImage(frame: frame,values: values,confidence: confidence)
        let result = try evaluator.evaluate(frame: frame,depth: depth,image: nil,context: qualityContext(),at: 100)
        let region = try #require(result.details?.regions.first)
        #expect(region.coverage == expected)
        #expect(region.usableDepthPixels == count && region.sampledDepthPixels == 100)
        #expect(region.lowConfidencePixels == 100-count && region.mediumConfidencePixels == count && region.highConfidencePixels == 0)
        #expect(result.details?.regions.dropFirst().allSatisfy { $0.coverage == .high } == true)
        #expect(result.reasons.contains("partialDepthCoverage") == (expected != .high))
    }
}

@Test func missingConfidenceAndAbsentLabelsPreserveGeometryAlongsideUnknownRegions() async throws {
    let depth = try GeometryFixture.load()[4].image(context: qualityContext(),sequence: 1,at: 100)
    let result = try await PerceptionEngine().process(depth,image: luma(depth.frame,value: 0),context: qualityContext(),at: 100)
    #expect(result.quality.details?.regions.allSatisfy { !$0.confidenceKnown && $0.highConfidencePixels == nil && $0.lowConfidencePixels == nil } == true)
    let other = try qualityFrame(sequence: 2)
    let decision = DisagreementPolicy.evaluate(result,labels: [SemanticEvidence(envelope: other.envelope,meaning: .floor)],context: qualityContext(),at: 100)
    #expect(!decision.retainedGeometryIDs.isEmpty)
    #expect(decision.reasons.contains("genericGeometryWithoutLabel"))
    #expect(decision.reasons.contains("unobservedRegionNotClearOrHole"))
    #expect(!decision.reasons.contains("floorLabelConflictsWithRaisedGeometry"))
    #expect(!HazardPolicy().evaluate(result,context: qualityContext(),at: 100).isEmpty)
}

private final class QualityClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ delta: TimeInterval) { lock.withLock { value += delta } }
}

@Test func cameraOnlyImageRecoveryIsExplicitWithoutInventingDepthSupport() throws {
    var evaluator = QualityEvaluator()
    let context = qualityContext(mode: .cameraOnly)
    func assess(_ sequence: UInt64, _ time: Double, _ dark: Bool = false) throws -> QualityAssessment {
        let frame = try qualityFrame(sequence: sequence, time: time, cameraOnly: true)
        return try evaluator.evaluate(frame: frame, depth: nil, image: luma(frame, value: dark ? 0 : nil), context: context, at: time)
    }
    #expect(try assess(1, 100).state == .initializing)
    let recovered = try assess(2, 100.1)
    #expect(recovered.state == .limited && recovered.usableDepthFraction == nil)
    #expect(!recovered.reasons.contains("awaitingQualityRecovery"))
    #expect(recovered.details?.regions.allSatisfy { $0.coverage == .unknown } == true)
    #expect(try assess(3, 100.2, true).reasons.contains("darkImage"))
    #expect(try assess(4, 100.3).state == .initializing)
    #expect(try assess(5, 100.4).state == .limited)
}

@MainActor @Test func qualityTransitionsSurviveCoalescingAndDoNotRepeatEachFrame() async throws {
    let clock = QualityClock()
    // Use one injected clock for every frame deadline in this test.
    let active = QualitySessionPipeline(clock: clock)
    active.start(context: qualityContext(mode: .cameraOnly))
    for sequence: UInt64 in 1...3 {
        let frame = try qualityFrame(sequence: sequence, time: clock.now(), cameraOnly: true)
        let result = try await active.process(frame: frame, depth: nil, image: luma(frame, value: 0))
        #expect(result?.quality.reasons.contains("darkImage") == true)
        #expect(result?.geometry.isEmpty == true && result?.events.isEmpty == true)
        clock.advance(0.05)
    }
    let events = active.ledger.pending(at: clock.now())
    #expect(events.count == 1 && events[0].reasons.contains(.darkImage))
    #expect(active.ledger.acknowledge(events[0].id, context: qualityContext(mode: .cameraOnly), at: clock.now()))
    #expect(active.ledger.pending(at: clock.now()).isEmpty)
    // Geometry and quality paths never need a consumer to read presentation snapshots.
}

@MainActor @Test func qualityWatchdogOutageHasNoFrameAndRecoveryRetainsSequenceWatermark() async throws {
    let clock = QualityClock()
    let active = QualitySessionPipeline(clock: clock)
    let context = qualityContext(mode: .cameraOnly)
    active.start(context: context)
    let frame = try qualityFrame(cameraOnly: true)
    _ = try await active.process(frame: frame, depth: nil, image: luma(frame))
    clock.advance(0.4)
    try active.markUnavailable()
    #expect(active.snapshot?.frame == nil && active.snapshot?.quality.state == .unavailable)
    let outage = try #require(active.ledger.pending(at: clock.now()).first)
    #expect(outage.source == nil && outage.reasons == [.inputUnavailable])
    #expect(outage.expiresAt == clock.now() + QualityConfiguration.current.limitationEventLifetime)
    try active.markUnavailable()
    #expect(active.ledger.pending(at: clock.now()).map(\.id) == [outage.id])
    let repeatedSequence = try qualityFrame(sequence: 1, time: clock.now(), cameraOnly: true)
    #expect(try await active.process(frame: repeatedSequence, depth: nil, image: luma(repeatedSequence)) == nil)
    #expect(try await active.process(frame: frame, depth: nil, image: luma(frame)) == nil)
    let fresh = try qualityFrame(sequence: 2, time: clock.now(), cameraOnly: true)
    #expect(try await active.process(frame: fresh, depth: nil, image: luma(fresh))?.quality.state == .initializing)
    active.stop()
    #expect(active.snapshot == nil && active.ledger.pending(at: clock.now()).isEmpty)
}

@MainActor @Test func qualityLedgerRejectsStaleGenerationAndPreservesBackpressure() throws {
    let ledger = QualityLimitationLedger(capacity: 1), context = qualityContext()
    ledger.start(context: context)
    let event = QualityLimitationEvent(context: context, source: nil, reasons: [.inputUnavailable], at: 100)
    try ledger.append(event, context: context, at: 100)
    #expect(throws: QualityLedgerError.capacityExceeded) {
        try ledger.append(QualityLimitationEvent(context: context, source: nil, reasons: [.inputUnavailable], at: 100), context: context, at: 100)
    }
    #expect(ledger.pending(at: 100) == [event])
    #expect(!ledger.acknowledge(event.id, context: qualityContext(2), at: 100))
    #expect(ledger.acknowledge(event.id, context: context, at: 100))
    try ledger.append(event, context: context, at: 100)
    #expect(ledger.pending(at: 100).isEmpty)
    ledger.start(context: qualityContext(2))
    #expect(throws: QualityLedgerError.invalidEvent) { try ledger.append(event, context: qualityContext(2), at: 100) }
    #expect(!QualityLimitationEvent(context: context, source: nil, reasons: [.qualityRecovered], at: 100).isCurrent(in: context, at: 100))
}

@MainActor @Test func stoppingQualityDuringTransitionCannotPublishAnOldSnapshot() async throws {
    let clock = QualityClock()
    let active = QualitySessionPipeline(clock: clock)
    active.start(context: qualityContext(mode: .cameraOnly))
    active.ledger.onEventsAvailable = { _ in active.stop() }
    let frame = try qualityFrame(cameraOnly: true)
    #expect(try await active.process(frame: frame, depth: nil, image: luma(frame)) == nil)
    #expect(active.snapshot == nil)
}
