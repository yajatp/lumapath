import Foundation
import Testing
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk

private struct Clock: MonotonicClock { let time: Double; func now() -> TimeInterval { time } }
private let session = UUID(uuidString: "00000000-0000-0000-0000-0000000000a3")!
private func context(_ generation: UInt64 = 1) -> CaptureContext { CaptureContext(sessionID: session,generation: generation,mode: .demoReplay) }
private func scene(_ index: Int,sequence: UInt64 = 1,at time: Double = 100,context current: CaptureContext = context()) throws -> DepthImage {
    try GeometryFixture.load()[index].image(context: current,sequence: sequence,at: time)
}
private func replacing(_ input: DepthImage,values: [Float]? = nil,confidence: [UInt8]? = nil,
                       transform: DisplayTransform? = nil,tracking: TrackingQuality? = nil) throws -> DepthImage {
    let f = input.frame
    let frame = FrameDescriptor(envelope: f.envelope,imageSize: f.imageSize,depthSize: f.depthSize,confidenceSize: f.confidenceSize,
        intrinsics: f.intrinsics,cameraToWorld: f.cameraToWorld,orientation: f.orientation,viewportSize: f.viewportSize,
        imageToDisplay: transform ?? f.imageToDisplay,depthKind: f.depthKind,tracking: tracking ?? f.tracking)
    return try DepthImage(frame: frame,values: values ?? input.values,confidence: confidence ?? input.confidence)
}

@Test func aheadAndSideHaveDifferentRelevanceAndFirstCloseEventIsImmediate() throws {
    var processor = GeometryProcessor()
    let ahead = try processor.process(scene(0),context: context(),at: 100)
    let side = try processor.process(scene(1,sequence: 2),context: context(),at: 100)
    #expect(ahead.observations.count == 1 && side.observations.count == 1)
    #expect(ahead.observations[0].details?.corridor == .ahead)
    #expect(side.observations[0].details?.corridor == .right)
    let policy = HazardPolicy()
    #expect(policy.evaluate(ahead,context: context(),at: 100).first?.urgency == .warning)
    #expect(policy.evaluate(side,context: context(),at: 100).first?.urgency == .information)
    let close = try processor.process(scene(2,sequence: 3),context: context(),at: 100)
    let immediate = try #require(policy.evaluate(close,context: context(),at: 100).first)
    #expect(immediate.urgency == .urgent && immediate.deliveryScope == .research)
    #expect(immediate.envelope.expiresAtMonotonic == 100.3)
    #expect(immediate.messageKey == "obstacle.ahead")
    #expect(policy.evaluate(close,context: context(),at: 100.3).isEmpty)
}

@Test func invalidLowConfidenceAndOutOfRangeSamplesNeverCreateClearSpaceOrHazards() throws {
    let empty = try scene(3)
    var processor = GeometryProcessor()
    for value: Float in [.nan,.infinity,-1,0,0.1,5] {
        let depth = try replacing(empty,values: [Float](repeating: value,count: empty.values.count))
        let result = try processor.process(depth,context: context(),at: 100)
        #expect(result.observations.isEmpty && result.quality.state == .unavailable)
        #expect(result.regions.allSatisfy { $0.nearestRangeMeters == nil })
    }
    let lowConfidence = try processor.process(scene(6),context: context(),at: 100)
    #expect(lowConfidence.observations.isEmpty)
    #expect(lowConfidence.quality.reasons.contains("noUsableDepth"))
    let input = try scene(0)
    let invalidConfidence = try replacing(input,confidence: [UInt8](repeating: 255,count: input.values.count))
    #expect(try processor.process(invalidConfidence,context: context(),at: 100).observations.isEmpty)
}

@Test func missingConfidenceRetainsGeometryAndAnObstacleCanCoexistWithBlindRegions() throws {
    var processor = GeometryProcessor()
    let result = try processor.process(scene(4),context: context(),at: 100)
    #expect(result.observations.count == 1)
    #expect(result.observations[0].details?.evidence == .confidenceUnknown)
    #expect(result.quality.reasons.contains("confidenceUnknown"))
    #expect(result.quality.state == .limited)
    #expect(result.regions.first(where: { $0.region == .left })?.coverage == 0)
    #expect(result.regions.first(where: { $0.region == .left })?.nearestRangeMeters == nil)
    #expect(HazardPolicy().evaluate(result,context: context(),at: 100).count == 1)
    #expect(result.ground.status == .unknown)
}

