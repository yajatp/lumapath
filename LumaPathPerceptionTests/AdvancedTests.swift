import Foundation
import Testing
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk

private let advancedSession = UUID()
private func advancedContext(_ generation: UInt64 = 1) -> CaptureContext { CaptureContext(sessionID: advancedSession,generation: generation,mode: .demoReplay) }
private func advancedFrame(sequence: UInt64 = 1,time: Double = 100,tx: Double = 0,yaw: Double = 0,
                           tracking: TrackingQuality = .normal,generation: UInt64 = 1) throws -> FrameDescriptor {
    let template = try GeometryFixture.load()[0].image(context: advancedContext(),sequence: 1,at: 100).frame
    let context = advancedContext(generation)
    let pose = [cos(yaw),0,-sin(yaw),0,0,1,0,0,sin(yaw),0,cos(yaw),0,tx,1,0,1]
    return FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context,sequence: sequence),mode: context.mode,
        capturedAt: time,createdAt: time,lifetime: 0.3),imageSize: template.imageSize,depthSize: template.depthSize,
        confidenceSize: template.confidenceSize,intrinsics: template.intrinsics,cameraToWorld: pose,orientation: template.orientation,
        viewportSize: template.viewportSize,imageToDisplay: .identity,depthKind: .sceneDepth,tracking: tracking)
}
private func model(_ frame: FrameDescriptor, family: AdvancedHazardFamily, free: Bool = true, historical: Bool = false) -> OccupancySnapshot {
    var cells: [VoxelKey: VoxelObservation] = [:]
    func put(_ x: Double,_ y: Double,_ z: Double,_ evidence: VolumeEvidence = .occupied) {
        let key = VoxelKey(x: Int(floor(x/0.1)),y: Int(floor(y/0.1)),z: Int(floor(-z/0.1)))
        cells[key] = VoxelObservation(key: key,evidence: evidence,lastObservedAt: frame.envelope.captureTimeMonotonic-(historical ? 0.1 : 0),support: 5)
    }
    switch family {
    case .overhead:
        for x in [-0.15,0.05,0.15] { put(x,1.65,1.15) }
    case .stepUp,.stepDown,.stairs:
        let levels = family == .stairs ? [0.05,0.15,0.25,0.35] : (family == .stepUp ? [0.05,0.15] : [0.05,-0.15])
        for (index,height) in levels.enumerated() {
            for x in [-0.25,-0.05,0.05,0.25] { put(x,height,1.1+Double(index)*0.2) }
        }
    case .narrowPassage:
        for x in [-0.55,0.55] { for y in [0.55,1.05,1.55] { put(x,y,1.15) } }
        if free {
            for x in -5...5 { for y in [5,10,15] { for z in -13 ... -10 {
                let key = VoxelKey(x: x,y: y,z: z)
                if cells[key] == nil { cells[key] = VoxelObservation(key: key,evidence: .observedFree,lastObservedAt: frame.envelope.captureTimeMonotonic,support: 5) }
            } } }
        }
    case .movingObstacle: break
    }
    return OccupancySnapshot(frame: frame,voxelSize: 0.1,cells: cells,truncated: false)
}
private let confirmedGround = GroundEstimate(status: .confirmed,worldHeightMeters: 0,supportingSamples: 200,reason: "syntheticMeasuredRig")

@Test func advancedFamiliesRequireMeasuredEvidenceAndTemporalSupport() throws {
    for family: AdvancedHazardFamily in [.overhead,.stepUp,.stepDown,.stairs,.narrowPassage] {
        var detector = AdvancedDetector()
        let first = try advancedFrame()
        #expect(try detector.detect(model(first,family: family),ground: confirmedGround,context: advancedContext(),at: 100).isEmpty)
        let second = try advancedFrame(sequence: 2,time: 100.1)
        let candidates = try detector.detect(model(second,family: family),ground: confirmedGround,context: advancedContext(),at: 100.1)
        #expect(candidates.contains { $0.family == family },"Missing \(family.rawValue)")
        #expect(candidates.allSatisfy { $0.envelope.expiresAtMonotonic == second.envelope.expiresAtMonotonic })
    }
}

