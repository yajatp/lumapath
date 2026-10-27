import SwiftUI
import LumaPathDomain
import LumaPathSensors
import LumaPathRendering
import LumaPathRisk
import LumaPathFeedback
import LumaPathPersonalization
import LumaPathAccessories
import LumaPathCommands
import LumaPathModels
import LumaPathPerception

@MainActor final class LiveRenderModel: ObservableObject {
    var onFindStarted: ((CaptureContext) -> Void)?
    var onFindStopped: (() -> Void)?
    var onFindSceneLost: (() -> Void)?
    var wantsFindFrame: (() -> Bool)?
    var onFindFrame: ((EncodedSemanticImage, DepthImage?) -> Void)?
    var findContext: CaptureContext? { provider.activeContext }
    func enqueueFind(_ item: FeedbackItem) { if active && researchEnabled { _ = feedback.enqueue(item) } }
    func invalidateFindOutput() { feedback.invalidateOptional() }
    private let driver = AdaptiveCameraDriver()
    private lazy var provider = CaptureCoordinator(driver: driver, permission: CameraPermissionService())
    private var recovery = CaptureRecoveryPolicy()
    private var fallbackTask: Task<Void, Never>?
    @Published var cameraOnlySelected = UserDefaults.standard.bool(forKey: "capture.cameraOnly") {
        didSet {
            UserDefaults.standard.set(cameraOnlySelected, forKey: "capture.cameraOnly")
            stop(); driver.forceStandardCamera = cameraOnlySelected
        }
    }
    private let renderer = FrameRenderer()
    private let cameraLighting = CameraLighting()
    private var lowLightPolicy = LowLightPreviewPolicy()
    @Published var autoBrightenPreview = true { didSet { lowLightPolicy.reset() } }
    @Published private(set) var lightingSummary = "Lighting has not been measured from a current image."
    @Published private(set) var flashlightEnabled = false
    @Published private(set) var flashlightStatus = "Flashlight is off."
    func toggleFlashlight() {
        guard active, !isRecording else { return }
        do {
            try cameraLighting.setEnabled(!flashlightEnabled, backend: driver.selectedBackend)
            flashlightEnabled = cameraLighting.enabled
            flashlightStatus = flashlightEnabled ? "Flashlight on. This changes the actual scene illumination." : "Flashlight is off."
        } catch { flashlightStatus = "Flashlight unavailable for this camera or current device conditions. Add room lighting instead." }
    }
    private let clock = SystemMonotonicClock()
    private var pipeline = GeometryPipeline()
    private let qualityPipeline = QualitySessionPipeline()
    @Published private(set) var qualitySnapshot: SessionSnapshot?
    var qualitySummary: String {
        guard let quality = qualitySnapshot?.quality else { return "Sensing has not started." }
        let reasons = SensingLimitation.reasons(for: quality)
        if quality.state == .initializing && reasons.isEmpty { return "Sensing is starting." }
        return reasons.isEmpty ? "Current sensing conditions are supported. Unobserved areas remain unknown." : reasons.map(\.message).prefix(3).joined(separator: " ")
    }
    private let output = AccessoryOutputSink()
    private lazy var feedback = FeedbackCoordinator(sink: output)
    private var pipelineContext: CaptureContext?
    private var distanceReadout = StableDistanceReadout()
    private var summaryEnvelope: ObservationEnvelope?
    private lazy var objectDetector = SceneObjectDetector(preset: objectPreset)
    private var objectPreparationID: UUID?
    @Published var objectPreset = SceneDetectorPreset(rawValue: UserDefaults.standard.string(forKey: "research.sceneDetector") ?? "") ?? .full {
        didSet {
            guard oldValue != objectPreset else { return }
            UserDefaults.standard.set(objectPreset.rawValue, forKey: "research.sceneDetector")
            stop(); objectsPrepared = false; preparingObjects = false; objectPreparationID = nil
            objectDetector = SceneObjectDetector(preset: objectPreset)
            objectStatus = "Loading \(objectPreset.title) on this device."
            Task { [weak self] in await self?.prepareObjects() }
        }
    }
    private var objectTracker = SceneObjectReadoutTracker()
    private var objectInference: Task<Void, Never>?
    private var objectInferenceID: UUID?
    private var lastObjectInference: Double = -.infinity
    private var preparingObjects = false
    private var objectsPrepared = false
    @Published var objectsEnabled = true { didSet { clearObjects() } }
    @Published private(set) var objects: [SceneObjectReadout] = []
    @Published private(set) var objectStatus = "Local object detector is loading."
    @Published private(set) var assistantReply = "Ask what is ahead, or ask for the distance to an object."
    private var requestedDescription: LiveVoiceAction?
    private var descriptionDeadline: Double?
    private var assistantEnvelope: ObservationEnvelope?
    func runVoiceCommand(_ action: LiveVoiceAction) {
        switch action {
        case .pause: pause(); assistantReply = "Camera paused."
        case .resume:
            if canStart { start(); assistantReply = "Camera requested. Waiting for fresh images." }
            else { assistantReply = active ? "Camera is already running." : "Camera unavailable. Check camera access and try Start live view." }
        case .end: stop(); assistantReply = "Live view ended."
        case .help: pause(); assistantReply = "Live view paused. No one has been called or messaged."
        case .describe, .distance:
            guard researchEnabled, objectsEnabled, objectsPrepared else {
                assistantReply = "Enable Research and object recognition first. Wait for the local detector to be ready."; return
            }
            if !active {
                guard canStart else { assistantReply = "Camera unavailable. Check access and try Start live view."; return }
                start()
            }
            requestedDescription = action; descriptionDeadline = clock.now() + 5
            assistantReply = "Checking a fresh camera frame. Keep the phone stationary."
        }
    }
    private func answerDescription(frame: FrameDescriptor, context: CaptureContext) {
        guard let request = requestedDescription, frame.envelope.isCurrent(in: context, at: clock.now()) else { return }
        let selection: SceneObjectReadout?
        switch request {
        case .distance(let label):
            selection = objects.first { $0.label == SceneObjectLabels.name(forUserQuery: label) }
            guard selection != nil else { return }
        case .describe: selection = objects.first
        default: return
        }
        let text = selection?.text ?? "No object recognized in this frame. Unobserved areas remain unknown."
        assistantReply = text; assistantEnvelope = frame.envelope
        requestedDescription = nil; descriptionDeadline = nil
        if !UIAccessibility.isVoiceOverRunning {
            _ = feedback.enqueue(FeedbackItem(context: context, createdAt: clock.now(), expiresAt: frame.envelope.expiresAtMonotonic,
                kind: .goal, priority: 1, text: text, repeatKey: "assistant.\(frame.envelope.frameID.sequence)", source: "currentLocalSceneObject"))
        }
    }
    func prepareObjects() async {
        guard !preparingObjects, !objectsPrepared else { return }
        let id = UUID(), detector = objectDetector, preset = objectPreset
        objectPreparationID = id
        preparingObjects = true
        do {
            try await detector.prepare()
            guard objectPreparationID == id else { return }
            objectsPrepared = true; objectStatus = "\(preset.title) ready. Enable Research and start capture to observe objects."
        } catch {
            guard objectPreparationID == id else { return }
            objectStatus = "Object detector unavailable. Depth sensing remains separate. \(error)"
        }
        objectPreparationID = nil
        preparingObjects = false
    }
    private func clearObjects() {
        objectInference?.cancel(); objectTracker.reset(); objects = []
        if objectsPrepared { objectStatus = "No current object result. Enable Research and start fresh capture." }
    }
    private func detectObjects(_ image: EncodedSemanticImage, depth: DepthImage?, context: CaptureContext) {
        guard objectInferenceID == nil else { return }
        let id = UUID(); objectInferenceID = id; lastObjectInference = clock.now()
        objectInference = Task(priority: .utility) { [weak self, objectDetector] in
            defer { if self?.objectInferenceID == id { self?.objectInferenceID = nil; self?.objectInference = nil } }
            do {
                let batch = try await objectDetector.detect(image, context: context)
                guard let self, !Task.isCancelled, self.objectInferenceID == id, self.objectsEnabled,
                      self.researchEnabled, self.provider.activeContext == context,
                      image.frame.envelope.isCurrent(in: context, at: self.clock.now()) else { return }
                let associations = batch.observations.map { DepthAssociator.associate($0, depth: depth, context: context, at: self.clock.now()) }
                self.objects = self.objectTracker.update(batch: batch, associations: associations, context: context, at: self.clock.now())
                self.objectStatus = self.objects.isEmpty ? "No current recognized objects. This does not establish an empty scene." : "Current object candidates. Names and surface distances are Research-only."
                self.answerDescription(frame: batch.frame, context: context)
            } catch is CancellationError { return }
            catch {
                guard let self, !Task.isCancelled, self.provider.activeContext == context else { return }
                self.objects = self.objects.filter { $0.envelope.isCurrent(in: context, at: self.clock.now()) }
                if self.objects.isEmpty { self.objectTracker.reset() }
                self.objectStatus = "Object result unavailable or too slow for the current frame. Depth sensing continues separately."
            }
        }
    }
    @Published private(set) var recording: ResearchRecording?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStatus = "Nothing recorded."
    @Published private(set) var recordingExportURL: URL?
    private var temporaryRecordingURL: URL?
    private var exportTask: Task<Void, Never>?
    private var exportID: UUID?
    private var recordingDeadline: Double?
    @Published private(set) var recordingAttempts = 0
    @Published private(set) var recordingLastIssue: String?
    func startRecording(consent: Bool, environment: String, label: String, measuredRange: String) {
        guard active, let context = provider.activeContext else {
            recordingStatus = "Camera is not running. Start live view, then start recording."; return
        }
        guard recording == nil else {
            recordingStatus = "Export or delete the previous recording before starting another."; return
        }
        do {
            let trimmed = measuredRange.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = trimmed.isEmpty ? nil : Double(trimmed)
            guard trimmed.isEmpty || range != nil else { throw ContractError.invalidValue("measuredRange") }
            recording = try ResearchRecording(context: context, consent: consent, environment: environment,
                targetLabel: label, measuredRangeMeters: range)
            isRecording = true; recordingDeadline = clock.now() + 15
            recordingAttempts = 0; recordingLastIssue = nil
            recordingStatus = "Waiting for the first camera sample: 0 of 12."
        } catch { recordingStatus = "Check consent, room/object labels and measured range (0.3–4 m, or blank)." }
    }
    func finishRecording() {
        isRecording = false; recordingDeadline = nil
        guard let recording else { return }
        recordingStatus = recording.samples.isEmpty
            ? "No samples captured. \(recordingLastIssue ?? "No usable camera frame arrived before recording ended.") Delete this empty attempt and retry."
            : "\(recording.samples.count) samples kept in memory. Review labels, then export or delete."
    }
    func deleteRecording() {
        exportTask?.cancel(); exportTask = nil; exportID = nil; isRecording = false; recordingDeadline = nil; recording = nil
        if let url = recordingExportURL { try? FileManager.default.removeItem(at: url) }
        recordingExportURL = nil; temporaryRecordingURL = nil
        recordingStatus = "Recording deleted from this app. Exported copies remain with their recipient."
    }
    func exportRecording() {
        guard !isRecording, let recording, !recording.samples.isEmpty, exportTask == nil else { return }
        recordingStatus = "Preparing local export…"
        let id = UUID(); exportID = id
        exportTask = Task { [weak self] in
            defer { if self?.exportID == id { self?.exportTask = nil; self?.exportID = nil } }
            do {
                let url = try await Task.detached(priority: .utility) {
                    let data = try recording.exportData()
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaPathResearch", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("\(recording.id.uuidString).lumacapture.json")
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    var protectedURL = url; try protectedURL.setResourceValues(values)
                    return url
                }.value
                guard !Task.isCancelled, self?.exportID == id, self?.recording?.id == recording.id else {
                    try? FileManager.default.removeItem(at: url); return
                }
                self?.recordingExportURL = url; self?.temporaryRecordingURL = url
                self?.recordingStatus = "Export ready. Sharing is your choice; nothing is uploaded automatically."
            } catch { if !Task.isCancelled { self?.recordingStatus = "Export failed. Keep or delete the in-memory samples and retry." } }
        }
    }
    private let sessionID = UUID()
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var viewport: CaptureViewport?
    private(set) var frame: FrameDescriptor?
    @Published private(set) var overlayRequest: RendererRequest?
    @Published private(set) var observationSummary = "No current observations."
    @Published private(set) var advancedEvidence: AdvancedGeometryResult?
    @Published private(set) var feedbackFailure: String?
    @Published var researchEnabled = false { didSet { stop() } }
    @Published var speechEnabled = false { didSet { updateChannels() } }
    @Published var hapticsEnabled = false { didSet { updateChannels() } }
    @Published var spatialEnabled = false { didSet { updateChannels() } }
    @Published var watchEnabled = false { didSet { stop() } }
    @Published var advancedEnabled = false { didSet { stop() } }
    @Published var mountMode = MountMode(rawValue: UserDefaults.standard.string(forKey: "mount.mode") ?? "") ?? .handheld {
        didSet { UserDefaults.standard.set(mountMode.rawValue, forKey: "mount.mode"); stop() }
    }
    @Published var stationaryConfirmed = false
    @Published var coverageConfirmed = false
    @Published var usualAidConfirmed = false
    @Published var headphonesConfirmed = false { didSet { output.spatial.headphonesConfirmed = headphonesConfirmed } }
    @Published var measuredHeight = "" { didSet { stop() } }
    @Published var clearanceHeight = 1.8 { didSet { stop() } }
    @Published private(set) var mountStatus = "Alignment required for phone-relative spatial cues."
    private var calibration = MountCalibration()
    var watchStatus: String { output.watch.status }
    var canConfirmMount: Bool { active && stationaryConfirmed && coverageConfirmed && usualAidConfirmed && frame != nil }
    var geometryProfile: MobilityGeometryProfile? {
        try? MobilityGeometryProfile(requiredWidth: preferences.requiredWidth ?? 0.8,
            clearanceHeight: clearanceHeight, earlierNotice: preferences.anticipation == .earlier)
    }
    func confirmMount() {
        guard canConfirmMount, let frame, let context = provider.activeContext,
              calibration.confirm(frame: frame, context: context, at: clock.now()) else {
            invalidateMount(); mountStatus = "Alignment unavailable: current tracked phone pose is required."; return
        }
        output.spatial.calibrated = true
        mountStatus = "Phone-forward aligned. Recheck after turning, moving the mount, or changing headphones."
        configurePipeline()
    }
    private func invalidateMount() {
        calibration.reset(); output.spatial.routeChanged()
        headphonesConfirmed = false
        stationaryConfirmed = false; coverageConfirmed = false; usualAidConfirmed = false
        mountStatus = "Alignment required. Phone speech/haptics remain available."
    }
    private func configurePipeline() {
        pipeline.stop(); pipelineContext = nil
        let height = Double(measuredHeight)
        let measured = mountMode == .chestMounted && calibration.context != nil && height?.isFinite == true
            && (0.3...2.5).contains(height ?? 0) ? height : nil
        pipeline = GeometryPipeline(configuration: GeometryConfiguration(calibratedCameraHeight: measured),
            advancedResearch: advancedEnabled && geometryProfile != nil, profile: geometryProfile ?? .standard)
        pipeline.ledger.onEventsAvailable = { [weak self] _ in
            guard let self, self.researchEnabled, self.active else { return }
            self.feedback.consume(self.pipeline.ledger)
        }
    }
    var outputCapabilities: OutputCapabilities { feedback.capabilities }
    var outputStatus: String {
        if !researchEnabled { return "Visual view only; alerts muted" }
        if feedback.channels.muted { return "Visual view only; alerts muted" }
        return "Research output · speech \(speechEnabled && outputCapabilities.speech ? "enabled" : "off/unavailable") · haptics \(hapticsEnabled && outputCapabilities.haptics ? "enabled" : "off/unavailable") · spatial \(spatialEnabled && outputCapabilities.spatial ? "phone-relative" : "off/unavailable") · watch \(watchEnabled && outputCapabilities.watch ? "reachable" : "off/unavailable")"
    }
    @Published private(set) var image: CGImage?
    @Published private(set) var status = CaptureStatus(.stopped)
    @Published private(set) var paused = false
    @Published private(set) var mode: SourceMode?
    @Published private(set) var renderMilliseconds = 0.0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var resourceDecision = ResourceDecision(preset: .balanced, suspended: false, reason: "balanced")
    @Published var preferLowPower = false { didSet { refreshResources() } }
    private var resourcePolicy = ResourcePolicy()
    private var capturePressure = ResourcePressure.nominal
    private var lastResourceCheck: TimeInterval = 0
    private var latency = LatencyWindow()
    private var processingLatency = LatencyWindow()
    private var firstImageSeconds: TimeInterval?
    var resourceSummary: String {
        if resourceDecision.suspended { return "Camera paused for resource pressure. Let the phone recover, then start again." }
        return resourceDecision.preset == .lean
            ? "Lean mode: image edges and highlight effects are paused to reduce resource use. Recovery needs 30 seconds of stable headroom."
            : "Balanced mode. Performance limits are provisional until device trials are complete."
    }
    var latencySummary: String {
        String(format: "Render p50 / p95 / p99: %.1f / %.1f / %.1f ms; samples: %d (up to 256 retained).",
            latency.percentile(0.5) ?? 0, latency.percentile(0.95) ?? 0, latency.percentile(0.99) ?? 0, latency.totalSamples)
    }
    var captureSummary: String {
        guard let metrics = provider.diagnostics else { return "No authorized capture run measured." }
        let first = metrics.firstPublishedSeconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "pending"
        let image = firstImageSeconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "pending"
        return String(format: "First publication: %@; first rendered image: %@. Producer publication rate: %.1f fps. Callbacks: %d; invalid: %d; throttled: %d; pending frames replaced: %d.",
            first, image, metrics.publicationFPS(at: clock.now()) ?? 0, metrics.callbacks,
            metrics.invalidFrames, metrics.throttledFrames, metrics.replacedPendingFrames)
    }
    var processingSummary: String {
        String(format: "Capture to processing completion p50 / p95 / p99: %.1f / %.1f / %.1f ms; completed attempts: %d; rejected or expired: %d. Publication age p95: %.1f ms.",
            processingLatency.percentile(0.5) ?? 0, processingLatency.percentile(0.95) ?? 0,
            processingLatency.percentile(0.99) ?? 0, processingLatency.totalSamples,
            processingLatency.rejectedSamples, provider.diagnostics?.publicationAge.percentile(0.95) ?? 0)
    }
    // Presentation changes take effect on the next original frame, without invalidating producer events.
    @Published var settings = EnhancementSettings()
    let profile: VisionProfile?
    var preferences: ProfilePreferences { profile?.preferences ?? ProfilePreferences() }
    @Published private(set) var regionSummary = "No current regional observations."
    var capabilities: CapabilitySet { provider.capabilities }
    var active: Bool { provider.activeContext != nil }
    var canStart: Bool { !active && !resourceDecision.suspended && viewport != nil && capabilities.preferredMode != nil }

