import Foundation
import Testing
import LumaPathDomain
@testable import LumaPathSensors

/// The unchecked conformance is limited to this test clock; every mutable access is protected by NSLock.
/// No pixel buffers or capture payloads are wrapped in an unchecked concurrency type.
private final class TestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ time: TimeInterval = 100) { self.time = time }
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ delta: TimeInterval) { lock.withLock { time += delta } }
}

@MainActor private final class Permission: CameraAuthorizing {
    var status: CameraPermission
    var requests = 0
    var suspend = false
    let requested: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<CameraPermission, Never>?
    init(_ status: CameraPermission = .authorized) {
        self.status = status
        (requested, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func request() async -> CameraPermission {
        requests += 1
        if !suspend { status = .authorized; return status }
        return await withCheckedContinuation { pending = $0; signal.yield(()) }
    }
    func resolve(_ status: CameraPermission) { self.status = status; pending?.resume(returning: status); pending = nil }
}

@MainActor private final class Driver: CaptureDriver {
    typealias Payload = Int
    var capabilities = CapabilitySet(worldTracking: true, sceneDepth: true, smoothedSceneDepth: true, cameraPermission: .notDetermined)
    var onFrame: (@MainActor (CaptureSample<Int>) -> Void)?
    var onEvent: (@MainActor (CaptureDriverEvent) -> Void)?
    var starts: [DepthKind] = []
    var stops = 0
    var onStop: (@MainActor () -> Void)?
    var viewport = CaptureViewport(orientation: .landscapeRight, size: PixelSize(width: 640, height: 480))
    var failOnStart = false
    func start(depthKind: DepthKind) {
        starts.append(depthKind)
        if failOnStart { onEvent?(.failed("driverFailure")) }
    }
    func stop() { stops += 1; onStop?() }
    func updateViewport(_ viewport: CaptureViewport) { self.viewport = viewport }
    func sample(at time: Double, kind: DepthKind = .sceneDepth, confidence: Bool = true, value: Int = 1,
                viewport override: CaptureViewport? = nil) throws -> CaptureSample<Int> {
        let frame = try ReplayFixtures.frames()[0]
        return CaptureSample(captureTime: time, imageSize: frame.imageSize,
            depthSize: kind == .none ? nil : frame.depthSize,
            confidenceSize: kind == .none || !confidence ? nil : frame.confidenceSize,
            intrinsics: frame.intrinsics, cameraToWorld: frame.cameraToWorld, viewport: override ?? viewport,
            imageToDisplay: frame.imageToDisplay, depthKind: kind, tracking: .normal, payload: value)
    }
    func emit(at time: Double, kind: DepthKind = .sceneDepth, confidence: Bool = true, value: Int = 1) throws {
        onFrame?(try sample(at: time, kind: kind, confidence: confidence, value: value))
    }
}

@MainActor private func controller(_ driver: Driver, permission: Permission = Permission(), clock: TestClock = TestClock(),
                                   automatic: Bool = false) -> CaptureCoordinator<Driver> {
    let controller = CaptureCoordinator(driver: driver, permission: permission, clock: clock, automaticallyChecksFreshness: automatic)
    controller.updateViewport(driver.viewport)
    return controller
}
private func context(generation: UInt64 = 1, mode: SourceMode = .liveDepth, sessionID: UUID = UUID()) -> CaptureContext {
    CaptureContext(sessionID: sessionID, generation: generation, mode: mode)
}

@Test @MainActor func capabilitiesAndAuthorizationAreCheckedBeforeCapture() async {
    for status in [CameraPermission.denied, .restricted] {
        let driver = Driver(), permission = Permission(status)
        let capture = controller(driver, permission: permission)
        await capture.start(context: context())
        #expect(capture.status.phase == .blocked)
        #expect(driver.starts.isEmpty && permission.requests == 0)
        capture.stop()
    }
    let driver = Driver(), permission = Permission(.notDetermined)
    driver.capabilities = CapabilitySet(worldTracking: false, sceneDepth: false, smoothedSceneDepth: false, cameraPermission: .notDetermined)
    let capture = controller(driver, permission: permission)
    await capture.start(context: context())
    #expect(capture.status.reason == "worldTrackingUnsupported")
    #expect(permission.requests == 0 && driver.starts.isEmpty)
}

@Test @MainActor func authorizationSuccessStartsOnlyOneDriverAndUsesRawDepthWhenAvailable() async {
    let driver = Driver(), permission = Permission(.notDetermined)
    let capture = controller(driver, permission: permission)
    await capture.start(context: context())
    #expect(permission.requests == 1)
    #expect(driver.starts == [.sceneDepth])
    #expect(capture.status.phase == .preparing) // No running claim before an actual frame.
    capture.stop()
    #expect(capture.status.phase == .stopped)
}

@Test @MainActor func stoppingOrCancellingDuringPermissionCannotStartCaptureLater() async {
    for cancelTask in [false, true] {
        let driver = Driver(), permission = Permission(.notDetermined)
        permission.suspend = true
        let capture = controller(driver, permission: permission)
        let start = Task { await capture.start(context: context()) }
        var requested = permission.requested.makeAsyncIterator()
        _ = await requested.next()
        if cancelTask { start.cancel() } else { capture.stop() }
        permission.resolve(.authorized)
        await start.value
        #expect(driver.starts.isEmpty)
        #expect(capture.status.phase == .stopped)
    }
}

@Test @MainActor func modesAreFixedAndMissingDepthDoesNotBecomeFabricatedData() async throws {
    let driver = Driver()
    driver.capabilities = CapabilitySet(worldTracking: true, sceneDepth: false, smoothedSceneDepth: false, cameraPermission: .authorized)
    let clock = TestClock(), capture = controller(driver, clock: clock)
    await capture.start(context: context())
    #expect(capture.status.reason == "depthUnsupported" && driver.starts.isEmpty)
    await capture.start(context: context(mode: .cameraOnly))
    #expect(driver.starts == [.none])
    try driver.emit(at: clock.now(), kind: .none, confidence: false)
    let frame = try #require(capture.latestFrame)
    #expect(frame.envelope.sourceMode == .cameraOnly && frame.depthSize == nil && frame.confidenceSize == nil)
    #expect(capture.status.reason == "depthUnavailable")
    capture.stop()
    driver.capabilities = CapabilitySet(worldTracking: true, sceneDepth: false, smoothedSceneDepth: true, cameraPermission: .authorized)
    await capture.start(context: context())
    #expect(driver.starts.last == .smoothedSceneDepth)
    try driver.emit(at: clock.now(), kind: .smoothedSceneDepth, confidence: false)
    #expect(capture.latestFrame?.depthKind == .smoothedSceneDepth)
    #expect(capture.latestFrame?.confidenceSize == nil)
    capture.stop()
}

@Test @MainActor func framesAreThrottledNewestOnlyAndLeasesDoNotRetainEvictedFrames() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock)
    let current = context()
    await capture.start(context: current)
    try driver.emit(at: clock.now(), value: 10)
    let first = try #require(capture.latestFrame)
    let lease = capture.lease(for: first)
    #expect(lease.isValid)
    clock.advance(0.01)
    try driver.emit(at: clock.now(), value: 11)
    #expect(capture.latestFrame == first)
    clock.advance(0.08)
    try driver.emit(at: clock.now(), value: 12)
    #expect(!lease.isValid)
    var consumer = capture.frames.makeAsyncIterator()
    let newest = try #require(await consumer.next())
    #expect(newest.envelope.frameID.sequence == 2)
    #expect(newest.envelope.frameID.sessionID == current.sessionID)
    let latestLease = capture.lease(for: newest)
    var value: Int?
    #expect(latestLease.withValue { value = $0 })
    #expect(value == 12)
    capture.stop()
    #expect(!latestLease.isValid)
}

