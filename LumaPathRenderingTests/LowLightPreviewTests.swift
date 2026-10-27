import Foundation
import Testing
import LumaPathDomain
@testable import LumaPathRendering

private func lightingImage(_ level: UInt8, time: Double, sequence: UInt64, context: CaptureContext) throws -> LumaImage {
    let source = try ReplayFixtures.frames()[0]
    let envelope = ObservationEnvelope(frameID: FrameID(context: context, sequence: sequence), mode: context.mode,
        capturedAt: time, createdAt: time, lifetime: 0.3)
    let frame = FrameDescriptor(envelope: envelope, imageSize: source.imageSize, depthSize: nil, confidenceSize: nil,
        intrinsics: nil, cameraToWorld: nil, orientation: source.orientation, viewportSize: source.viewportSize,
        imageToDisplay: source.imageToDisplay, depthKind: .none, tracking: .unavailable, backend: .avfoundation)
    return try LumaImage(frame: frame, size: PixelSize(width: 8, height: 8), values: Array(repeating: level, count: 64))
}
@Test func previewLiftIsBoundedAndDoesNotChangeRawLumaOrEvidence() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .cameraOnly)
    var policy = LowLightPreviewPolicy()
    let dark = try lightingImage(20, time: 1, sequence: 1, context: context)
    let adjusted = policy.update(image: dark, context: context, at: 1)
    #expect(adjusted.scene == .dim)
    #expect(adjusted.exposure > 0 && adjusted.exposure <= 1.5)
    #expect(adjusted.shadowLift <= 0.45 && adjusted.gamma >= 0.7)
    #expect(dark.values.allSatisfy { $0 == 20 })
    #expect(dark.frame.depthKind == .none)
    #expect(policy.update(image: dark, context: context, at: 1.4).scene == .unknown)
    #expect(policy.update(image: nil, context: context, at: 1.4).exposure == 0)
}
@Test func previewRespondsGraduallyToLightingAndRestartsForANewGeneration() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .cameraOnly)
    var policy = LowLightPreviewPolicy()
    let first = policy.update(image: try lightingImage(20, time: 1, sequence: 1, context: context), context: context, at: 1)
    let bright = policy.update(image: try lightingImage(180, time: 1.05, sequence: 2, context: context), context: context, at: 1.05)
    #expect(bright.scene == .normal)
    #expect(bright.exposure > 0 && bright.exposure < first.exposure)
    let replacement = CaptureContext(sessionID: context.sessionID, generation: 2, mode: .cameraOnly)
    let reset = policy.update(image: try lightingImage(180, time: 2, sequence: 1, context: replacement), context: replacement, at: 2)
    #expect(reset.exposure == 0)
    let black = policy.update(image: try lightingImage(0, time: 2.1, sequence: 2, context: replacement), context: replacement, at: 2.1)
    #expect(black.scene == .veryDark)
    #expect(black.message.contains("missing"))
}
