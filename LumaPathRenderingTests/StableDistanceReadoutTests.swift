import Foundation
import Testing
import LumaPathDomain
@testable import LumaPathRendering

@Test func bucketBoundariesDoNotChatterButCloserCrossingsAndExpiryStillWin() {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    var readout = StableDistanceReadout()
    #expect(readout.update(key: "surface", rangeMeters: 2, envelope: sample(context, 1, 1), context: context, at: 1) == 2)
    for (offset, value) in [2.14, 2.16, 2.13, 2.17, 2.12].enumerated() {
        let time = 1 + Double(offset+1)*0.04
        #expect(readout.update(key: "surface", rangeMeters: value, envelope: sample(context, UInt64(offset+2), time), context: context, at: time) == 2)
    }
    #expect((readout.update(key: "surface", rangeMeters: 0.98, envelope: sample(context, 8, 1.24), context: context, at: 1.24) ?? 9) < 1)
    #expect(readout.update(key: "surface", rangeMeters: nil, envelope: sample(context, 9, 1.25), context: context, at: 1.25) == nil)
    #expect(readout.update(key: "surface", rangeMeters: 2, envelope: sample(context, 10, 1.3), context: context, at: 1.7) == nil)
}

private func sample(_ context: CaptureContext, _ sequence: UInt64, _ time: Double) -> ObservationEnvelope {
    ObservationEnvelope(frameID: FrameID(context: context, sequence: sequence), mode: context.mode,
                        capturedAt: time, createdAt: time, lifetime: 0.3)
}

@Test func distanceJitterIsStableButRealApproachIsImmediate() {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    var readout = StableDistanceReadout()
    let first = readout.update(key: "chair-1", rangeMeters: 2, envelope: sample(context, 1, 1), context: context, at: 1)
    #expect(first == 2)
    #expect(readout.update(key: "chair-1", rangeMeters: 2.06, envelope: sample(context, 2, 1.05), context: context, at: 1.05) == first)
    #expect(readout.update(key: "chair-1", rangeMeters: 1.02, envelope: sample(context, 3, 1.1), context: context, at: 1.1) == 1)
    #expect((readout.update(key: "chair-1", rangeMeters: 0.98, envelope: sample(context, 4, 1.15), context: context, at: 1.15) ?? 9) < 1)
}

@Test func distanceCannotSurviveLossExpiryGenerationOrInvalidDepth() {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    var readout = StableDistanceReadout()
    #expect(readout.update(key: "object", rangeMeters: 2, envelope: sample(context, 1, 1), context: context, at: 1) == 2)
    #expect(readout.update(key: "object", rangeMeters: nil, envelope: sample(context, 2, 1.1), context: context, at: 1.1) == nil)
    #expect(readout.update(key: "object", rangeMeters: .nan, envelope: sample(context, 3, 1.2), context: context, at: 1.2) == nil)
    #expect(readout.update(key: "object", rangeMeters: 2, envelope: sample(context, 4, 1), context: context, at: 1.4) == nil)
    let replacement = CaptureContext(sessionID: context.sessionID, generation: 2, mode: .cameraOnly)
    #expect(readout.update(key: "object", rangeMeters: 2, envelope: sample(context, 5, 1.4), context: replacement, at: 1.4) == nil)
    #expect(readout.update(key: "object", rangeMeters: 2, envelope: sample(context, 6, 1.5), context: context, at: 1.5) == 2)
    #expect(readout.update(key: "object", rangeMeters: 3, envelope: sample(context, 5, 1.4), context: context, at: 1.5) == nil)
    readout.reset()
    #expect(readout.update(key: "new-object", rangeMeters: 3, envelope: sample(context, 1, 2), context: context, at: 2) == 3)
}