@Test @MainActor func staleFuturePreStartDuplicateAndOldRunCallbacksAreRejected() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock)
    let first = context()
    await capture.start(context: first)
    let oldCallback = try #require(driver.onFrame)
    try driver.emit(at: 99.99)
    try driver.emit(at: 101)
    try driver.emit(at: .nan)
    #expect(capture.latestFrame == nil)
    try driver.emit(at: clock.now())
    let descriptor = capture.latestFrame
    try driver.emit(at: clock.now())
    #expect(capture.latestFrame == descriptor)
    capture.stop()
    clock.advance(1)
    await capture.start(context: context(generation: 2, sessionID: first.sessionID))
    oldCallback(try driver.sample(at: clock.now()))
    #expect(capture.latestFrame == nil)
    try driver.emit(at: clock.now())
    #expect(capture.latestFrame?.envelope.frameID.generation == 2)
    capture.stop()
}

@Test @MainActor func expiryWatchdogAndRecoveryInvalidateAccessAndNotifyOncePerOutage() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock)
    var cancellations = 0
    capture.onFreshnessLoss = { _ in cancellations += 1 }
    await capture.start(context: context())
    try driver.emit(at: clock.now())
    let lease = capture.lease(for: try #require(capture.latestFrame))
    clock.advance(0.31)
    #expect(!lease.isValid) // Access checks the deadline even before the timer's next tick.
    capture.checkFreshness()
    #expect(capture.latestFrame == nil && capture.status.reason == "frameExpired")
    #expect(cancellations == 1)
    clock.advance(0.21)
    capture.checkFreshness(); capture.checkFreshness()
    #expect(capture.status.reason == "missingFrames" && cancellations == 1)
    try driver.emit(at: clock.now())
    #expect(capture.status.phase == .running)
    #expect(!lease.isValid)
    clock.advance(0.6)
    capture.checkFreshness()
    #expect(cancellations == 2)
    capture.stop()
}