    init(profile: VisionProfile? = nil) {
        self.profile = profile
        driver.onPressureChange = { [weak self] pressure in
            self?.capturePressure = pressure
            self?.refreshResources()
        }
        if let profile { settings = profile.preferences.enhancement }
        feedback.setDescriptionInterval(preferences.descriptionInterval)
        speechEnabled = preferences.speech && outputCapabilities.speech
        hapticsEnabled = preferences.haptics && outputCapabilities.haptics
        spatialEnabled = preferences.spatialCues
        updateChannels()
        qualityPipeline.onSnapshot = { [weak self] in self?.qualitySnapshot = $0 }
        qualityPipeline.ledger.onEventsAvailable = { [weak self] _ in
            guard let self, self.researchEnabled, self.active else { return }
            self.feedback.consume(self.qualityPipeline.ledger)
        }
        pipeline.ledger.onEventsAvailable = { [weak self] _ in
            guard let self, self.researchEnabled, self.active else { return }
            self.feedback.consume(self.pipeline.ledger)
        }
        feedback.onChange = { [weak self] in self?.objectWillChange.send() }
        output.onInterruption = { [weak self] in self?.pause() }
        output.watch.onPause = { [weak self] in self?.pause() }
        output.onAlignmentLost = { [weak self] in self?.invalidateMount(); self?.configurePipeline() }
        output.onCapabilityChange = { [weak self] in self?.objectWillChange.send() }
        provider.onStatusChange = { [weak self] status in
            self?.status = status
            if let self, self.recovery.requestFallback(backend: self.driver.selectedBackend, status: status) {
                let generation = self.generation
                self.fallbackTask = Task { [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    self.start(standardFallback: true)
                }
            }
            if status.phase != .running {
                self?.clearImage()
                if let self, self.provider.activeContext == nil {
                    self.qualityPipeline.stop()
                    if self.isRecording { self.finishRecording() }
                    do { try self.cameraLighting.turnOff(); self.flashlightEnabled = false }
                    catch { self.flashlightStatus = "Could not confirm the flashlight turned off. Check the phone's flashlight control." }
                }
            }
        }
        provider.onFreshnessLoss = { [weak self] _ in self?.clearImage() }
    }
    deinit {
        task?.cancel(); expiryTask?.cancel(); fallbackTask?.cancel(); objectInference?.cancel(); exportTask?.cancel()
        if let url = temporaryRecordingURL { try? FileManager.default.removeItem(at: url) }
    }
    func updateViewport(_ value: CaptureViewport) {
        guard viewport != value else { return }
        clearImage()
        viewport = value
        provider.updateViewport(value)
        // Publish even before capture so Start becomes enabled once the actual surface is laid out.
        objectWillChange.send()
    }
    func start(standardFallback: Bool = false) {
        refreshResources()
        guard !resourceDecision.suspended else { return }
        if standardFallback {
            task?.cancel(); task = nil
            provider.stop(); clearImage()
            driver.forceStandardCamera = true
        } else {
            recovery = CaptureRecoveryPolicy()
            driver.forceStandardCamera = cameraOnlySelected
        }
        guard canStart, let mode = capabilities.preferredMode else { return }
        latency = LatencyWindow(); processingLatency = LatencyWindow(); firstImageSeconds = nil
        renderMilliseconds = 0; droppedFrames = 0
        paused = false; self.mode = mode
        generation += 1
        let context = CaptureContext(sessionID: sessionID, generation: generation, mode: mode)
        configurePipeline()
        feedback.start(context: context, allowResearch: researchEnabled)
        if researchEnabled && watchEnabled { output.watch.start(context: context) }
        updateChannels()
        qualityPipeline.start(context: context)
        let provider = provider
        task?.cancel()
        task = Task { [weak self] in
            defer { if provider.activeContext == context { provider.stop() } }
            await provider.start(context: context)
            guard !Task.isCancelled, provider.activeContext == context else { return }
            self?.onFindStarted?(context)
            for await frame in provider.frames {
                guard !Task.isCancelled, provider.activeContext == context else { return }
                await self?.receive(frame, context: context)
            }
        }
    }
    func pause() { let shouldPause = active || paused; stop(); paused = shouldPause }
    func stop() {
        do { try cameraLighting.turnOff(); flashlightEnabled = false; flashlightStatus = "Flashlight is off." }
        catch { flashlightStatus = "Could not confirm the flashlight turned off. Check the phone's flashlight control." }
        requestedDescription = nil; descriptionDeadline = nil; assistantEnvelope = nil
        assistantReply = "No current observation. Request a fresh description after starting capture."
        finishRecording()
        onFindStopped?()
        fallbackTask?.cancel(); fallbackTask = nil
        task?.cancel(); task = nil
        qualityPipeline.stop(); provider.stop(); clearImage(); paused = false
        feedback.cancel(reason: "sessionStopped"); output.shutdown()
    }
    private func receive(_ frame: FrameDescriptor, context: CaptureContext) async {
        guard let viewport, RenderBoundary.accepts(frame, context: context, orientation: viewport.orientation,
                                                   viewport: viewport.size, at: clock.now()) else { return }
        // A frame lease can be evicted during the first await, even if self.frame still matches.
        // Own every requested input now. Archival samples must not depend on perception completing.
        let lease = provider.lease(for: frame)
        let depth: DepthImage?
        let luma: LumaImage?
        var encoded: EncodedSemanticImage?
        let recordRequested = isRecording && recording?.wantsSample(at: frame.envelope.captureTimeMonotonic) == true
        let detectRequested = researchEnabled && objectsEnabled && objectsPrepared && wantsFindFrame == nil
            && resourceDecision.preset == .balanced && objectInferenceID == nil && clock.now() - lastObjectInference >= 0.12
        let findRequested = researchEnabled && resourceDecision.preset == .balanced && wantsFindFrame?() == true
        do {
            depth = try lease.copyDepthImage()
            luma = try? lease.copyLumaImage()
            let acquiredAt = clock.now()
            if recordRequested { recordingAttempts += 1 }
            do {
                encoded = recordRequested || detectRequested || findRequested
                    ? try lease.copySemanticImage(quarterTurn: FindPresentation.quarterTurn(frame.orientation)) : nil
            } catch {
                encoded = nil
                if recordRequested { recordingLastIssue = "Camera image encoding failed: \(error)." }
            }
            if recordRequested {
                if let encoded {
                    do {
                        // acquiredAt describes the validated lease access, not a later inference completion.
                        let accepted = try recording?.append(image: encoded, depth: depth, quality: nil, at: acquiredAt)
                        recordingStatus = "Recorded \(recording?.samples.count ?? 0) of 12 samples."
                        if accepted == true { recordingLastIssue = nil }
                        if accepted == false || recording?.isFull == true { finishRecording() }
                    } catch { recordingLastIssue = "The camera sample was expired or mismatched: \(error)." }
                } else if recordingLastIssue == nil {
                    recordingLastIssue = "The source camera frame was replaced before its image could be copied."
                }
            }
        } catch {
            if recordRequested { recordingLastIssue = "Depth/image acquisition failed: \(error)." }
            return
        }
        var completed = false
        defer {
            // A stopped/replaced generation cannot contaminate the next run's samples.
            if provider.activeContext == context {
                processingLatency.record(seconds: clock.now() - frame.envelope.captureTimeMonotonic,
                    accepted: completed && frame.envelope.isCurrent(in: context, at: clock.now()))
            }
        }
        let started = clock.now()
        var effectiveSettings = settings
        let adjustment = lowLightPolicy.update(image: luma, context: context, at: clock.now())
        if lightingSummary != adjustment.message { lightingSummary = adjustment.message }
        if autoBrightenPreview && effectiveSettings.enhanced {
            effectiveSettings.exposure = min(2, effectiveSettings.exposure + adjustment.exposure)
            effectiveSettings.shadowLift = adjustment.shadowLift
            effectiveSettings.gamma = adjustment.gamma
        }
        if !resourceDecision.allowsExpensiveEffects {
            effectiveSettings.edges = 0; effectiveSettings.highlightCompression = 0
            effectiveSettings.shadowLift = 0; effectiveSettings.gamma = 1
        }
        let output = renderer.render(lease: provider.lease(for: frame), frame: frame, settings: effectiveSettings)
        renderMilliseconds = (clock.now() - started) * 1000
        // Rendering may have used most of the 300 ms lifetime. Never publish a late result.
        guard let output, provider.activeContext == context,
              RenderBoundary.accepts(frame, context: context, orientation: viewport.orientation,
                                     viewport: viewport.size, at: clock.now()) else {
            latency.record(seconds: renderMilliseconds/1000, accepted: false)
            droppedFrames += 1; clearImage(); return
        }
        latency.record(seconds: renderMilliseconds/1000, accepted: true)
        if firstImageSeconds == nil, let metrics = provider.diagnostics {
            firstImageSeconds = clock.now() - metrics.startedAt
        }
        if calibration.context != nil && !calibration.validate(frame: frame, context: context, at: clock.now()) {
            invalidateMount(); configurePipeline()
        }
        // Swap image-bound overlays immediately, but publish text only after processing.
        // Clearing it here produced a blank/observation oscillation on every frame.
        self.frame = frame; image = output; overlayRequest = nil; advancedEvidence = nil
        var nextObservationSummary = "No current observations."
        var nextRegionSummary = "No current regional observations."
        // Start optional inference from the owned original while geometry works independently.
        // Waiting for both pipelines first consumed much of the image's original lifetime.
        if detectRequested, let encoded, frame.envelope.isCurrent(in: context, at: clock.now()) {
            detectObjects(encoded, depth: depth, context: context)
        }
        expiryTask?.cancel()
        let remaining = max(0, frame.envelope.expiresAtMonotonic - clock.now())
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled, self?.frame == frame else { return }
            self?.clearImage()
        }
        do {
            if researchEnabled {
                if pipelineContext != context { pipeline.start(context: context); pipelineContext = context }
                let eligibility = FeatureAvailabilityEvaluator.evaluate(.metricGeometry, frame: frame, context: context,
                    at: clock.now(), geometryEvidenceEnabled: researchEnabled)
                if let depth, eligibility.state == .enabled {
                    let snapshot = try await pipeline.process(depth, image: luma)
                    guard !Task.isCancelled, researchEnabled, provider.activeContext == context, self.frame == frame,
                          let snapshot, frame.envelope.isCurrent(in: context, at: clock.now()) else { return }
                    overlayRequest = RendererRequest(frame: frame, geometry: ProfilePresentation.prioritize(snapshot.geometry.observations, events: snapshot.events), context: context, at: clock.now())
                    advancedEvidence = snapshot.geometry.advanced
                    // Events describe newly delivered alerts; their absence is not object disappearance.
                    nextObservationSummary = snapshot.geometry.observations.isEmpty
                        ? "No supported obstacle observation. Unobserved regions remain unknown."
                        : "Current depth geometry observed. These are generic surfaces, not identified objects."
                    nextRegionSummary = snapshot.geometry.regions.map { region in
                        let stable = distanceReadout.update(key: region.region.rawValue, rangeMeters: region.nearestRangeMeters,
                            envelope: frame.envelope, context: context, at: clock.now())
                        let range = stable.map { String(format: "observed region about %.1f meters", $0) } ?? "unknown"
                        return "\(region.region.rawValue.capitalized): \(range)."
                    }.joined(separator: " ")
                    feedbackFailure = nil
                    feedback.consume(pipeline.ledger)
                } else { distanceReadout.reset(); nextObservationSummary = "Depth unavailable; nearby obstacles are unknown." }
            }
            // Evaluate image-only sessions as well; geometry feedback never waits for this separate session update.
            _ = try await qualityPipeline.process(frame: frame, depth: depth, image: luma)
            guard provider.activeContext == context, self.frame == frame,
                  frame.envelope.isCurrent(in: context, at: clock.now()) else { return }
            if observationSummary != nextObservationSummary { observationSummary = nextObservationSummary }
            if regionSummary != nextRegionSummary { regionSummary = nextRegionSummary }
            summaryEnvelope = frame.envelope
            completed = true
            if qualitySnapshot?.frame == frame, let quality = qualitySnapshot?.quality {
                try? recording?.attachQuality(quality, to: frame.envelope.frameID)
            }
            // Explicit Find consumer only, after mandatory geometry/quality processing. One bounded image at a time.
            if findRequested, researchEnabled,
               provider.activeContext == context, self.frame == frame,
               frame.envelope.isCurrent(in: context, at: clock.now()),
               let encoded {
                onFindFrame?(encoded, depth)
            }
        } catch is CancellationError { return }
        catch {
            guard provider.activeContext == context else { return }
            clearImage(); feedbackFailure = "Research processing stopped: \(error). End and restart capture to try again."
            // Includes producer ledger overflow: cancel the run rather than silently losing a critical batch.
            pause()
        }
    }
    func tickFeedback() {
        if isRecording, recording?.samples.isEmpty == true {
            let issue = recordingLastIssue ?? "Waiting for a source camera frame."
            let message = "0 of 12 samples; \(recordingAttempts) acquisition attempts. \(issue)"
            if recordingStatus != message { recordingStatus = message }
        }
        if let deadline = recordingDeadline, clock.now() >= deadline { finishRecording() }
        if let deadline = descriptionDeadline, clock.now() >= deadline {
            requestedDescription = nil; descriptionDeadline = nil; assistantReply = "No current matching object result. Distance is unknown."
        }
        if let envelope = assistantEnvelope, let context = provider.activeContext,
           !envelope.isCurrent(in: context, at: clock.now()) {
            assistantEnvelope = nil; assistantReply = "That observation expired. Request a fresh description."
        }
        if !objects.isEmpty, let context = provider.activeContext {
            let current = objects.filter { $0.envelope.isCurrent(in: context, at: clock.now()) }
            if current.count != objects.count {
                objects = current
                if current.isEmpty { objectTracker.reset(); objectStatus = "Object result expired; waiting for a current observation." }
            }
        }
        if let envelope = summaryEnvelope, let context = provider.activeContext,
           !envelope.isCurrent(in: context, at: clock.now()) {
            summaryEnvelope = nil; distanceReadout.reset()
            observationSummary = "No current observations."; regionSummary = "No current regional observations."
        }
        if clock.now() - lastResourceCheck >= 1 { refreshResources(); objectWillChange.send() }
        feedback.tick()
        if active && researchEnabled {
            feedback.consume(pipeline.ledger)
            feedback.consume(qualityPipeline.ledger)
        }
    }
    func refreshResources(memoryWarning: Bool = false) {
        lastResourceCheck = clock.now()
        let thermal: ResourcePressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .elevated
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .critical
        }
        let decision = resourcePolicy.update(thermal: thermal, capture: capturePressure,
            lowPower: preferLowPower || ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryWarning: memoryWarning, latencyExceeded: active && renderMilliseconds > 100, at: lastResourceCheck)
        if resourceDecision != decision { resourceDecision = decision }
        if memoryWarning { renderer.purgeCaches(); clearImage() }
        if decision.suspended && active { stop() }
    }
    private func updateChannels() {
        feedback.setChannels(OutputChannels(speech: speechEnabled, haptics: hapticsEnabled,
            spatial: spatialEnabled, watch: watchEnabled))
    }
    private func clearImage() {
        lowLightPolicy.reset()
        lightingSummary = "Lighting has not been measured from a current image."
        if assistantEnvelope != nil { assistantEnvelope = nil; assistantReply = "Current image lost. Request a fresh description." }
        clearObjects()
        // A transient expired/changed viewport clears live evidence, but recording can wait for
        // the next source frame within its fixed 15-second window. Stop/background still ends it.
        distanceReadout.reset(); summaryEnvelope = nil
        onFindSceneLost?()
        invalidateMount()
        let hadScene = frame != nil || overlayRequest != nil || qualitySnapshot?.frame != nil
        expiryTask?.cancel(); expiryTask = nil; image = nil; frame = nil; overlayRequest = nil; advancedEvidence = nil
        observationSummary = "No current observations."; regionSummary = "No current regional observations."; configurePipeline()
        // Status and watchdog can report the same loss; keep the one newly emitted outage cue.
        if hadScene || !active { feedback.invalidateScene(reason: "frameOrViewportUnavailable") }
        if active && (status.phase == .running || status.phase == .unavailable || qualitySnapshot?.frame != nil) {
            do { try qualityPipeline.markUnavailable() }
            catch { feedbackFailure = "Sensing updates stopped. End and restart capture to try again."; stop() }
        }
    }
}