@Test func spatialClustersRejectIsolatedSpecklesWithoutMixingDepthSurfaces() throws {
    let input = try scene(0)
    var values = input.values
    values[16*64+28] = 0.31 // One unsupported close pixel in an otherwise 2 m tile.
    var processor = GeometryProcessor()
    let result = try processor.process(replacing(input,values: values),context: context(),at: 100)
    #expect(result.observations.count == 1)
    #expect(abs(result.observations[0].axialDepthMeters-2) < 1e-6)
    let empty = try scene(3)
    values = empty.values
    for v in 10..<12 { for u in 10..<12 { values[v*64+u] = 1 } }
    let confidence = [UInt8](repeating: 2,count: values.count)
    let speckle = try processor.process(replacing(empty,values: values,confidence: confidence),context: context(),at: 100)
    #expect(speckle.observations.isEmpty && speckle.discardedSmallComponents == 1)
}

@Test func componentsSeparateAcrossUnknownGapsAndDepthDiscontinuities() throws {
    let input = try scene(0)
    var values = input.values
    for v in 16..<28 { for u in 32..<36 { values[v*64+u] = 3 } }
    var processor = GeometryProcessor()
    let split = try processor.process(replacing(input,values: values),context: context(),at: 100)
    #expect(split.observations.count == 2)
    #expect(Set(split.observations.map(\.axialDepthMeters)) == Set([2,3]))
    values = input.values
    for v in 16..<28 { for u in 30..<34 { values[v*64+u] = 0 } }
    #expect(try processor.process(replacing(input,values: values),context: context(),at: 100).observations.count == 2)
}

@Test func groundNeedsCalibrationBroadSupportAndTemporalConsistency() throws {
    var uncalibrated = GeometryProcessor()
    let unknown = try uncalibrated.process(scene(5),context: context(),at: 100)
    #expect(unknown.ground.status == .unknown)
    #expect(unknown.observations.count >= 2) // Low points are retained without a trustworthy floor.
    var calibrated = GeometryProcessor(configuration: GeometryConfiguration(calibratedCameraHeight: 1))
    let first = try calibrated.process(scene(5),context: context(),at: 100)
    #expect(first.ground.status == .candidate)
    let second = try calibrated.process(scene(5,sequence: 2,at: 100.1),context: context(),at: 100.1)
    #expect(second.ground.status == .confirmed)
    #expect(second.ground.supportingSamples >= 100)
    #expect(second.observations.count == 1)
    #expect(second.observations[0].details?.groundRelation == .raised)
    #expect(abs(second.ground.worldHeightMeters ?? 100) < 0.01)
    let newGeneration = try calibrated.process(scene(5,sequence: 1,at: 100.2,context: context(2)),context: context(2),at: 100.2)
    #expect(newGeneration.ground.status == .candidate)
    let trackingLost = try calibrated.process(replacing(scene(5,sequence: 2,at: 100.3,context: context(2)),tracking: .unavailable),context: context(2),at: 100.3)
    #expect(trackingLost.ground.status == .unknown)
    #expect(trackingLost.observations.allSatisfy { $0.details?.groundRelation == .unclassified })
    #expect(trackingLost.observations.allSatisfy { $0.details?.corridor == .unknown })
}

@Test func projectionUsesScaledIntrinsicsAndTheDisplayTransformExactlyOnce() throws {
    let input = try scene(0)
    var processor = GeometryProcessor()
    let plain = try processor.process(input,context: context(),at: 100)
    let rect = try #require(plain.observations.first?.details?.displayBounds)
    #expect(abs(rect.minX-28.0/64) < 1e-9 && abs(rect.maxX-36.0/64) < 1e-9)
    #expect(abs(rect.minY-16.0/48) < 1e-9 && abs(rect.maxY-28.0/48) < 1e-9)
    let rotate = DisplayTransform(a: 0,b: 1,c: -1,d: 0,tx: 1,ty: 0)
    let frame = try replacing(input,transform: rotate)
    let rotated = try processor.process(frame,context: context(),at: 100)
    let result = try #require(rotated.observations.first?.details?.displayBounds)
    #expect(abs(result.minX-(1-rect.maxY)) < 1e-9)
    #expect(abs(result.minY-rect.minX) < 1e-9)
    let point = plain.observations[0].opticalPoint
    let mapped = try #require(GeometryProjection.displayPoint(point,frame: frame.frame))
    let original = try #require(GeometryProjection.displayPoint(point,frame: input.frame))
    #expect(abs(mapped.x-(1-original.y)) < 1e-9 && abs(mapped.y-original.x) < 1e-9)
}

