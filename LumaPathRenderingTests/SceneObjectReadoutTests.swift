import Foundation
import Testing
import LumaPathDomain
@testable import LumaPathRendering

@Test func briefDetectorMissKeepsOnlyTheOriginalUnexpiredSource() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    let box = NormalizedBounds(minX: 0.1, minY: 0.1, maxX: 0.5, maxY: 0.6)
    var tracker = SceneObjectReadoutTracker()
    let first = try sceneBatch(context, sequence: 1, time: 1, box: box)
    let seen = tracker.update(batch: first, associations: paired(first, range: 2), context: context, at: 1)
    let second = try sceneBatch(context, sequence: 2, time: 1.1, box: box)
    let missed = SemanticBatch(frame: second.frame, observations: [], inferenceDuration: 0.01, modelID: "test", modelVersion: "1")
    let held = tracker.update(batch: missed, associations: [], context: context, at: 1.1)
    #expect(held.first?.id == seen.first?.id)
    #expect(held.first?.envelope == first.frame.envelope)
    let third = try sceneBatch(context, sequence: 3, time: 1.31, box: box)
    let stillMissing = SemanticBatch(frame: third.frame, observations: [], inferenceDuration: 0.01, modelID: "test", modelVersion: "1")
    #expect(tracker.update(batch: stillMissing, associations: [], context: context, at: 1.31).isEmpty)
}

@Test func pinnedDetectorLabelsAndVoiceQueriesUseTheSameNames() {
    #expect(SceneObjectLabels.mapping.count == 80)
    #expect(SceneObjectLabels.names.count == 80)
    #expect(SceneObjectLabels.mapping["diningtable"] == "dining table")
    #expect(SceneObjectLabels.mapping["pottedplant"] == "potted plant")
    #expect(SceneObjectLabels.name(forUserQuery: "table") == "dining table")
    #expect(SceneObjectLabels.name(forUserQuery: "couch") == "sofa")
    #expect(SceneObjectLabels.name(forUserQuery: "tv") == "television")
    #expect(SceneObjectLabels.name(forUserQuery: "dragon") == nil)
}

private func sceneBatch(_ context: CaptureContext, sequence: UInt64, time: Double, box: NormalizedBounds, label: String = "chair", tracking: TrackingQuality = .normal) throws -> SemanticBatch {
    let source = try ReplayFixtures.frames()[0]
    let envelope = ObservationEnvelope(frameID: FrameID(context: context, sequence: sequence), mode: context.mode, capturedAt: time, createdAt: time, lifetime: 0.3)
    let frame = FrameDescriptor(envelope: envelope, imageSize: source.imageSize, depthSize: source.depthSize, confidenceSize: source.confidenceSize,
        intrinsics: source.intrinsics, cameraToWorld: source.cameraToWorld, orientation: source.orientation, viewportSize: source.viewportSize,
        imageToDisplay: source.imageToDisplay, depthKind: source.depthKind, tracking: tracking)
    let observation = SemanticObservation(envelope: envelope, modelID: "test", modelVersion: "1", target: nil, text: label, labelScore: 0.9, imageBounds: box, visualContextConfirmed: true)
    return SemanticBatch(frame: frame, observations: [observation], inferenceDuration: 0.01, modelID: "test", modelVersion: "1")
}
private func paired(_ batch: SemanticBatch, range: Double?) -> [DepthAssociation] {
    batch.observations.map { DepthAssociation(observationID: $0.id, frameID: batch.frame.envelope.frameID, rangeMeters: range,
        axialDepthMeters: range, bearingRadians: 0, associationSupport: 1, uncertaintyMeters: 0.03, reasons: ["test"]) }
}
@Test func namedRangesUseOnlyTheirOwnFrameAndLoseHistoryOnObjectReplacement() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    let left = NormalizedBounds(minX: 0.1, minY: 0.1, maxX: 0.4, maxY: 0.5)
    let right = NormalizedBounds(minX: 0.6, minY: 0.1, maxX: 0.9, maxY: 0.5)
    var tracker = SceneObjectReadoutTracker()
    let first = try sceneBatch(context, sequence: 1, time: 1, box: left)
    let initial = tracker.update(batch: first, associations: paired(first, range: 2), context: context, at: 1)
    #expect(initial.first?.rangeMeters == 2)
    let second = try sceneBatch(context, sequence: 2, time: 1.1, box: left)
    let stable = tracker.update(batch: second, associations: paired(second, range: 2.06), context: context, at: 1.1)
    #expect(stable.first?.id == initial.first?.id)
    #expect(stable.first?.rangeMeters == 2)
    let third = try sceneBatch(context, sequence: 3, time: 1.2, box: right)
    let replacement = tracker.update(batch: third, associations: paired(second, range: 2), context: context, at: 1.2)
    #expect(replacement.first?.id != initial.first?.id)
    #expect(replacement.first?.rangeMeters == nil)
    #expect(replacement.first?.text.contains("unknown") == true)
    #expect(tracker.update(batch: third, associations: paired(third, range: 2), context: context, at: 1.6).isEmpty)
}
@Test func namedRangesCannotBorrowHistoryAcrossLabelGenerationOrMissingDepth() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    let box = NormalizedBounds(minX: 0.1, minY: 0.1, maxX: 0.5, maxY: 0.6)
    var tracker = SceneObjectReadoutTracker()
    let chair = try sceneBatch(context, sequence: 1, time: 1, box: box)
    let first = tracker.update(batch: chair, associations: paired(chair, range: 2), context: context, at: 1)
    let person = try sceneBatch(context, sequence: 2, time: 1.1, box: box, label: "person")
    let next = tracker.update(batch: person, associations: [], context: context, at: 1.1)
    #expect(next.first?.id != first.first?.id)
    #expect(next.first?.rangeMeters == nil)
    let limited = try sceneBatch(context, sequence: 3, time: 1.2, box: box, tracking: .limited)
    #expect(tracker.update(batch: limited, associations: paired(limited, range: 2), context: context, at: 1.2).first?.rangeMeters == nil)
    let changed = CaptureContext(sessionID: context.sessionID, generation: 2, mode: .liveDepth)
    #expect(tracker.update(batch: person, associations: paired(person, range: 2), context: changed, at: 1.1).isEmpty)
}