/// The UIKit surface reports its own window orientation and pixel dimensions, not the enclosing screen.
struct CameraSurface: UIViewRepresentable {
    let image: CGImage?
    let updateViewport: (CaptureViewport) -> Void
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.backgroundColor = .black; view.contentMode = .scaleToFill
        view.isAccessibilityElement = true; view.accessibilityLabel = "Live camera image. No obstacle guidance."
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        view.report = updateViewport
        view.image = image.map { UIImage(cgImage: $0) }
        view.setNeedsLayout()
    }
    final class Surface: UIImageView {
        var report: ((CaptureViewport) -> Void)?
        private var last: CaptureViewport?
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let scene = window?.windowScene, bounds.width > 0, bounds.height > 0 else { return }
            let orientation: ImageOrientation
            switch scene.interfaceOrientation {
            case .portrait: orientation = .portrait
            case .portraitUpsideDown: orientation = .portraitUpsideDown
            case .landscapeLeft: orientation = .landscapeLeft
            case .landscapeRight: orientation = .landscapeRight
            default: return
            }
            let size = PixelSize(width: Int((bounds.width * scene.screen.scale).rounded()),
                                 height: Int((bounds.height * scene.screen.scale).rounded()))
            let value = CaptureViewport(orientation: orientation, size: size)
            guard value != last else { return }
            last = value
            image = nil // Clear old orientation immediately, before publishing SwiftUI state.
            DispatchQueue.main.async { [weak self] in
                guard self?.window != nil, self?.last == value else { return }
                self?.report?(value)
            }
        }
    }
}