@Test func depthShapeAndStaleGenerationAreRejectedAndOldOptionalContractsDecode() throws {
    let image = try scene(0)
    #expect(throws: ContractError.self) { try DepthImage(frame: image.frame,values: [],confidence: []) }
    var processor = GeometryProcessor()
    #expect(throws: ContractError.self) { try processor.process(image,context: context(2),at: 100) }
    #expect(throws: ContractError.self) { try processor.process(image,context: context(),at: 100.3) }
    let oldEvent = HazardEvent(id: UUID(),envelope: image.frame.envelope,geometryIDs: [UUID()],urgency: .warning,messageKey: "demo")
    let encoded = try JSONEncoder().encode(oldEvent)
    let decoded = try JSONDecoder().decode(HazardEvent.self,from: encoded)
    #expect(decoded.deliveryScope == nil && decoded.corridor == nil)
}

@Test @MainActor func ledgerPersistsFirstEventAcrossCoalescedFramesAndRequiresAcknowledgment() async throws {
    let pipeline = GeometryPipeline(clock: Clock(time: 100))
    pipeline.start(context: context())
    var signalled = 0
    pipeline.ledger.onEventsAvailable = { _ in signalled += 1 }
    let first = try #require(try await pipeline.process(scene(2)))
    let firstEvent = try #require(first.events.first)
    #expect(signalled == 1) // Signal comes from the ledger, before presentation consumes a snapshot.
    _ = try await pipeline.process(scene(0,sequence: 2))
    let pending = pipeline.ledger.pending(at: 100)
    #expect(pending.count == 2 && pending.first?.urgency == .urgent)
    #expect(pending.contains { $0.id == firstEvent.id })
    #expect(pipeline.ledger.acknowledge(firstEvent.id,context: context(),at: 100))
    #expect(!pipeline.ledger.acknowledge(firstEvent.id,context: context(),at: 100))
    try pipeline.ledger.append([firstEvent],context: context(),at: 100)
    #expect(pipeline.ledger.pending(at: 100).count == 1)
    #expect(pipeline.ledger.pending(at: 100.3).isEmpty)
    pipeline.stop()
    #expect(pipeline.ledger.pending(at: 100).isEmpty)
}

