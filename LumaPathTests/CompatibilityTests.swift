import Foundation
import Testing
@testable import LumaPathDomain

@Test func compatibilityProfilesDoNotConfusePermissionSupportAndEvidence() {
    for rear in [false, true] { for ar in [false, true] { for depth in [false, true] {
        for permission in [false, true] { for operation in [false, true] { for forced in [false, true] {
            let snapshot = CapabilitySnapshot(revision: 1, probedAt: 100, rearCamera: rear, worldTracking: ar,
                sceneDepth: depth, smoothedSceneDepth: false, authorized: permission, operational: operation,
                forceCameraOnly: forced)
            let expected: CapabilityProfile = !rear || !permission || !operation ? .noCamera
                : forced || !ar ? .camera : depth ? .depth : .tracking
            #expect(snapshot.profile == expected)
            #expect(FeatureAvailabilityEvaluator.evaluate(.metricGeometry, snapshot: snapshot).state == .unavailable)
            #expect(FeatureAvailabilityEvaluator.evaluate(.savedNotes, snapshot: snapshot).state == .enabled)
            #expect(FeatureAvailabilityEvaluator.evaluate(.manualRoutes, snapshot: snapshot).state == .enabled)
            #expect(FeatureAvailabilityEvaluator.evaluate(.manualReports, snapshot: snapshot).state == .enabled)
        } } }
    } } }
}

@Test func cameraMetadataHasNoFabricatedCalibrationAndLegacyRecordsStayStrict() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .cameraOnly)
    let frame = FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context, sequence: 1),
        mode: .cameraOnly, capturedAt: 100, createdAt: 100, lifetime: 0.3),
        imageSize: .init(width: 1280, height: 720), depthSize: nil, confidenceSize: nil,
        intrinsics: nil, cameraToWorld: nil, orientation: .portrait,
        viewportSize: .init(width: 375, height: 667), imageToDisplay: .identity,
        depthKind: .none, tracking: .unavailable, backend: .avfoundation, capabilityRevision: 1)
    try frame.validate()
    #expect(FrameGeometry.unproject(u: 0, v: 0, axialDepth: 2, frame: frame) == nil)
    let encoded = try JSONEncoder().encode(frame)
    #expect(try JSONDecoder().decode(FrameDescriptor.self, from: encoded) == frame)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "metadataVersion")
    let legacy = try JSONDecoder().decode(FrameDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: ContractError.self) { try legacy.validate() }
    object["metadataVersion"] = 99
    let future = try JSONDecoder().decode(FrameDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: ContractError.unsupportedSchema(99)) { try future.validate() }
}

@Test func rearCameraWorksWithoutARAndAspectFillPreservesImageCenter() {
    let hardware = CapabilitySet(worldTracking: false, sceneDepth: false, smoothedSceneDepth: false,
        cameraPermission: .authorized, rearCamera: true)
    #expect(hardware.preferredMode == .cameraOnly)
    #expect(CapabilitySet(worldTracking: true, sceneDepth: true, smoothedSceneDepth: true,
        cameraPermission: .authorized, rearCamera: false).preferredMode == nil)
    for orientation in [ImageOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
        let transform = DisplayTransform.aspectFill(image: .init(width: 1280, height: 720),
            viewport: .init(width: 375, height: 667), orientation: orientation)
        #expect(transform.isValid)
        let center = transform.apply(x: 0.5, y: 0.5)
        #expect(abs(center.x-0.5) < 1e-9 && abs(center.y-0.5) < 1e-9)
    }
}

@Test func arRecoveryIsBoundedAndDoesNotRetryPermissionOrStandardCameraFailure() {
    var policy = CaptureRecoveryPolicy()
    let result1 = !policy.requestFallback(backend: .arkit, status: .init(.blocked, reason: "cameraDenied"))
    #expect(result1)
    let result2 = !policy.requestFallback(backend: .arkit, status: .init(.unavailable, reason: "frameExpired"))
    #expect(result2)
    let result3 = policy.requestFallback(backend: .arkit, status: .init(.unavailable, reason: "missingFrames"))
    #expect(result3)
    let result4 = !policy.requestFallback(backend: .arkit, status: .init(.blocked, reason: "arkitFailure:test:1"))
    #expect(result4)
    policy = CaptureRecoveryPolicy()
    let result5 = !policy.requestFallback(backend: .avfoundation, status: .init(.unavailable, reason: "missingFrames"))
    #expect(result5)
    let result6 = policy.requestFallback(backend: .arkit, status: .init(.blocked, reason: "arkitFailure:test:1"))
    #expect(result6)
}

@Test func frameEligibilityRejectsMissingPoseStaleFramesAndClosedGates() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 7, mode: .cameraOnly)
    let frame = FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context, sequence: 1),
        mode: .cameraOnly, capturedAt: 100, createdAt: 100, lifetime: 0.3),
        imageSize: .init(width: 1280, height: 720), depthSize: nil, confidenceSize: nil,
        intrinsics: nil, cameraToWorld: nil, orientation: .portrait,
        viewportSize: .init(width: 375, height: 667), imageToDisplay: .identity,
        depthKind: .none, tracking: .unavailable, backend: .avfoundation, capabilityRevision: 7)
    for feature: FeatureID in [.metricGeometry, .spatialMemory] {
        #expect(FeatureAvailabilityEvaluator.evaluate(feature, frame: frame, context: context, at: 100,
            geometryEvidenceEnabled: true, memoryEvidenceEnabled: true).state == .unavailable)
    }
    #expect(FeatureAvailabilityEvaluator.evaluate(.imageCandidates, frame: frame, context: context,
        at: 100, imageModelReady: true).state == .limited)
    #expect(FeatureAvailabilityEvaluator.evaluate(.imageCandidates, frame: frame, context: context,
        at: 100).reason == "modelUnavailable")
    #expect(FeatureAvailabilityEvaluator.evaluate(.cameraView, frame: frame, context: context, at: 100.3).state == .unavailable)
    let replacement = CaptureContext(sessionID: context.sessionID, generation: 8, mode: .cameraOnly)
    #expect(FeatureAvailabilityEvaluator.evaluate(.cameraView, frame: frame, context: replacement, at: 100).state == .unavailable)
}

