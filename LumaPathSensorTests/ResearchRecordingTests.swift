import Foundation
import Testing
import LumaPathDomain
@testable import LumaPathSensors

@MainActor @Test func imageOwnedBeforeSuspensionSurvivesLeaseEvictionWithoutExtendingFreshness() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    let image = try recordedFrame(1, 1, context: context)
    let replacement = try recordedFrame(2, 1.1, context: context)
    let store = FrameStore<Data>(capacity: 1)
    store.insert(image.data, for: image.frame.envelope.frameID)
    let lease = FrameLease<Data>(descriptor: image.frame, access: { body in
        store.withValue(for: image.frame.envelope.frameID, body)
    })
    var owned: Data?
    #expect(lease.withValue { owned = $0 })
    // Reproduces a new provider frame arriving while geometry/quality is awaited.
    store.insert(replacement.data, for: replacement.frame.envelope.frameID)
    #expect(!lease.withValue { _ in Issue.record("Evicted raw data must be inaccessible") })
    var recording = try ResearchRecording(context: context, consent: true, environment: "room", targetLabel: "chair")
    let copied = try EncodedSemanticImage(frame: image.frame, data: #require(owned), quarterTurn: .up)
    #expect(try recording.append(image: copied, depth: nil, quality: nil, at: 1.01))
    #expect(recording.samples.count == 1)
    #expect(recording.samples[0].acquiredAtMonotonic == 1.01)
    #expect(!recording.samples[0].frame.envelope.isCurrent(in: context, at: 1.4))
    #expect(throws: (any Error).self) { try recording.append(image: replacement, depth: nil, quality: nil, at: 1.5) }
}

@Test func delayedQualityCanOnlyAttachToItsArchivedSourceFrame() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    let image = try recordedFrame(1, 1, context: context)
    var recording = try ResearchRecording(context: context, consent: true, environment: "room", targetLabel: "chair")
    #expect(try recording.append(image: image, depth: nil, quality: nil, at: 1))
    let detail = QualityDetails(configurationVersion: 1, frameID: image.frame.envelope.frameID, sampleAge: 0.1,
        tracking: .normal, regions: [], worldDependentFunctionsSupported: true, reasons: [])
    let quality = QualityAssessment(state: .active, reasons: [], details: detail)
    try recording.attachQuality(quality, to: image.frame.envelope.frameID)
    #expect(recording.samples[0].quality == quality)
    let wrong = FrameID(context: context, sequence: 99)
    #expect(throws: (any Error).self) { try recording.attachQuality(quality, to: wrong) }
}

private func recordedFrame(_ sequence: UInt64, _ time: Double, context: CaptureContext) throws -> EncodedSemanticImage {
    let source = try ReplayFixtures.frames()[0]
    let envelope = ObservationEnvelope(frameID: FrameID(context: context, sequence: sequence), mode: context.mode,
        capturedAt: time, createdAt: time, lifetime: 0.3)
    let frame = FrameDescriptor(envelope: envelope, imageSize: source.imageSize, depthSize: source.depthSize,
        confidenceSize: source.confidenceSize, intrinsics: source.intrinsics, cameraToWorld: source.cameraToWorld,
        orientation: source.orientation, viewportSize: source.viewportSize, imageToDisplay: source.imageToDisplay,
        depthKind: source.depthKind, tracking: source.tracking)
    return try EncodedSemanticImage(frame: frame, data: Data([0xff, 0xd8, 0xff, 0xd9]), quarterTurn: .up)
}
@Test func recordingRequiresConsentAndIndependentValidLabels() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    #expect(throws: (any Error).self) { try ResearchRecording(context: context, consent: false, environment: "room-a", targetLabel: "chair") }
    #expect(throws: (any Error).self) { try ResearchRecording(context: context, consent: true, environment: "", targetLabel: "chair") }
    #expect(throws: (any Error).self) { try ResearchRecording(context: context, consent: true, environment: "room-a", targetLabel: "chair", measuredRangeMeters: .nan) }
}
@Test func recordingPairsExactFramesPreservesInvalidDepthAndBoundsSampling() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    var recording = try ResearchRecording(context: context, consent: true, environment: "room-a", targetLabel: "chair", measuredRangeMeters: 2)
    let image = try recordedFrame(1, 1, context: context)
    let count = image.frame.depthSize!.width * image.frame.depthSize!.height
    var values = [Float](repeating: 2, count: count); values[0] = .nan
    let depth = try DepthImage(frame: image.frame, values: values, confidence: [UInt8](repeating: 2, count: count))
    #expect(try recording.append(image: image, depth: depth, quality: nil, at: 1))
    let bits = recording.samples[0].depthFloat32LE!.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8*$1.offset)) }
    #expect(Float(bitPattern: bits).isNaN)
    #expect(throws: (any Error).self) { try recording.append(image: recordedFrame(2, 2, context: context), depth: depth, quality: nil, at: 2) }
    #expect(throws: (any Error).self) { try recording.append(image: recordedFrame(2, 2, context: context), depth: nil, quality: nil, at: 2.4) }
    #expect(try !recording.append(image: recordedFrame(2, 1.1, context: context), depth: nil, quality: nil, at: 1.1))
    for index in 2...12 { #expect(try recording.append(image: recordedFrame(UInt64(index), Double(index), context: context), depth: nil, quality: nil, at: Double(index))) }
    #expect(recording.isFull)
    #expect(try !recording.append(image: recordedFrame(13, 13, context: context), depth: nil, quality: nil, at: 13))
    let decoded = try JSONDecoder().decode(ResearchRecording.self, from: recording.exportData())
    #expect(decoded.samples.count == 12)
    #expect(decoded.samples[0].frame == image.frame)
    #expect(decoded.measuredRangeMeters == 2)
}
