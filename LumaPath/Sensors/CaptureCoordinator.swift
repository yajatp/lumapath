import Foundation
import LumaPathDomain

/// One controller per capture driver. The caller supplies a fresh session/generation on every start.
@MainActor public final class CaptureCoordinator<Driver: CaptureDriver>: SensorProvider {
    public private(set) var frames: AsyncStream<FrameDescriptor>
    private var continuation: AsyncStream<FrameDescriptor>.Continuation
    public var onStatusChange: (@MainActor (CaptureStatus) -> Void)?
    /// Hook for downstream cancellation of current-scene work; never inferred from a dropped snapshot.
    public var onFreshnessLoss: (@MainActor (CaptureContext) -> Void)?
    public private(set) var status = CaptureStatus(.stopped)
    public private(set) var diagnostics: CaptureDiagnostics?
    public private(set) var latestFrame: FrameDescriptor?
    public private(set) var selectedDepthKind: DepthKind = .none
    private let driver: Driver
    private let permission: any CameraAuthorizing
    private let clock: any MonotonicClock
    // One retained raw frame + one driver's newest-only mailbox + one in-flight callback <= three.
    private let store = FrameStore<Driver.Payload>(capacity: 1)
    private let automaticallyChecksFreshness: Bool
    private var watchdogTask: Task<Void, Never>?
    private var watchdog: FreshnessWatchdog?
    private var context: CaptureContext?
    private var previousContext: CaptureContext?
    private var runID: UUID?
    private var sequence: UInt64 = 0
    private var captureNotBefore: TimeInterval = 0
    private var lastSeenTime: TimeInterval?
    private var lastPublishedTime: TimeInterval?
    private var viewport: CaptureViewport?
    private var hasReportedExpiry = false