struct LiveCameraView: View {
    @EnvironmentObject private var interfaceMode: InterfaceMode
    @EnvironmentObject private var presentation: PresentationSettings
    @StateObject private var model: LiveRenderModel
    init(profile: VisionProfile? = nil) { _model = StateObject(wrappedValue: LiveRenderModel(profile: profile)) }
    @State private var help = false
    @State private var assistant = false
    @State private var helpAfterAssistant = false
    @State private var recordingConsent = false
    @State private var recordingEnvironment = ""
    @State private var recordingLabel = ""
    @State private var measuredRange = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    ShellSectionHeading(model.capabilities.preferredMode == nil ? "Camera unavailable" : model.paused ? "Live view paused" : model.active ? "Current camera" : "Camera ready", subtitle: nil)
                    Text(model.outputStatus).modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk).accessibilityIdentifier("feedback.channels")
                    if model.researchEnabled {
                        LumaNotice(title: "Stationary Research trial", detail: "Sensing and object names are unvalidated. Keep using your usual aids. No walking guidance.")
                    } else {
                        Text("Adjust your camera image. Research sensing is off; no walking guidance.").modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                    }
                    if model.capabilities.preferredMode == nil {
                        Text("Live view is unavailable on this device. Try Enhancement preview with the static fixture.")
                            .accessibilityIdentifier("live.unsupported")
                    }
                    if model.paused { Text("Paused — resume explicitly to request fresh frames.") }
                    if model.mode == .cameraOnly { Text("Camera only — depth is unavailable.") }
                    if model.mode == .liveDepth { Text(model.researchEnabled ? "Depth-capable Research capture; sensing is unvalidated." : "Depth-capable capture. Research feedback is off.") }
                }
                if presentation.style == .voice { observationPanel }
                if model.isRecording {
                    Label("Recording: \(model.recording?.samples.count ?? 0) of 12 samples", systemImage: "record.circle")
                        .font(.headline).accessibilityIdentifier("recording.progress")
                    ProgressView(value: Double(model.recording?.samples.count ?? 0), total: 12)
                        .accessibilityLabel("Research recording sample progress")
                    Text(model.recordingStatus).modifier(LumaSecondaryText())
                }
                CameraSurface(image: model.image, updateViewport: model.updateViewport)
                    .frame(height: typeSize.isAccessibilitySize || presentation.style == .voice ? 120 : presentation.style == .visual ? 300 : 220).clipped()
                    .overlay {
                        if let request = model.overlayRequest, let frame = model.frame {
                            FrameOverlayView(request: request, displayedFrame: frame,
                                context: CaptureContext(sessionID: frame.envelope.frameID.sessionID, generation: frame.envelope.frameID.generation, mode: frame.envelope.sourceMode),
                                orientation: frame.orientation, viewport: frame.viewportSize,
                                outlineWidth: model.preferences.outlineWidth, color: model.preferences.outlineColor.swiftUIColor,
                                dualStroke: model.preferences.dualStroke, density: model.preferences.density)
                        }
                    }
                    .overlay {
                        if model.image == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: model.paused ? "pause.circle" : "camera").font(.title).accessibilityHidden(true)
                                Text("No current camera image")
                            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(LumaTheme.sunken).foregroundStyle(LumaTheme.ink)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 28))

                if presentation.style != .voice { observationPanel }
                ShellCard {
                    ShellSectionHeading("Dim-light camera", subtitle: nil)
                    Toggle("Brighten dim camera image", isOn: $model.autoBrightenPreview).disabled(!model.settings.enhanced)
                    if !model.settings.enhanced {
                        Text("Original image is selected. Enable Enhanced image under Adjust camera image to apply preview brightening.").modifier(LumaSecondaryText())
                    }
                    Text(model.lightingSummary).modifier(LumaSecondaryText())
                    Button(model.flashlightEnabled ? "Turn flashlight off" : "Turn flashlight on") { model.toggleFlashlight() }
                        .buttonStyle(ShellButtonStyle()).disabled(!model.active || model.isRecording)
                    Text(model.flashlightStatus).modifier(LumaSecondaryText())
                    Text("Preview brightening changes the display only. Original images are recorded and used for detection. Set the flashlight before recording; it turns off when capture ends.").modifier(LumaSecondaryText())
                }
                Button { assistant = true } label: { Label("Speak command", systemImage: "mic") }
                    .buttonStyle(ShellButtonStyle()).accessibilityIdentifier("live.assistant")
                InteractionShortcut()
                DisclosureGroup("Sensing status: \(model.qualitySnapshot?.quality.state.rawValue ?? "not started")") {
                    Text(model.qualitySummary).accessibilityIdentifier("quality.summary")
                    SensingQualityDetailsView(quality: model.qualitySnapshot?.quality)
                }
                DisclosureGroup("Camera and power options") {
                Text("Profile: \(model.profile?.name ?? "Neutral defaults")")
                Toggle("Use camera only", isOn: $model.cameraOnlySelected)
                Toggle("Reduce resource use", isOn: $model.preferLowPower)
                Text(model.resourceSummary).accessibilityIdentifier("resource.summary")
                Text("Changing camera mode ends capture. Start again for fresh images. Distance sensing needs supported depth and its validation gates.")
                if model.mode == .cameraOnly {
                    Text("Camera-only mode. Distance sensing is unavailable. Profiles and Help remain available. Saved place names and notes are available from Home and Find. Find targets, routes, and reports are still awaiting product integration.")
                }
                }
                if interfaceMode.developer || model.recording != nil {
                DisclosureGroup("Collect research data") {
                    Text("Record synchronized camera JPEG, depth, confidence, camera calibration/pose and quality. No microphone, GPS or raw IMU is recorded. Samples stay on this device until you choose Share.")
                    if model.recording == nil {
                        TextField("Anonymous room ID (for example room-a)", text: $recordingEnvironment)
                        TextField("Stationary target (for example chair)", text: $recordingLabel)
                        TextField("Independently measured range in meters (optional)", text: $measuredRange).keyboardType(.decimalPad)
                        Toggle("I have permission to record this scene and any people in it", isOn: $recordingConsent)
                        Button("Start 12-sample recording") {
                            model.startRecording(consent: recordingConsent, environment: recordingEnvironment, label: recordingLabel, measuredRange: measuredRange)
                        }.buttonStyle(ShellButtonStyle(prominent: true)).disabled(!model.active || !recordingConsent)
                    } else {
                        Text("Room: \(model.recording!.environment). Target: \(model.recording!.targetLabel). Keep the target and camera stationary during this short recording.")
                        Text("Independent measured range: \(model.recording!.measuredRangeMeters.map { String(format: "%.2f m", $0) } ?? "unlabelled")")
                        if model.isRecording { Button("Stop recording") { model.finishRecording() }.buttonStyle(ShellButtonStyle()) }
                        else {
                            Button("Prepare export") { model.exportRecording() }.buttonStyle(ShellButtonStyle()).disabled(model.recording?.samples.isEmpty != false)
                            if let url = model.recordingExportURL { ShareLink("Share recording…", item: url).buttonStyle(ShellButtonStyle()) }
                            Button("Delete recording", role: .destructive) { model.deleteRecording() }.buttonStyle(ShellButtonStyle())
                        }
                    }
                    Text(model.recordingStatus)
                    if let issue = model.recordingLastIssue { Text(issue).modifier(LumaSecondaryText()) }
                    Text("Use an anonymous room ID. Avoid faces, addresses and personal papers. Use a protected stationary setup. These samples are research data, not proof of navigation safety.").modifier(LumaSecondaryText())
                }
                }
                if let failure = model.feedbackFailure { Text(failure) }
                if interfaceMode.developer {
                DisclosureGroup("Research feedback — unvalidated") {
                    Toggle("Enable Research overlays and feedback", isOn: $model.researchEnabled)
                    Toggle("Recognize objects on this device", isOn: $model.objectsEnabled)
                    Picker("Object detector", selection: $model.objectPreset) {
                        ForEach(SceneDetectorPreset.allCases, id: \.self) { preset in Text(preset.title).tag(preset) }
                    }.disabled(model.isRecording)
                    Text("Changing detector ends capture. Full YOLOv3 has more capacity than Tiny; device speed and accuracy still need comparison.").modifier(LumaSecondaryText())
                    DisclosureGroup("Supported object categories") {
                        Text(SceneObjectLabels.names.sorted().map { $0.capitalized }.joined(separator: ", "))
                        Text("Neither detector includes doors, stairs, curbs or potholes as trained classes. Unrecognized objects and surfaces can still be present.")
                    }
                    Text(model.objectStatus)
                    Text("Changing Research mode ends capture. Start explicitly after choosing channels. This does not activate validated guidance.")
                    Toggle("Phone speech", isOn: $model.speechEnabled).disabled(!model.researchEnabled || (!model.outputCapabilities.speech && !model.speechEnabled))
                    Toggle("Phone haptics", isOn: $model.hapticsEnabled).disabled(!model.researchEnabled || (!model.outputCapabilities.haptics && !model.hapticsEnabled))
                    if let reason = model.outputCapabilities.reason { Text(reason) }
                    Text("Scene cues expire after 300 ms and speech may be cut short. Preview complete cues in Settings. Haptic meanings and physical latency remain unvalidated.")
                }
                }
                if let reason = model.status.reason, model.status.phase != .running {
                    Text("Current image unavailable (\(reason)). Check camera access or end and restart capture.")
                }
                if model.capabilities.cameraPermission == .denied || model.capabilities.cameraPermission == .restricted {
                    Text("Camera access is denied or restricted. No live image is available.")
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }
                if interfaceMode.developer {
                DisclosureGroup("Mount and accessories — Research") {
                    MountInstructions()
                    Picker("Phone mount", selection: $model.mountMode) {
                        Text("Handheld").tag(MountMode.handheld)
                        Text("Chest mounted").tag(MountMode.chestMounted)
                    }
                    Text("Only this mount preference is saved. Alignment is checked again each session. Changing mount or measured height ends capture.")
                    if model.mountMode == .chestMounted {
                        TextField("Measured camera height above level floor (meters, optional)", text: $model.measuredHeight)
                            .keyboardType(.decimalPad)
                        Text("Use a measured stationary rig height only. Blank or invalid height keeps floor evidence unknown; body height is not camera height.")
                    }
                    Toggle("I am stationary, with the rear camera facing forward", isOn: $model.stationaryConfirmed)
                    Toggle("Camera is clear and covers the intended view", isOn: $model.coverageConfirmed)
                    Toggle("Usual aid and safe protected setup checked", isOn: $model.usualAidConfirmed)
                    Button("Confirm phone-forward alignment") { model.confirmMount() }.disabled(!model.canConfirmMount).frame(minHeight: 56)
                    Text(model.mountStatus).accessibilityIdentifier("mount.status")
                    Toggle("Phone-relative spatial cues", isOn: $model.spatialEnabled).disabled(!model.researchEnabled)
                    Toggle("Stereo headphones are worn; output is not a speaker", isOn: $model.headphonesConfirmed)
                    Toggle("Watch Research cues", isOn: $model.watchEnabled).disabled(!model.researchEnabled)
                    Text(model.watchStatus)
                    Text("Watch changes end capture. Start again, then enable Research cues in the foreground watch app. Watch loss never pauses phone output.")
                    Toggle("Advanced hazard candidates — Research", isOn: $model.advancedEnabled).disabled(!model.researchEnabled)
                    Stepper("Required clearance: \(model.clearanceHeight, specifier: "%.2f") meters", value: $model.clearanceHeight, in: 0.8...2.5, step: 0.05)
                    if model.geometryProfile == nil { Text("Advanced candidates unavailable: saved required width must be 0.3–2 meters for this producer. Edit the profile; it has not been clamped.") }
                    Text("Overhead, narrow passage, steps, stairs and moving-obstacle candidates remain uncertain and Research-only. Missing depth is unknown, never a drop-off. No walking direction is inferred from the phone.")
                }
                if model.advancedEnabled {
                    DisclosureGroup("Current advanced evidence and uncertainty") { AdvancedEvidenceView(result: model.advancedEvidence) }
                }
                }
                DisclosureGroup("Adjust camera image") { EnhancementControls(settings: $model.settings) }
                if interfaceMode.developer { DisclosureGroup("Renderer diagnostics") {
                    Text(model.captureSummary)
                    Text(model.processingSummary)
                    Text("Times start after permission. Rates include startup and outages. Driver/hardware drops, screen presentation, audible delivery, memory and battery require separate device measurements.")
                    Text(model.latencySummary)
                    Text(String(format: "Last render: %.1f ms; rejected renders: %d", model.renderMilliseconds, model.droppedFrames))
                    Text("One current image, at most 1280 pixels on the longer side. Timing here is not a device benchmark.")
                } }
            }.padding(.horizontal, typeSize.isAccessibilitySize ? 16 : 24).padding(.vertical, 16)
        }
        .scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Live view").navigationBarTitleDisplayMode(.inline)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttons }
                    VStack(spacing: 12) { buttons }
                }
            }.padding(16).background(LumaTheme.surface)
        }
        .sheet(isPresented: $help) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Live view paused").font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text("No contact has been called or messaged. Contact someone you choose using Phone or Messages. Close Help, then resume when ready.")
                        Button("Close Help") { help = false }.buttonStyle(ShellButtonStyle())
                    }.padding(24)
                }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Help").navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $assistant, onDismiss: {
            if helpAfterAssistant { helpAfterAssistant = false; help = true }
        }) { LiveVoiceAssistant(model: model) { helpAfterAssistant = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.pause() } }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in model.refreshResources() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in model.refreshResources() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.refreshResources(memoryWarning: true) }
        .task { await model.prepareObjects() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                model.tickFeedback()
            }
        }
    }
    private var observationPanel: some View {
        ShellCard {
            ShellSectionHeading("Observations", subtitle: "Current camera · only fresh evidence is shown")
            Text(model.observationSummary).modifier(LumaObservationText()).accessibilityIdentifier("feedback.summary")
            if model.researchEnabled && model.objectsEnabled {
                ForEach(Array(model.objects.prefix(5))) { object in
                    Text(object.text).font(.title2).accessibilityElement(children: .combine)
                }
                Text(model.objectStatus).modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                Text("A distance requires depth from the object’s own camera frame. Unmeasured distances stay unknown.").modifier(LumaSecondaryText())
            }
            if model.researchEnabled || model.preferences.focus != .wholeScene {
                Text(model.preferences.focus == .wideSceneSummary ? "Wide-scene summary" : "Central summary").font(.headline)
                Text(model.regionSummary)
                Text("Summary placement only. Outlines retain their measured positions.").modifier(LumaSecondaryText())
            }
        }
    }
    @ViewBuilder private var buttons: some View {
        Button(model.active ? "Pause" : model.paused ? "Resume" : "Start live view") {
            if model.active { model.pause() } else { model.start() }
        }.disabled(!model.active && !model.canStart).buttonStyle(ShellButtonStyle(prominent: true))
        Button("Help") { model.pause(); help = true }.buttonStyle(ShellButtonStyle())
        Button("End live view") { model.stop() }.buttonStyle(ShellButtonStyle(destructive: true))
    }
}

