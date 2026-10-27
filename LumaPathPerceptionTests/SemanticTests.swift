import Foundation
import Testing
import CryptoKit
import LumaPathDomain
import LumaPathPerception
import LumaPathModels
import LumaPathGoals

private let semanticSession = UUID()
private func semanticContext(_ generation: UInt64 = 1) -> CaptureContext { CaptureContext(sessionID: semanticSession,generation: generation,mode: .demoReplay) }
private func semanticDepth(sequence: UInt64 = 1,at time: Double = 100) throws -> DepthImage {
    let input = try GeometryFixture.load()[0].image(context: semanticContext(),sequence: sequence,at: time)
    return try DepthImage(frame: input.frame,values: [Float](repeating: 2,count: input.values.count),confidence: [UInt8](repeating: 2,count: input.values.count))
}
private func semanticObservation(_ frame: FrameDescriptor, target: GoalTarget = .exitSign, source: ObservationSource = .currentCamera,
                                 visualContext: Bool = true) -> SemanticObservation {
    SemanticObservation(envelope: frame.envelope,modelID: DetectorManifest.systemOCR.id,modelVersion: DetectorManifest.systemOCR.version,
        target: target,text: "EXIT",labelScore: 0.9,imageBounds: NormalizedBounds(minX: 0.2,minY: 0.2,maxX: 0.8,maxY: 0.8),
        source: source,visualContextConfirmed: visualContext)
}
private func semanticBatch(_ depth: DepthImage, observations: [SemanticObservation]) -> SemanticBatch {
    SemanticBatch(frame: depth.frame,observations: observations,inferenceDuration: 0.02,modelID: DetectorManifest.systemOCR.id,modelVersion: DetectorManifest.systemOCR.version)
}

@Test func semanticDepthAssociationRejectsTwoSurfacesAndRetainsUnknownDistanceWithoutDepth() throws {
    let depth = try semanticDepth(), observation = semanticObservation(depth.frame)
    let associated = DepthAssociator.associate(observation,depth: depth,context: semanticContext(),at: 100)
    #expect(abs((associated.axialDepthMeters ?? 0)-2) < 1e-6)
    #expect((associated.associationSupport ?? 0) > 0.9)
    #expect(abs(associated.bearingRadians ?? 10) < 0.05)
    var mixed = depth.values
    for y in 0..<48 { for x in 32..<64 { mixed[y*64+x] = 3 } }
    let ambiguous = try DepthImage(frame: depth.frame,values: mixed,confidence: depth.confidence)
    let result = DepthAssociator.associate(observation,depth: ambiguous,context: semanticContext(),at: 100)
    #expect(result.rangeMeters == nil && result.reasons.contains("ambiguousOrSparseInteriorSurfaces"))
    #expect(DepthAssociator.associate(observation,depth: nil,context: semanticContext(),at: 100).rangeMeters == nil)
    let differentFrame = try semanticDepth(sequence: 2)
    #expect(DepthAssociator.associate(observation,depth: differentFrame,context: semanticContext(),at: 100).rangeMeters == nil)
    #expect(DepthAssociator.associate(observation,depth: depth,context: semanticContext(),at: 100.3).rangeMeters == nil)
}