@Test func unknownGapsGroundLossHistoricalCellsAndTrackingLossDoNotBecomeDropsOrPassages() throws {
    for family: AdvancedHazardFamily in [.narrowPassage,.stepDown,.overhead] {
        var detector = AdvancedDetector()
        let first = try advancedFrame()
        _ = try detector.detect(model(first,family: family),ground: confirmedGround,context: advancedContext(),at: 100)
        let second = try advancedFrame(sequence: 2,time: 100.1)
        let unknown = GroundEstimate(status: .unknown,worldHeightMeters: nil,supportingSamples: 0,reason: "groundLost")
        #expect(try detector.detect(model(second,family: family),ground: unknown,context: advancedContext(),at: 100.1).isEmpty)
        #expect(try detector.detect(model(second,family: family,historical: true),ground: confirmedGround,context: advancedContext(),at: 100.1).isEmpty)
    }
    var disconnected = AdvancedDetector()
    for index in 0..<2 {
        let frame = try advancedFrame(sequence: UInt64(index+1),time: 100+Double(index)*0.1)
        let source = model(frame,family: .stepUp)
        let cells = source.cells.filter { $0.key.x != 0 }
        let gap = OccupancySnapshot(frame: frame,voxelSize: 0.1,cells: cells,truncated: false)
        #expect(try disconnected.detect(gap,ground: confirmedGround,context: advancedContext(),at: frame.envelope.createdTimeMonotonic).isEmpty)
    }
    var panDetector = AdvancedDetector()
    let stationary = try advancedFrame()
    _ = try panDetector.detect(model(stationary,family: .overhead),ground: confirmedGround,context: advancedContext(),at: 100)
    let panned = try advancedFrame(sequence: 2,time: 100.1,yaw: 0.2)
    #expect(try panDetector.detect(model(panned,family: .overhead),ground: confirmedGround,context: advancedContext(),at: 100.1).isEmpty)
    var detector = AdvancedDetector()
    for index in 0..<3 {
        let frame = try advancedFrame(sequence: UInt64(index+1),time: 100+Double(index)*0.1)
        #expect(try detector.detect(model(frame,family: .narrowPassage,free: false),ground: confirmedGround,context: advancedContext(),at: frame.envelope.createdTimeMonotonic).isEmpty)
    }
}

@Test func rollingVolumeDistinguishesRayEvidenceFromUnknownAndClearsOnLossAndGeneration() throws {
    var occupancy = RollingOccupancy()
    func depth(_ frame: FrameDescriptor, value: Float = 2) throws -> DepthImage {
        try DepthImage(frame: frame,values: [Float](repeating: value,count: 3072),confidence: [UInt8](repeating: 2,count: 3072))
    }
    let frame = try advancedFrame()
    let result = try occupancy.integrate(depth(frame),context: advancedContext(),at: 100)
    #expect(result.cells.values.contains { $0.evidence == .occupied })
    #expect(result.cells.values.contains { $0.evidence == .observedFree })
    #expect(result.evidence(at: VoxelKey(x: 100,y: 100,z: 100)) == .unknown)
    #expect(result.cells.count <= AdvancedConfiguration.current.maximumVoxels)
    let missing = try advancedFrame(sequence: 2,time: 100.1,tracking: .limited)
    #expect(try occupancy.integrate(depth(missing),context: advancedContext(),at: 100.1).cells.isEmpty)
    let new = try advancedFrame(time: 101,generation: 2)
    #expect(try occupancy.integrate(depth(new,value: 0),context: advancedContext(2),at: 101).cells.isEmpty)
    #expect(throws: ContractError.self) { try occupancy.integrate(depth(frame),context: advancedContext(2),at: 101) }
}