@Test @MainActor func independentTimerDetectsAStreamThatNeverProducesAFrame() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock, automatic: true)
    await capture.start(context: context())
    clock.advance(0.6)
    capture.checkFreshness()
    #expect(capture.status.phase == .preparing)
    clock.advance(4.4)
    // Let the independently scheduled watchdog start on a busy executor. A fixed
    // 160 ms sleep can finish before its task gets its first 100 ms timer turn.
    // Do not call checkFreshness here: this must still prove automatic delivery.
    let scheduler = ContinuousClock()
    let deadline = scheduler.now.advanced(by: .seconds(2))
    while capture.status.phase != .unavailable && scheduler.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(capture.status.phase == .unavailable && capture.status.reason == "missingFrames")
    capture.stop()
    clock.advance(1)
    try await Task.sleep(for: .milliseconds(120))
    #expect(capture.status.phase == .stopped)
}

@Test @MainActor func interruptionFailureAndViewportChangeNeverReuseOldBuffers() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock)
    let current = context()
    await capture.start(context: current)
    try driver.emit(at: clock.now())
    let old = capture.lease(for: try #require(capture.latestFrame))
    let oldViewport = driver.viewport
    capture.updateViewport(CaptureViewport(orientation: .portrait, size: PixelSize(width: 480, height: 640)))
    #expect(!old.isValid && capture.status.reason == "viewportChanged")
    clock.advance(0.1)
    driver.onFrame?(try driver.sample(at: clock.now(), viewport: oldViewport))
    #expect(capture.latestFrame == nil)
    try driver.emit(at: clock.now())
    let rotated = capture.lease(for: try #require(capture.latestFrame))
    driver.onEvent?(.interrupted("sessionInterrupted"))
    #expect(!rotated.isValid && capture.status.phase == .interrupted)
    #expect(driver.onFrame == nil)
    await capture.start(context: current)
    #expect(capture.status.reason == "freshGenerationRequired")
    driver.failOnStart = true
    await capture.start(context: context(generation: 2, sessionID: current.sessionID))
    #expect(capture.status.phase == .blocked && capture.status.reason == "driverFailure")
}

@Test @MainActor func releasingTheControllerStopsTheExclusivelyOwnedDriver() async throws {
    let driver = Driver(), clock = TestClock()
    var capture: CaptureCoordinator<Driver>? = controller(driver, clock: clock)
    await capture?.start(context: context())
    try driver.emit(at: clock.now())
    let lease = try #require(capture).lease(for: try #require(capture?.latestFrame))
    await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
        driver.onStop = { driver.onStop = nil; stopped.resume() }
        capture = nil
    }
    #expect(!lease.isValid)
    #expect(driver.onFrame == nil)
}

private struct TransformExamples: Decodable {
    struct Example: Decodable {
        let name: String
        let frame: FrameDescriptor
        let imageLandmark: [Double]
        let displayLandmark: [Double]
    }
    let cases: [Example]
}

@Test @MainActor func generatedAspectFillExamplesPreserveCalibrationAndCropWithoutDoubleRotation() async throws {
    let cases = try JSONDecoder().decode(TransformExamples.self,
        from: Data(contentsOf: ReplayFixtures.url("aspect-fill-examples.json"))).cases
    #expect(cases.count == 4)
    for example in cases {
        let input = example.frame
        try input.validate()
        let mapped = input.imageToDisplay.apply(x: example.imageLandmark[0], y: example.imageLandmark[1])
        #expect(abs(mapped.x - example.displayLandmark[0]) < 1e-9)
        #expect(abs(mapped.y - example.displayLandmark[1]) < 1e-9)
        let center = input.imageToDisplay.apply(x: 0.5, y: 0.5)
        #expect(abs(center.x - 0.5) < 1e-9 && abs(center.y - 0.5) < 1e-9)
        let corner = input.imageToDisplay.apply(x: 0, y: 0)
        #expect(corner.x < 0 || corner.y < 0 || corner.x > 1 || corner.y > 1) // Aspect fill crops the sensor image.
        let driver = Driver(), clock = TestClock()
        driver.viewport = CaptureViewport(orientation: input.orientation, size: input.viewportSize)
        let capture = controller(driver, clock: clock)
        await capture.start(context: context())
        driver.onFrame?(CaptureSample(captureTime: clock.now(), imageSize: input.imageSize, depthSize: input.depthSize,
            confidenceSize: input.confidenceSize, intrinsics: input.intrinsics, cameraToWorld: input.cameraToWorld,
            viewport: driver.viewport, imageToDisplay: input.imageToDisplay, depthKind: input.depthKind, tracking: input.tracking, payload: 1))
        let published = try #require(capture.latestFrame)
        #expect(published.imageToDisplay == input.imageToDisplay)
        #expect(published.intrinsics == input.intrinsics && published.confidenceSize == input.confidenceSize)
        capture.stop()
    }
}