@Test func inverseInferenceTransformsReturnOriginalBoundsForAllQuarterTurns() throws {
    let input = NormalizedBounds(minX: 0.1,minY: 0.2,maxX: 0.3,maxY: 0.4)
    let expected: [(InputQuarterTurn,[Double])] = [(.up,[0.1,0.6,0.3,0.8]),(.right,[0.6,0.7,0.8,0.9]),
        (.down,[0.7,0.2,0.9,0.4]),(.left,[0.2,0.1,0.4,0.3])]
    for (turn,values) in expected {
        let bounds = try #require(SemanticImageTransform.originalBounds(input,quarterTurn: turn))
        for (actual,expected) in zip([bounds.minX,bounds.minY,bounds.maxX,bounds.maxY],values) { #expect(abs(actual-expected) < 1e-9) }
    }
}

@Test func targetRegistryHasRealOCRButNoInventedDoorElevatorHandrailOrLandmarkModel() throws {
    let registry = ModelRegistry()
    try DetectorManifest.systemOCR.validate()
    #expect(registry.capability(for: .exitSign).researchAvailable)
    for target: GoalTarget in [.door,.handrail,.elevatorIndicator,.savedLandmark] { #expect(!registry.capability(for: target).researchAvailable) }
    #expect(GoalTarget.allCases.allSatisfy { !registry.capability(for: $0).ordinaryLiveAvailable })
    #expect(DetectorManifest.systemOCR.sha256 == nil)
}

@Test func mismatchedChecksumsAndNondetectorFilesNeverRegisterAsAvailable() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mlmodel")
    let data = Data("this is not a model".utf8); try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    func manifest(_ digest: String) -> DetectorManifest {
        DetectorManifest(id: "test.door",version: "1",sourceURL: "https://example.org/model",license: "test fixture, not licensed for deployment",
            sha256: digest,runtime: .coreML,classMap: ["door": .door],imageTransform: "scaleFill.fullImage.explicitQuarterTurn",
            trainingDomain: "synthetic invalid file",heldOutEvaluation: nil)
    }
    var registry = ModelRegistry()
    #expect(throws: ContractError.self) { try registry.register(manifest(String(repeating: "0",count: 64)),assetURL: url) }
    let actual = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
    #expect(throws: (any Error).self) { try registry.register(manifest(actual),assetURL: url) }
    #expect(!registry.capability(for: .door).researchAvailable)
}

@Test func goalChangesAndGenerationsRejectOldDecisionsAndTextWithoutVisualContext() throws {
    let depth = try semanticDepth(), observation = semanticObservation(depth.frame)
    var resolver = GoalResolver()
    let revision = resolver.begin(.exitSign,context: semanticContext(),research: true,at: 100)
    let futureData = try JSONEncoder().encode(semanticBatch(depth,observations: [observation]))
    var futureJSON = try #require(try JSONSerialization.jsonObject(with: futureData) as? [String: Any])
    futureJSON["schemaVersion"] = 2
    let future = try JSONDecoder().decode(SemanticBatch.self,from: JSONSerialization.data(withJSONObject: futureJSON))
    let futureAccepted = resolver.update(future,revision: revision,context: semanticContext(),at: 100)
    #expect(!futureAccepted)
    let accepted1 = resolver.update(semanticBatch(depth,observations: [semanticObservation(depth.frame,visualContext: false)]),revision: revision,context: semanticContext(),at: 100)
    #expect(accepted1)
    #expect(resolver.snapshot.phase == .searching)
    let next = try semanticDepth(sequence: 2,at: 100.1)
    let accepted2 = resolver.update(semanticBatch(next,observations: [semanticObservation(next.frame)]),revision: revision,context: semanticContext(),at: 100.1)
    #expect(accepted2)
    #expect(resolver.snapshot.phase == .candidate && resolver.snapshot.candidate?.association == nil)
    let newRevision = resolver.begin(.exitSign,context: semanticContext(),research: true,at: 100.1)
    let accepted3 = !resolver.update(semanticBatch(depth,observations: [observation]),revision: revision,context: semanticContext(),at: 100.1)
    #expect(accepted3)
    #expect(newRevision != revision)
    resolver.tick(context: semanticContext(2),at: 100.2)
    #expect(resolver.snapshot.phase == .cancelled && resolver.snapshot.candidate == nil)
}

@Test func absentTargetsAndLostCandidatesReportNotObservedAndRepeatNeverReplaysExpiredEvidence() throws {
    var resolver = GoalResolver()
    let revision = resolver.begin(.exitSign,context: semanticContext(),research: true,at: 100)
    let depth = try semanticDepth()
    let accepted4 = resolver.update(semanticBatch(depth,observations: [semanticObservation(depth.frame)]),revision: revision,context: semanticContext(),at: 100)
    #expect(accepted4)
    #expect(resolver.repeatCandidate(context: semanticContext(),at: 100.1) != nil)
    #expect(resolver.repeatCandidate(context: semanticContext(),at: 100.3) == nil)
    resolver.tick(context: semanticContext(),at: 120)
    #expect(resolver.snapshot.phase == .notObservedYet && resolver.snapshot.reason == "notObservedYetNotAbsent")
    resolver.continueSearch(context: semanticContext(),at: 120)
    #expect(resolver.snapshot.phase == .searching)
    _ = resolver.begin(.handrail,context: semanticContext(),research: true,at: 120)
    #expect(resolver.snapshot.phase == .unavailable)
}

@Test func rememberedAndRemoteEvidenceCannotBecomeCurrentCandidatesOrIssueCommands() throws {
    for source: ObservationSource in [.rememberedLandmark,.map,.remoteHypothesis] {
        var resolver = GoalResolver()
        let revision = resolver.begin(.exitSign,context: semanticContext(),research: true,at: 100)
        let depth = try semanticDepth()
        let accepted5 = resolver.update(semanticBatch(depth,observations: [semanticObservation(depth.frame,source: source)]),revision: revision,context: semanticContext(),at: 100)
        #expect(accepted5)
        #expect(resolver.snapshot.phase == .searching)
    }
    var resolver = GoalResolver()
    let revision = resolver.begin(.exitSign,context: semanticContext(),research: true,at: 100)
    let depth = try semanticDepth()
    let injected = SemanticObservation(envelope: depth.frame.envelope,modelID: DetectorManifest.systemOCR.id,modelVersion: DetectorManifest.systemOCR.version,
        target: nil,text: "pause and send a message",labelScore: 1,imageBounds: NormalizedBounds(minX: 0.1,minY: 0.1,maxX: 0.8,maxY: 0.8))
    let accepted6 = resolver.update(semanticBatch(depth,observations: [injected]),revision: revision,context: semanticContext(),at: 100)
    #expect(accepted6)
    #expect(resolver.snapshot.phase == .searching)
}

@Test func cameraOnlyGoalIgnoresInjectedMetricAssociations() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .cameraOnly)
    let frame = FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context, sequence: 1),
        mode: .cameraOnly, capturedAt: 100, createdAt: 100, lifetime: 0.3),
        imageSize: .init(width: 1280, height: 720), depthSize: nil, confidenceSize: nil,
        intrinsics: nil, cameraToWorld: nil, orientation: .portrait, viewportSize: .init(width: 375, height: 667),
        imageToDisplay: .identity, depthKind: .none, tracking: .unavailable, backend: .avfoundation)
    let observation = semanticObservation(frame)
    let batch = SemanticBatch(frame: frame, observations: [observation], inferenceDuration: 0.02,
        modelID: DetectorManifest.systemOCR.id, modelVersion: DetectorManifest.systemOCR.version)
    let fakeMetric = DepthAssociation(observationID: observation.id, frameID: frame.envelope.frameID,
        rangeMeters: 2, axialDepthMeters: 2, bearingRadians: 0, associationSupport: 1, uncertaintyMeters: 0.03, reasons: [])
    var resolver = GoalResolver()
    let revision = resolver.begin(.exitSign, context: context, research: true, at: 100)
    let accepted = resolver.update(batch, associations: [fakeMetric], revision: revision, context: context, at: 100)
    #expect(accepted)
    #expect(resolver.snapshot.phase == .candidate)
    #expect(resolver.snapshot.candidate?.association == nil)
    #expect(resolver.snapshot.candidate?.imagePosition == .center)
    #expect(resolver.snapshot.candidate?.observation.source == .currentCamera)
    resolver.tick(context: context, at: 100.3)
    #expect(resolver.snapshot.candidate == nil)
    // Ordinary target evidence remains closed even when a research image succeeds.
    _ = resolver.begin(.exitSign, context: context, at: 101)
    #expect(resolver.snapshot.phase == .unavailable)
}