    public init(driver: Driver, permission: any CameraAuthorizing,
                clock: any MonotonicClock = SystemMonotonicClock(), automaticallyChecksFreshness: Bool = true) {
        self.driver = driver; self.permission = permission; self.clock = clock
        self.automaticallyChecksFreshness = automaticallyChecksFreshness
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit {
        watchdogTask?.cancel(); continuation.finish()
        // Global-actor objects can be released off actor. Hop safely to stop the exclusively owned driver.
        let driver = driver
        Task { @MainActor in
            driver.onFrame = nil; driver.onEvent = nil; driver.stop()
        }
    }

    public var activeContext: CaptureContext? { context }

    public var capabilities: CapabilitySet {
        let hardware = driver.capabilities
        return CapabilitySet(worldTracking: hardware.worldTracking, sceneDepth: hardware.sceneDepth,
            smoothedSceneDepth: hardware.smoothedSceneDepth, cameraPermission: permission.status, rearCamera: hardware.rearCamera)
    }

    public func updateViewport(_ viewport: CaptureViewport) {
        guard viewport.size.isValid else { return }
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        driver.updateViewport(viewport)
        if latestFrame != nil {
            invalidateFrames()
            hasReportedExpiry = true
            publish(CaptureStatus(.preparing, reason: "viewportChanged"))
            if let context { onFreshnessLoss?(context) }
        }
    }

    public func start(context: CaptureContext) async {
        stopResources()
        diagnostics = nil
        continuation.finish()
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        if let previousContext, previousContext.sessionID == context.sessionID, context.generation <= previousContext.generation {
            block("freshGenerationRequired"); return
        }
        previousContext = context
        guard context.mode != .demoReplay else { block("useReplayProvider"); return }
        guard viewport?.size.isValid == true else { block("viewportRequired"); return }
        let hardware = capabilities
        guard hardware.rearCamera else { block("rearCameraUnavailable"); return }
        guard context.mode != .liveDepth || hardware.worldTracking else { block("worldTrackingUnsupported"); return }
        if context.mode == .liveDepth {
            if hardware.sceneDepth { selectedDepthKind = .sceneDepth }
            else if hardware.smoothedSceneDepth { selectedDepthKind = .smoothedSceneDepth }
            else { block("depthUnsupported"); return }
        } else { selectedDepthKind = .none }
        let token = UUID()
        runID = token; self.context = context
        publish(CaptureStatus(.preparing))
        // A status callback may synchronously stop this request before authorization begins.
        guard runID == token else { return }
        let authorization = permission.status == .notDetermined ? await permission.request() : permission.status
        guard runID == token, !Task.isCancelled else {
            if runID == token { stop() }
            return
        }
        guard authorization == .authorized else {
            block(authorization == .restricted ? "cameraRestricted" : "cameraDenied"); return
        }
        sequence = 0; lastSeenTime = nil; lastPublishedTime = nil; hasReportedExpiry = false
        captureNotBefore = clock.now()
        diagnostics = CaptureDiagnostics(startedAt: captureNotBefore)
        watchdog = FreshnessWatchdog(startedAt: captureNotBefore)
        driver.onFrame = { [weak self] sample in self?.receive(sample, runID: token) }
        driver.onEvent = { [weak self] event in self?.receive(event, runID: token) }
        driver.start(depthKind: selectedDepthKind)
        guard runID == token else { return }
        if automaticallyChecksFreshness {
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(CaptureConfiguration.current.watchdogInterval)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.checkFreshness()
                }
            }
        }
    }

    public func stop() { stopResources(); publish(CaptureStatus(.stopped)); continuation.finish() }

    public func lease(for descriptor: FrameDescriptor) -> FrameLease<Driver.Payload> {
        FrameLease(descriptor: descriptor, access: { [weak self] body in
            guard let self, let context = self.context, self.runID != nil,
                  self.latestFrame == descriptor, descriptor.envelope.isCurrent(in: context, at: self.clock.now()),
                  self.viewport?.orientation == descriptor.orientation, self.viewport?.size == descriptor.viewportSize else { return false }
            return self.store.withValue(for: descriptor.envelope.frameID, body)
        })
    }

    /// Also exposed for deterministic injected-clock checks. Production schedules this independently of callbacks.
    public func checkFreshness() {
        guard let context, runID != nil else { return }
        let now = clock.now()
        if let latestFrame, !latestFrame.envelope.isCurrent(in: context, at: now), !hasReportedExpiry {
            invalidateFrames(); hasReportedExpiry = true
            publish(CaptureStatus(.unavailable, reason: "frameExpired"))
            onFreshnessLoss?(context)
        }
        let timeout = lastSeenTime == nil ? CaptureConfiguration.current.startupTimeout : CaptureConfiguration.current.missingFrameInterval
        if watchdog?.check(at: now, timeout: timeout) == true {
            invalidateFrames()
            publish(CaptureStatus(.unavailable, reason: "missingFrames"))
            if !hasReportedExpiry { onFreshnessLoss?(context) }
            hasReportedExpiry = true
        }
    }

    private func receive(_ sample: CaptureSample<Driver.Payload>, runID token: UUID) {
        guard runID == token, let context else { return }
        let now = clock.now()
        guard sample.viewport == viewport, sample.captureTime.isFinite, sample.captureTime >= captureNotBefore, now >= sample.captureTime,
              now - sample.captureTime < CaptureConfiguration.current.maximumFrameAge,
              lastSeenTime.map({ sample.captureTime > $0 }) ?? true else {
            diagnostics?.record(.invalid, capturedAt: sample.captureTime, at: now); return
        }
        let descriptor = sample.descriptor(context: context, sequence: sequence + 1, createdAt: now)
        guard (try? descriptor.validate()) != nil,
              sample.depthKind == .none || sample.depthKind == selectedDepthKind else {
            diagnostics?.record(.invalid, capturedAt: sample.captureTime, at: now); return
        }
        lastSeenTime = sample.captureTime
        watchdog?.received(at: sample.captureTime)
        guard lastPublishedTime.map({ sample.captureTime - $0 >= CaptureConfiguration.current.processingInterval }) ?? true else {
            diagnostics?.record(.throttled, capturedAt: sample.captureTime, at: now); return
        }
        sequence += 1; lastPublishedTime = sample.captureTime; hasReportedExpiry = false
        store.insert(sample.payload, for: descriptor.envelope.frameID)
        latestFrame = descriptor
        let result = continuation.yield(descriptor)
        let outcome: CaptureDiagnostics.Outcome
        switch result {
        case .dropped: outcome = .replacedPending
        case .enqueued: outcome = .published
        case .terminated: return
        @unknown default: return
        }
        diagnostics?.record(outcome, capturedAt: sample.captureTime, at: now)
        // Capture running does not assert geometry/region quality; A3/A4 own that assessment.
        publish(CaptureStatus(.running, reason: sample.depthKind == .none ? "depthUnavailable" : nil))
    }

    private func receive(_ event: CaptureDriverEvent, runID token: UUID) {
        guard runID == token else { return }
        switch event {
        case .interrupted(let reason):
            stopResources(); publish(CaptureStatus(.interrupted, reason: reason)); continuation.finish()
        case .failed(let reason): block(reason)
        }
    }
    private func invalidateFrames() { latestFrame = nil; store.removeAll() }
    private func stopResources() {
        diagnostics?.stop(at: clock.now())
        runID = nil; context = nil
        watchdogTask?.cancel(); watchdogTask = nil; watchdog = nil
        driver.onFrame = nil; driver.onEvent = nil; driver.stop()
        invalidateFrames()
    }
    private func block(_ reason: String) {
        stopResources(); publish(CaptureStatus(.blocked, reason: reason)); continuation.finish()
    }
    private func publish(_ status: CaptureStatus) {
        guard self.status != status else { return }
        self.status = status; onStatusChange?(status)
    }
}