@Test @MainActor func consumerCanStopSynchronouslyFromAViewportInvalidationHook() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock)
    await capture.start(context: context())
    try driver.emit(at: clock.now())
    capture.onFreshnessLoss = { [weak capture] _ in capture?.stop() }
    capture.updateViewport(CaptureViewport(orientation: .portrait, size: PixelSize(width: 480, height: 640)))
    #expect(capture.status.phase == .stopped && capture.activeContext == nil && capture.latestFrame == nil)
}

@Test @MainActor func standardCameraWithoutARAcceptsMissingPoseAndRejectsReplacedRun() async throws {
    let driver = Driver(), clock = TestClock()
    driver.capabilities = CapabilitySet(worldTracking: false, sceneDepth: false, smoothedSceneDepth: false,
        cameraPermission: .authorized, rearCamera: true)
    let capture = controller(driver, clock: clock)
    let first = context(mode: .cameraOnly)
    await capture.start(context: first)
    #expect(driver.starts == [.none])
    let callback = try #require(driver.onFrame)
    func sample() -> CaptureSample<Int> {
        CaptureSample(captureTime: clock.now(), imageSize: .init(width: 640, height: 480), depthSize: nil,
            confidenceSize: nil, intrinsics: nil, cameraToWorld: nil, viewport: driver.viewport,
            imageToDisplay: .identity, depthKind: .none, tracking: .unavailable, payload: 1, backend: .avfoundation)
    }
    callback(sample())
    let old = try #require(capture.latestFrame)
    #expect(old.cameraToWorld == nil && old.intrinsics == nil && old.backend == .avfoundation)
    let lease = capture.lease(for: old)
    await capture.start(context: context(generation: 2, mode: .cameraOnly, sessionID: first.sessionID))
    callback(sample())
    #expect(capture.latestFrame == nil && !lease.isValid)
    driver.onFrame?(sample())
    #expect(capture.latestFrame?.envelope.frameID.generation == 2)
    capture.stop()
}

@Test @MainActor func captureDiagnosticsSeparateThrottleInvalidAndMailboxReplacement() async throws {
    let driver = Driver(), clock = TestClock()
    let capture = controller(driver, clock: clock)
    await capture.start(context: context())
    clock.advance(0.01)
    try driver.emit(at: clock.now())
    try driver.emit(at: 99) // Stale callback, not a producer publication.
    clock.advance(0.01)
    try driver.emit(at: clock.now()) // Supported frame intentionally rate-limited.
    clock.advance(0.2)
    try driver.emit(at: clock.now()) // Replaces the unconsumed first descriptor.
    let metrics = try #require(capture.diagnostics)
    #expect(metrics.callbacks == 4)
    #expect(metrics.invalidFrames == 1 && metrics.throttledFrames == 1)
    #expect(metrics.publishedFrames == 2 && metrics.replacedPendingFrames == 1)
    #expect(abs(try #require(metrics.firstPublishedSeconds) - 0.01) < 1e-9)
    #expect(metrics.publicationAge.totalSamples == 2)
    capture.stop()
    let rate = capture.diagnostics?.publicationFPS(at: clock.now())
    clock.advance(100)
    #expect(capture.diagnostics?.publicationFPS(at: clock.now()) == rate)
    await capture.start(context: context(generation: 2))
    #expect(capture.diagnostics?.callbacks == 0)
    #expect(capture.diagnostics?.firstPublishedSeconds == nil)
    capture.stop()
}

@Test @MainActor func captureDiagnosticsExcludePermissionWaitAndRemainEmptyOnDenial() async throws {
    let driver = Driver(), clock = TestClock(), permission = Permission(.notDetermined)
    permission.suspend = true
    let capture = controller(driver, permission: permission, clock: clock)
    let start = Task { await capture.start(context: context()) }
    for await _ in permission.requested { break }
    #expect(capture.diagnostics == nil)
    clock.advance(60)
    permission.resolve(.authorized)
    await start.value
    clock.advance(0.1)
    try driver.emit(at: clock.now())
    #expect(abs(try #require(capture.diagnostics?.firstPublishedSeconds) - 0.1) < 1e-9)
    capture.stop()
    permission.status = .denied
    await capture.start(context: context(generation: 2))
    #expect(capture.diagnostics == nil)
}