@Test @MainActor func ledgerOverflowIsExplicitAtomicAndDoesNotEvictAnUrgentEvent() throws {
    var processor = GeometryProcessor()
    let urgent = HazardPolicy().evaluate(try processor.process(scene(2),context: context(),at: 100),context: context(),at: 100)
    let warning = HazardPolicy().evaluate(try processor.process(scene(0,sequence: 2),context: context(),at: 100),context: context(),at: 100)
    let ledger = HazardEventLedger(capacity: 1)
    ledger.start(context: context())
    try ledger.append(urgent,context: context(),at: 100)
    do { try ledger.append(warning,context: context(),at: 100); Issue.record("Overflow silently accepted") }
    catch EventLedgerError.capacityExceeded(let rejected) { #expect(rejected == warning) }
    #expect(ledger.pending(at: 100) == urgent)
    #expect(!ledger.acknowledge(urgent[0].id,context: context(2),at: 100))
    ledger.stop(); ledger.start(context: context(2))
    #expect(throws: EventLedgerError.self) { try ledger.append(urgent,context: context(),at: 100) }
    #expect(ledger.pending(at: 100).isEmpty)
}

@Test @MainActor func stoppingDuringEventDeliveryCannotPublishAnOldGeometrySnapshot() async throws {
    let pipeline = GeometryPipeline(clock: Clock(time: 100))
    pipeline.start(context: context())
    pipeline.ledger.onEventsAvailable = { [weak pipeline] _ in pipeline?.stop() }
    #expect(try await pipeline.process(scene(2)) == nil)
    #expect(pipeline.ledger.pending(at: 100).isEmpty)
}

@Test func aCalibratedRigDoesNotMistakeATableOrAStaleFloorEstimateForGround() throws {
    let floor = try scene(5)
    let table = try replacing(floor,values: floor.values.map { $0/2 })
    var processor = GeometryProcessor(configuration: GeometryConfiguration(calibratedCameraHeight: 1))
    let result = try processor.process(table,context: context(),at: 100)
    #expect(result.ground.status == .unknown && !result.observations.isEmpty)
    _ = try processor.process(floor,context: context(),at: 100)
    let confirmed = try processor.process(scene(5,sequence: 2,at: 100.1),context: context(),at: 100.1)
    #expect(confirmed.ground.status == .confirmed)
    let afterGap = try processor.process(scene(5,sequence: 3,at: 101),context: context(),at: 101)
    #expect(afterGap.ground.status == .candidate)
}

@Test func componentBudgetKeepsCloseSupportedGeometryAndDeclaresTruncation() throws {
    let blank = try scene(3)
    var values = blank.values
    for y in stride(from: 0,to: 48,by: 6) {
        for x in stride(from: 0,to: 64,by: 8) {
            for v in y..<y+2 { for u in x..<x+4 { values[v*64+u] = 2 } }
        }
    }
    for v in 42..<44 { for u in 56..<60 { values[v*64+u] = 0.6 } }
    var processor = GeometryProcessor()
    let result = try processor.process(replacing(blank,values: values,confidence: [UInt8](repeating: 2,count: values.count)),context: context(),at: 100)
    #expect(result.observations.count == GeometryConfiguration.current.maximumComponents)
    #expect(result.quality.reasons.contains("componentBudgetExceeded"))
    #expect(result.observations[0].rangeMeters < 1)
    #expect(HazardPolicy().evaluate(result,context: context(),at: 100).first?.urgency == .urgent)
}

@Test func croppedGeometryCannotPopulateVisibleRegionDistancesOrOutOfBoundsOverlays() throws {
    let input = try replacing(scene(0),transform: DisplayTransform(a: 2,b: 0,c: 0,d: 1,tx: 0.5,ty: 0))
    var processor = GeometryProcessor()
    let result = try processor.process(input,context: context(),at: 100)
    #expect(result.observations.count == 1)
    #expect(result.observations[0].details?.displayBounds == nil)
    #expect(result.regions.allSatisfy { $0.nearestRangeMeters == nil })
}

@Test @MainActor func immutableEventIDsCannotBeRewrittenAndPipelineDropsDuplicateFrames() async throws {
    let pipeline = GeometryPipeline(clock: Clock(time: 100))
    pipeline.start(context: context())
    let input = try scene(0)
    let output = try #require(try await pipeline.process(input))
    #expect(try await pipeline.process(input) == nil)
    let event = try #require(output.events.first)
    let changed = HazardEvent(id: event.id,envelope: event.envelope,geometryIDs: event.geometryIDs,urgency: .urgent,
        messageKey: "changed",corridor: event.corridor,rangeMeters: event.rangeMeters,deliveryScope: .research)
    #expect(throws: EventLedgerError.invalidEvent) { try pipeline.ledger.append([changed],context: context(),at: 100) }
    #expect(pipeline.ledger.pending(at: 100) == output.events)
    pipeline.stop()
}

@Test func hazardPolicyRejectsGeometryFromAnotherFreshFrame() throws {
    var processor = GeometryProcessor()
    let old = try processor.process(scene(0),context: context(),at: 100)
    let nextFrame = try scene(0,sequence: 2).frame
    let mixed = GeometryResult(frame: nextFrame,observations: old.observations,regions: old.regions,ground: old.ground,
        quality: old.quality,discardedSmallComponents: 0)
    #expect(HazardPolicy().evaluate(mixed,context: context(),at: 100).isEmpty)
}

@Test func aWideComponentContributesMeasurementsToEveryVisibleRegionItOccupies() throws {
    let blank = try scene(3)
    var values = blank.values
    for v in 16..<28 { for u in 0..<64 { values[v*64+u] = 2 } }
    var processor = GeometryProcessor()
    let result = try processor.process(replacing(blank,values: values,confidence: [UInt8](repeating: 2,count: values.count)),context: context(),at: 100)
    #expect(result.observations.count == 1)
    #expect(result.regions.allSatisfy { $0.nearestRangeMeters != nil })
    #expect(result.regions.allSatisfy { $0.usablePixels > 0 })
}

@Test func aSupportedNearDepthClusterCannotBeDilutedByAChainOfFartherSamples() throws {
    let blank = try scene(3)
    var values = blank.values
    for y in stride(from: 22,to: 26,by: 2) {
        for x in stride(from: 30,to: 34,by: 2) {
            values[y*64+x] = 0.9; values[y*64+x+1] = 1.09
            values[(y+1)*64+x] = 1.28; values[(y+1)*64+x+1] = 1.47
        }
    }
    var processor = GeometryProcessor()
    let result = try processor.process(replacing(blank,values: values,confidence: [UInt8](repeating: 2,count: values.count)),context: context(),at: 100)
    #expect(result.observations.count == 1)
    #expect(result.observations[0].rangeMeters < 1)
    #expect(HazardPolicy().evaluate(result,context: context(),at: 100).first?.urgency == .urgent)
}
