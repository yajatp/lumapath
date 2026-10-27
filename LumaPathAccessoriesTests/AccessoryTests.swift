import Foundation
import Testing
import LumaPathDomain
import LumaPathAccessories

private func session() -> WatchSession { WatchSession(context: CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)) }
private func armed() -> (WatchReceiver, WatchSession, UUID) {
    var receiver = WatchReceiver(); let s = session(); let nonce = receiver.beginProbe(at: 10)
    #expect({ receiver.completeProbe(nonce: nonce, session: s, phoneTime: 100, at: 10.1) }())
    return (receiver, s, nonce)
}
private func cue(_ session: WatchSession, _ nonce: UUID, sequence: UInt64 = 1, id: UUID = UUID(), created: Double = 100.1, expires: Double = 100.3) -> WatchCue {
    WatchCue(nonce: nonce, session: session, sequence: sequence, eventID: id, createdAt: created, expiresAt: expires, kind: .urgent, text: "Close obstacle ahead.")
}
@Test func watchUsesConservativeClockBoundAndOriginalExpiry() {
    var (r,s,n) = armed(); let value = cue(s,n)
    #expect({ r.receive(value, at: 10.11) }())
    #expect({ abs(r.currentDeadline-10.29) < 0.000001 }())
    r.expire(at: 10.291); #expect({ r.current == nil }())
    #expect({ !r.receive(cue(s,n,sequence: 2), at: 10.30) }())
}
@Test func lateHandshakeUnknownAgeFutureAndInvalidPacketsFailClosed() {
    var r = WatchReceiver(); let s = session(), n = r.beginProbe(at: 10)
    #expect({ !r.completeProbe(nonce: n, session: s, phoneTime: 100, at: 10.201) }())
    #expect({ !r.receive(cue(s,n), at: 10.21) }())
    var (ready,s2,n2) = armed()
    #expect({ !ready.receive(cue(s2,n2,created: 101,expires: 101.1), at: 10.11) }())
    #expect({ !ready.receive(cue(s2,n2,expires: 101), at: 10.11) }())
    #expect({ !ready.receive(cue(s2,n2,expires: .nan), at: 10.11) }())
    #expect({ !ready.receive(cue(s2,n2), at: .nan) }())
}
@Test func reconnectGenerationAndDuplicateNeverReplayCues() {
    var (r,s,n) = armed(); let first = cue(s,n)
    #expect({ r.receive(first, at: 10.11) }())
    #expect({ !r.receive(first, at: 10.12) }())
    #expect({ !r.receive(cue(s,n,sequence: 2,id: first.eventID), at: 10.12) }())
    #expect({ !r.receive(cue(session(),n,sequence: 3), at: 10.12) }())
    let next = r.beginProbe(at: 10.13)
    #expect({ r.current == nil }())
    #expect({ r.completeProbe(nonce: next, session: s, phoneTime: 100.13, at: 10.14) }())
    #expect({ !r.receive(cue(s,n,sequence: 4), at: 10.15) }())
    #expect({ r.receive(cue(s,next,sequence: 5), at: 10.16) }())
    r.disconnect(); #expect({ !r.receive(cue(s,next,sequence: 6), at: 10.17) }())
}
@Test func cancelledAndExpiredHandshakeRejectDelayedMessages() {
    var (r,s,n) = armed()
    #expect({ r.receive(cue(s,n,sequence: 4), at: 10.11) }())
    #expect({ r.cancel(nonce: n, session: s, sequence: 6) }())
    #expect({ r.current == nil && !r.receive(cue(s,n,sequence: 5), at: 10.12) }())
    #expect({ !r.cancel(nonce: UUID(), session: s, sequence: 7) }())
    #expect({ r.receive(cue(s,n,sequence: 7), at: 10.13) }())
    #expect({ !r.receive(cue(s,n,sequence: 8,created: 102,expires: 102.3), at: 12.11) }())
}
@Test func watchWireRoundTripAndBudget() throws {
    let (_,s,n) = armed(), value = cue(s,n)
    let packet = try WatchWire.decode(WatchWire.cue(value).encoded())
    guard case .cue(let decoded) = packet else { Issue.record("Wrong message"); return }
    #expect({ value == decoded }())
    #expect(throws: ContractError.self) { try WatchWire.decode(Data(repeating: 0, count: 8193)) }
}
@Test func spatialDirectionRequiresExplicitPhoneReferenceAndSupportedRoute() {
    let left = SpatialPolicy.position(bearing: -.pi/2, reference: .phoneForward, calibrated: true, headphones: true, remainingLifetime: 0.2)
    #expect({ abs((left?.x ?? 0)+1) < 0.00001 }())
    #expect({ SpatialPolicy.position(bearing: 0, reference: .headForward, calibrated: true, headphones: true, remainingLifetime: 1) == nil }())
    #expect({ SpatialPolicy.position(bearing: 0, reference: .motionHeading, calibrated: true, headphones: true, remainingLifetime: 1) == nil }())
    #expect({ SpatialPolicy.position(bearing: 0, reference: .phoneForward, calibrated: true, headphones: false, remainingLifetime: 1) == nil }())
    #expect({ SpatialPolicy.position(bearing: 0, reference: .phoneForward, calibrated: false, headphones: true, remainingLifetime: 1) == nil }())
    #expect({ SpatialPolicy.position(bearing: .nan, reference: .phoneForward, calibrated: true, headphones: true, remainingLifetime: 1) == nil }())
    #expect({ SpatialPolicy.position(bearing: 0, reference: .phoneForward, calibrated: true, headphones: true, remainingLifetime: 0.119) == nil }())
}
@Test func mountCalibrationExpiresAcrossRotationGenerationAndLostTracking() throws {
    let template = try ReplayFixtures.frames()[0]
    let context = CaptureContext(sessionID: template.envelope.frameID.sessionID, generation: template.envelope.frameID.generation, mode: template.envelope.sourceMode)
    let now = template.envelope.createdTimeMonotonic
    var calibration = MountCalibration()
    #expect({ calibration.confirm(frame: template, context: context, at: now) }())
    #expect({ calibration.validate(frame: template, context: context, at: now) }())
    let next = CaptureContext(sessionID: context.sessionID, generation: context.generation+1, mode: context.mode)
    #expect({ !calibration.validate(frame: template, context: next, at: now) }())
    #expect({ calibration.context == nil }())
    #expect({ calibration.confirm(frame: template, context: context, at: now) }())
    #expect({ !calibration.validate(frame: template, context: context, at: template.envelope.expiresAtMonotonic) }())
    let angle = Double.pi/3
    let rotated = FrameDescriptor(envelope: template.envelope, imageSize: template.imageSize, depthSize: template.depthSize,
        confidenceSize: template.confidenceSize, intrinsics: template.intrinsics,
        cameraToWorld: [cos(angle),0,-sin(angle),0, 0,1,0,0, sin(angle),0,cos(angle),0, 0,0,0,1],
        orientation: template.orientation, viewportSize: template.viewportSize, imageToDisplay: template.imageToDisplay,
        depthKind: template.depthKind, tracking: .normal)
    #expect({ calibration.confirm(frame: template, context: context, at: now) }())
    #expect({ !calibration.validate(frame: rotated, context: context, at: now) }())
    let lost = FrameDescriptor(envelope: template.envelope, imageSize: template.imageSize, depthSize: template.depthSize,
        confidenceSize: template.confidenceSize, intrinsics: template.intrinsics, cameraToWorld: template.cameraToWorld,
        orientation: template.orientation, viewportSize: template.viewportSize, imageToDisplay: template.imageToDisplay,
        depthKind: template.depthKind, tracking: .limited)
    #expect({ !calibration.confirm(frame: lost, context: context, at: now) }())
}