private func objectFrame(sequence: UInt64,time: Double,cameraX: Double,worldX: Double,depth z: Float = 2,yaw: Double = 0) throws -> DepthImage {
    let frame = try advancedFrame(sequence: sequence,time: time,tx: cameraX,yaw: yaw)
    var values = [Float](repeating: 0,count: 3072), confidence = [UInt8](repeating: 0,count: 3072)
    // Project a fixed-size plane patch in world space into the moving camera's original image.
    for y in 15..<31 { for x in 0..<64 {
        let opticalX = (Double(x)-32)*Double(z)/50
        let world = cos(yaw)*opticalX-sin(yaw)*Double(z)+cameraX
        if abs(world-worldX) < 0.25 { values[y*64+x] = z; confidence[y*64+x] = 2 }
    } }
    return try DepthImage(frame: frame,values: values,confidence: confidence)
}

@Test func cameraTranslationAndSweepDoNotCreateObjectMotionAndAbruptTurnResetsPrediction() throws {
    var tracker = MotionTracker(), processor = GeometryProcessor()
    for index in 0..<7 {
        let time = 100+Double(index)*0.1, yaw = Double(index)*0.02
        let depth = try objectFrame(sequence: UInt64(index+1),time: time,cameraX: Double(index)*0.02,worldX: 0,yaw: yaw)
        let geometry = try processor.process(depth,context: advancedContext(),at: time)
        let tracks = try tracker.update(depth,geometry: geometry,context: advancedContext(),at: time)
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { $0.encounterTime == nil })
        if index >= 3 { #expect(tracks.allSatisfy { $0.worldVelocity.map { lengthForTest($0) < 0.2 } ?? true }) }
    }
    let turned = try objectFrame(sequence: 8,time: 100.7,cameraX: 0,worldX: -0.8,yaw: 0.5)
    let geometry = try processor.process(turned,context: advancedContext(),at: 100.7)
    let tracks = try tracker.update(turned,geometry: geometry,context: advancedContext(),at: 100.7)
    #expect(tracks.allSatisfy { $0.worldVelocity == nil && $0.encounterTime == nil })
}
private func lengthForTest(_ vector: SIMD3<Double>) -> Double { (vector.x*vector.x+vector.y*vector.y+vector.z*vector.z).squareRoot() }

@Test func approachingObjectGetsBoundedEncounterButNeverSurvivesTrackingLoss() throws {
    var tracker = MotionTracker(), processor = GeometryProcessor()
    var last: [MotionTrack] = []
    for index in 0..<7 {
        let time = 100+Double(index)*0.1
        let depth = try objectFrame(sequence: UInt64(index+1),time: time,cameraX: 0,worldX: 0,depth: Float(2-Double(index)*0.1))
        last = try tracker.update(depth,geometry: processor.process(depth,context: advancedContext(),at: time),context: advancedContext(),at: time)
    }
    #expect(last.contains { ($0.encounterTime ?? 10) < 3 && ($0.velocityUncertainty ?? 10) <= 0.6 })
    if let measured = last.first, let encounter = measured.encounterTime, let error = measured.velocityUncertainty, let residual = measured.positionResidual {
        let metrics: [String: Any] = ["source": "analyticApproachingPlaneReplay","encounterSeconds": encounter,
            "velocityUncertaintyMetersPerSecond": error,"positionInterpolationResidualMeters": residual,
            "worldSpeedMetersPerSecond": measured.worldVelocity.map(lengthForTest) ?? 0]
        print("A5_FIXTURE_METRICS "+String(decoding: try JSONSerialization.data(withJSONObject: metrics,options: [.sortedKeys]),as: UTF8.self))
    }
    let frame = try advancedFrame(sequence: 8,time: 100.7,tracking: .unavailable)
    let depth = try DepthImage(frame: frame,values: [Float](repeating: 1,count: 3072),confidence: [UInt8](repeating: 2,count: 3072))
    #expect(try tracker.update(depth,geometry: processor.process(depth,context: advancedContext(),at: 100.7),context: advancedContext(),at: 100.7).isEmpty)
}