private struct LiveVoiceAssistant: View {
    @ObservedObject var model: LiveRenderModel
    let openHelp: () -> Void
    @StateObject private var speech = PushToTalkModel()
    @State private var input = ""
    @State private var proposal: LiveVoiceAction?
    @State private var reviewedInput = ""
    @FocusState private var editing: Bool
    @State private var reviewStatus = "Say ‘what is ahead’, ‘how far is the chair’, ‘pause’, ‘resume’ or ‘help’."
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ShellCard {
                        ShellSectionHeading("Speak or type", subtitle: "English on-device speech. Review the command before it runs.")
                        Text("Using the microphone pauses capture and speech output. A description command requests fresh camera images after confirmation.").modifier(LumaSecondaryText())
                        if speech.listening || speech.requesting {
                            Button("Review speech") { input = speech.finish(); review() }.disabled(speech.requesting).buttonStyle(ShellButtonStyle(prominent: true))
                            Button("Cancel microphone") { speech.cancel(clearTranscript: true) }.buttonStyle(ShellButtonStyle())
                        } else {
                            Button("Speak command") { proposal = nil; model.pause(); speech.start() }.buttonStyle(ShellButtonStyle(prominent: true))
                            if !speech.transcript.isEmpty { Button("Use captured speech") { input = speech.finish(); review() }.buttonStyle(ShellButtonStyle()) }
                        }
                        Label(speech.listening ? "Listening" : speech.requesting ? "Checking microphone access" : "Microphone off", systemImage: speech.listening ? "mic.fill" : "mic.slash").font(.headline)
                        Text(speech.status).modifier(LumaSecondaryText())
                        if !speech.transcript.isEmpty { Text(speech.transcript).accessibilityLabel("Captured speech: \(speech.transcript)") }
                        Text("Live command").font(.headline)
                        TextField("Type a command", text: $input, axis: .vertical).textFieldStyle(.roundedBorder).focused($editing)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("live.assistant.input")
                            .onChange(of: input) { _, value in if value != reviewedInput { proposal = nil }; if value.count > 161 { input = String(value.prefix(161)) } }
                        Button("Review typed command") { editing = false; speech.cancel(); review() }.buttonStyle(ShellButtonStyle())
                        Text(reviewStatus)
                        if let proposal {
                            Text(proposal.reviewText).font(.headline)
                            Button("Confirm command") {
                                speech.cancel(clearTranscript: true); model.runVoiceCommand(proposal); self.proposal = nil
                                if proposal == .help { dismiss(); openHelp() }
                            }.buttonStyle(ShellButtonStyle(prominent: true))
                            Button("Dismiss command") { self.proposal = nil }.buttonStyle(ShellButtonStyle())
                        }
                    }
                    ShellCard {
                        Label("Assistant response", systemImage: "text.bubble").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(model.assistantReply).font(.title3)
                        Text("Object answers need Research capture. Optional Phone speech uses the current frame deadline and may be cut short; VoiceOver can read the text. This is not a conversational VLM or walking assistant.").modifier(LumaSecondaryText())
                        Toggle("Phone speech", isOn: $model.speechEnabled).disabled(!model.researchEnabled)
                    }
                }.padding()
            }.scrollDismissesKeyboard(.interactively).scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Voice assistant").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { speech.cancel(clearTranscript: true); dismiss() } }
        }
        .onDisappear { speech.cancel(clearTranscript: true) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { speech.cancel(clearTranscript: true); proposal = nil; model.pause() } }
    }
    private func review() {
        reviewedInput = input
        proposal = LiveVoiceCommandParser.parse(input)
        reviewStatus = proposal == nil ? "Try one command: describe scene, how far is the chair, pause, resume, end live view, or help." : "Review the action, then confirm or dismiss."
    }
}