@Test func resourcePolicyDegradesImmediatelyAndRecoversOnlyAfterContinuousHeadroom() {
    var policy = ResourcePolicy()
    let lean = policy.update(thermal: .serious, capture: .nominal, lowPower: false, at: 100)
    #expect(lean.preset == .lean && !lean.allowsExpensiveEffects)
    let cooling = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: 101)
    #expect(cooling.preset == .lean)
    let warning = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, memoryWarning: true, at: 120)
    #expect(warning.preset == .lean)
    _ = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: 121)
    let early = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: 150.9)
    #expect(early.preset == .lean)
    let recovered = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: 151)
    #expect(recovered.preset == .balanced)
    let stopped = policy.update(thermal: .nominal, capture: .critical, lowPower: false, at: 152)
    #expect(stopped.suspended)
    let stillStopped = policy.update(thermal: .serious, capture: .nominal, lowPower: false, at: 152)
    #expect(stillStopped.suspended)
    let badClock = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: .nan)
    #expect(badClock == stillStopped)
    _ = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: 153)
    let stable = policy.update(thermal: .nominal, capture: .nominal, lowPower: false, at: 183)
    #expect(!stable.suspended && stable.preset == .balanced)
    let lowPower = policy.update(thermal: .nominal, capture: .nominal, lowPower: true, at: 184)
    #expect(lowPower.preset == .lean)
}

@Test func resourceLatencyDiagnosticsStayBoundedAndRejectInvalidSamples() {
    var metrics = LatencyWindow()
    for i in 1...1000 { metrics.record(seconds: Double(i)/1000, accepted: i.isMultiple(of: 2)) }
    metrics.record(seconds: .infinity, accepted: true)
    #expect(metrics.totalSamples == 1000 && metrics.rejectedSamples == 500)
    #expect(metrics.retainedSamples == 256)
    #expect(metrics.percentile(0.5) == 872)
    #expect(metrics.percentile(0.99) == 998)
    #expect(metrics.percentile(.nan) == nil)
    #expect(CaptureConfiguration.current.maximumFrameAge == 0.3)
}

@Test func lowPowerChoiceDoesNotPreventExplicitCaptureAfterCriticalRecovery() {
    var policy = ResourcePolicy()
    _ = policy.update(thermal: .critical, capture: .nominal, lowPower: true, at: 100)
    let cooling = policy.update(thermal: .nominal, capture: .nominal, lowPower: true, at: 101)
    #expect(cooling.suspended)
    let ready = policy.update(thermal: .nominal, capture: .nominal, lowPower: true, at: 131)
    #expect(!ready.suspended && ready.preset == .lean && !ready.allowsExpensiveEffects)
}

@Test func localDepthEligibilityDoesNotInventOrRequireWorldAlignment() throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth)
    let frame = FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context, sequence: 1),
        mode: .liveDepth, capturedAt: 100, createdAt: 100, lifetime: 0.3),
        imageSize: .init(width: 1280, height: 720), depthSize: .init(width: 64, height: 48), confidenceSize: nil,
        intrinsics: .init(fx: 800, fy: 800, cx: 640, cy: 360), cameraToWorld: nil, orientation: .portrait,
        viewportSize: .init(width: 375, height: 667), imageToDisplay: .identity,
        depthKind: .sceneDepth, tracking: .unavailable, backend: .arkit)
    try frame.validate()
    #expect(FeatureAvailabilityEvaluator.evaluate(.metricGeometry, frame: frame, context: context,
        at: 100, geometryEvidenceEnabled: true).state == .enabled)
    #expect(FeatureAvailabilityEvaluator.evaluate(.metricGeometry, frame: frame, context: context,
        at: 100).state == .unavailable)
    #expect(FeatureAvailabilityEvaluator.evaluate(.spatialMemory, frame: frame, context: context,
        at: 100, memoryEvidenceEnabled: true).state == .unavailable)
}

@Test func captureDiagnosticsBoundAgeSamplesAndFreezeStoppedRates() throws {
    var metrics = CaptureDiagnostics(startedAt: 100)
    #expect(metrics.publicationFPS(at: 100) == nil)
    #expect(metrics.firstPublishedSeconds == nil)
    for index in 1...1000 {
        let now = 100 + Double(index)
        metrics.record(.published, capturedAt: now - 0.1, at: now)
    }
    #expect(metrics.publicationAge.retainedSamples == 256)
    #expect(metrics.publicationFPS(at: 1100) == 1)
    metrics.record(.invalid, capturedAt: 0, at: .nan)
    metrics.record(.invalid, capturedAt: 0, at: 1099)
    #expect(metrics.callbacks == 1000)
    metrics.stop(at: 1101)
    metrics.record(.published, capturedAt: 1102, at: 1102)
    #expect(metrics.callbacks == 1000)
    #expect(metrics.publicationFPS(at: 5000) == metrics.publicationFPS(at: 1101))
    var invalid = CaptureDiagnostics(startedAt: .nan)
    invalid.record(.published, capturedAt: 0, at: 1)
    #expect(invalid.callbacks == 0 && invalid.publicationFPS(at: 2) == nil)
}