@Test @MainActor func advancedPriorityUsesOriginalDeadlinesAndCannotWeakenCloseEvents() throws {
    let frame = try advancedFrame(), model = model(frame,family: .overhead)
    let close = AdvancedHazardCandidate(envelope: frame.envelope,family: .overhead,rangeMeters: 0.8,bearingRadians: 0,
        uncertaintyMeters: 0.2,reasons: ["synthetic"])
    let result = AdvancedGeometryResult(occupancy: model,candidates: [close],tracks: [],activations: FeatureActivation.researchOnly,reasons: [])
    for profile in [MobilityGeometryProfile.standard,try MobilityGeometryProfile(requiredWidth: 1.2,earlierNotice: true)] {
        let events = AdvancedHazardPolicy.evaluate(result,context: advancedContext(),profile: profile,at: 100)
        #expect(events.first?.urgency == .urgent && events.first?.advancedCandidateID == close.id)
        let ledger = HazardEventLedger(); ledger.start(context: advancedContext())
        try ledger.append(events,context: advancedContext(),at: 100)
        #expect(ledger.pending(at: 100).count == 1 && ledger.pending(at: 100.3).isEmpty)
    }
    #expect(FeatureActivation.researchOnly.allSatisfy { !$0.ordinaryLiveAvailable })
}

@Test func familyGatesAreIndependentAndExtremeWorldOriginsFailClosed() throws {
    let frame = try advancedFrame(), snapshot = model(frame,family: .overhead)
    let candidate = AdvancedHazardCandidate(envelope: frame.envelope,family: .overhead,rangeMeters: 1,bearingRadians: 0,
        uncertaintyMeters: 0.1,reasons: [])
    let disabled = FeatureActivation(family: .overhead,researchAvailable: false,reasons: ["disabledByFixture"])
    let result = AdvancedGeometryResult(occupancy: snapshot,candidates: [candidate],tracks: [],activations: [disabled],reasons: [])
    #expect(AdvancedHazardPolicy.evaluate(result,context: advancedContext(),at: 100).isEmpty)
    var occupancy = RollingOccupancy()
    let invalid = try advancedFrame(tx: 1e100)
    let depth = try DepthImage(frame: invalid,values: [Float](repeating: 2,count: 3072),confidence: [UInt8](repeating: 2,count: 3072))
    #expect(try occupancy.integrate(depth,context: advancedContext(),at: 100).cells.isEmpty)
}

@Test func rawDepthFloorAndOverheadReplayFeedsTheIntegratedAdvancedPipeline() async throws {
    let engine = PerceptionEngine(configuration: GeometryConfiguration(calibratedCameraHeight: 1))
    var last: GeometryResult?
    for index in 0..<4 {
        let time = 100+Double(index)*0.1, base = try advancedFrame(sequence: UInt64(index+1),time: time)
        let size = PixelSize(width: 256,height: 192)
        let frame = FrameDescriptor(envelope: base.envelope,imageSize: base.imageSize,depthSize: size,confidenceSize: size,
            intrinsics: base.intrinsics,cameraToWorld: base.cameraToWorld,orientation: base.orientation,
            viewportSize: base.viewportSize,imageToDisplay: .identity,depthKind: .sceneDepth,tracking: .normal)
        var values = [Float](repeating: 0,count: size.width*size.height)
        var confidence = [UInt8](repeating: 0,count: values.count)
        for v in 0..<size.height { for u in 0..<size.width {
            var z: Double?
            if v > 96 { z = 200/Double(v-96) } // Analytic y=0 floor; rig camera at y=1.
            if index >= 2, v < 96 {
                let upper = 130/Double(96-v) // Analytic y=1.65 horizontal crossbar surface.
                let x = (Double(u)-128)*upper/200
                if upper >= 1.5 && upper <= 3 && abs(x) <= 0.3 { z = upper }
            }
            if let z, z >= 0.3 && z <= 4 { values[v*size.width+u] = Float(z); confidence[v*size.width+u] = 2 }
        } }
        let depth = try DepthImage(frame: frame,values: values,confidence: confidence)
        last = try await engine.process(depth,advancedResearch: true,context: advancedContext(),at: time)
    }
    let result = try #require(last), advanced = try #require(result.advanced)
    #expect(result.ground.status == .confirmed)
    #expect(advanced.candidates.contains { $0.family == .overhead })
    #expect(AdvancedHazardPolicy.evaluate(advanced,context: advancedContext(),at: 100.3).contains { $0.messageKey == "candidate.overhead" })
}