struct EnhancementControls: View {
    @Binding var settings: EnhancementSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enhanced image", isOn: $settings.enhanced).accessibilityIdentifier("render.enhanced")
            Text(settings.enhanced ? "Enhanced" : "Original — all enhancement bypassed").accessibilityIdentifier("render.mode")
            Group {
                slider("Brightness (exposure)", value: $settings.exposure, range: -1...2)
                slider("Contrast", value: $settings.contrast, range: 0.5...2)
                slider("Highlight compression", value: $settings.highlightCompression, range: 0...1)
                slider("Image edges", value: $settings.edges, range: 0...1)
            }.disabled(!settings.enhanced)
            Text("Edges show changes in image brightness. They are not detected obstacles.").modifier(LumaMetadataText())
            Button("Reset enhancement") { settings = EnhancementSettings() }.frame(minHeight: 56).buttonStyle(.bordered)
            Text("These adjustments are temporary for this view. Edit a named profile in Profiles to save preferences.").modifier(LumaMetadataText())
        }
    }
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(label): \(value.wrappedValue, specifier: "%.2f")")
            Slider(value: value, in: range, step: 0.05) { Text(label) }.frame(minHeight: 44)
        }
    }
}

struct EnhancementPreviewView: View {
    @State private var settings = EnhancementSettings()
    @State private var image: CGImage?
    @State private var renderer = FrameRenderer()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Static synthetic fixture — not a current observation").font(.headline)
                Text("Preview uses a bundled calibration image. No camera permission is needed.")
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel("Synthetic scene with colored calibration corners and a yellow center rectangle.")
                } else { Text("The static preview image could not be rendered.") }
                EnhancementControls(settings: $settings)
            }.padding()
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Enhancement preview").navigationBarTitleDisplayMode(.inline)
        .onAppear { render() }
        .onChange(of: settings) { _, _ in render() }
    }
    private func render() {
        guard let url = try? ReplayFixtures.url("synthetic-scene.png"),
              let source = UIImage(contentsOfFile: url.path)?.cgImage else { image = nil; return }
        image = renderer.preview(source, settings: settings)
    }
}
