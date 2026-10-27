import Foundation
import SwiftUI
import LumaPathDomain
import LumaPathGoals
import LumaPathModels
import LumaPathPerception
import LumaPathCommands
import LumaPathAttention
import LumaPathPersonalization
import LumaPathFeedback

@MainActor final class FindModel: ObservableObject {
    let live: LiveRenderModel
    let speech = PushToTalkModel()
    private let clock: any MonotonicClock
    private let ocr = VisionOCRAdapter()
    private var resolver = GoalResolver()
    private var review = CommandReviewSession()
    private var attention = LocalAttention()
    private var inference: Task<Void, Never>?
    private var inferenceID: UUID?
    private var lastInference: Double = -.infinity
    private var context = CaptureContext(sessionID: UUID(), generation: 0, mode: .cameraOnly)
    private var profileRevision: UInt64 = 0
    private var selectedTarget: GoalTarget?
    private var awaitingCapture = false
    private var timeoutAnnounced = false
    @Published private(set) var snapshot: GoalSearchSnapshot
    @Published private(set) var proposal: CommandProposal?
    @Published private(set) var reviewedWords = ""
    @Published private(set) var message = "Choose a target or type a command. No search is running."
    @Published private(set) var inferenceStatus = "No image inference requested."
    @Published private(set) var detail: SpeechDetail
    @Published var input = "" {
        didSet { if input != oldValue && proposal != nil { dismissReview() } }
    }
    @Published private(set) var paused = false
    var reviewContext: CommandReviewContext {
        CommandReviewContext(capture: context, goalRevision: snapshot.revision, profileRevision: profileRevision)
    }
    init(profile: VisionProfile? = nil, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.clock = clock; live = LiveRenderModel(profile: profile)
        snapshot = resolver.snapshot
        detail = SpeechDetail(rawValue: profile?.preferences.speechDetail.rawValue ?? "standard") ?? .standard
        live.onFindStarted = { [weak self] in self?.captureStarted($0) }
        live.onFindStopped = { [weak self] in self?.captureStopped() }
        live.wantsFindFrame = { [weak self] in
            guard let self else { return false }
            return self.inferenceID == nil && self.clock.now() - self.lastInference >= 2
                && [.searching, .candidate].contains(self.snapshot.phase) && self.snapshot.target == .exitSign
        }
        live.onFindFrame = { [weak self] image, depth in self?.recognize(image, depth: depth) }
        live.onFindSceneLost = { [weak self] in self?.sceneLost() }
        bindReview()
    }
    deinit { inference?.cancel() }
    private func bindReview() { review.bind(to: reviewContext); proposal = review.pending; attention.bind(reviewContext) }
    func submit(_ text: String, source: CommandInputSource = .typedUser) {
        switch source {
        case .sceneText, .communityText, .remoteHypothesis:
            message = FindPresentation.clarification(.rejected(.untrustedSource)); return
        case .typedUser, .pushToTalkUser: break
        }
        speech.cancel()
        reviewedWords = text
        bindReview()
        message = FindPresentation.clarification(review.submit(text, source: source))
        proposal = review.pending
    }
    func dismissReview() { review.cancelReview(); proposal = nil; message = "Command dismissed. Nothing changed." }
    func confirm() {
        guard let proposal, let command = review.confirm(proposal.id, in: reviewContext) else { return }
        self.proposal = nil
        switch command {
        case .find(let target): begin(target)
        case .pause: pause()
        case .resume:
            if paused, let target = selectedTarget { begin(target) }
            else { message = "No paused search to resume." }
        case .cancel: stop()
        case .setDetail(let detail):
            self.detail = detail; profileRevision &+= 1; live.invalidateFindOutput()
            cancelInference(); bindReview(); message = "Using \(detail.rawValue) descriptions for this search."
        case .repeatCandidate: repeatCandidate()
        case .nextCandidate:
            resolver.next(context: context, at: clock.now()); refresh(); announce(explicit: true)
        }
    }
    private func begin(_ target: GoalTarget) {
        timeoutAnnounced = false
        speech.cancel(); cancelInference(); live.invalidateFindOutput(); selectedTarget = target; paused = false
        context = live.findContext ?? CaptureContext(sessionID: context.sessionID, generation: context.generation + 1, mode: .cameraOnly)
        _ = resolver.begin(target, context: context, research: live.researchEnabled, at: clock.now())
        refresh(); bindReview()
        guard snapshot.phase != .unavailable else { message = FindPresentation.unavailable(target, research: live.researchEnabled); return }
        if live.active { message = "Target changed. Scanning current images; mandatory alerts continue."; return }
        guard live.canStart else {
            resolver.invalidate(reason: "cameraUnavailable"); refresh(); bindReview()
            message = "Camera unavailable. Check camera permission and device support. Typed commands still work."; return
        }
        awaitingCapture = true
        message = "Requesting camera access for a stationary Research scan. Keep using your usual aids."
        live.start()
    }
    // Trusted coordinator callback, including its automatic camera-only fallback generation.
    func captureStarted(_ context: CaptureContext) {
        guard let selectedTarget, !paused else { return }
        cancelInference(); live.invalidateFindOutput()
        awaitingCapture = false; timeoutAnnounced = false; self.context = context
        _ = resolver.begin(selectedTarget, context: context, research: live.researchEnabled, at: clock.now())
        lastInference = -.infinity; refresh(); bindReview()
        message = snapshot.phase == .unavailable
            ? FindPresentation.unavailable(selectedTarget, research: live.researchEnabled)
            : "Stationary Research scan. A sign candidate is not a safe route."
    }
    private func captureStopped() {
        awaitingCapture = false; cancelInference()
        // A successful user completion still shuts down capture and output, but remains completed.
        if snapshot.phase != .completed { resolver.invalidate(reason: "captureStopped") }
        inferenceStatus = "No image inference requested."
        live.invalidateFindOutput(); refresh(); bindReview()
    }
    func pause() {
        let hadSearch = selectedTarget != nil
        speech.cancel(clearTranscript: true); live.stop(); review.cancelReview(); proposal = nil; paused = hadSearch
        message = "Search paused. Resume explicitly for fresh observations."
    }
    func stop() {
        speech.cancel(clearTranscript: true); live.stop(); selectedTarget = nil; paused = false; review.end(); proposal = nil
        resolver.invalidate(); refresh()
        attention.reset(); input = ""; message = "Search stopped. No current candidate."
    }
    func researchChanged() { stop() }
    func startSpeech() {
        // Audio capture is a separate explicit interaction, never concurrent with guidance output.
        pause(); review.cancelReview(); proposal = nil
        speech.start()
    }
    func useTranscript() {
        let text = speech.finish()
        input = text; submit(text, source: .pushToTalkUser)
    }
    func tick() {
        live.tickFeedback(); resolver.tick(context: context, at: clock.now()); refresh()
        if !timeoutAnnounced && snapshot.phase == .notObservedYet {
            timeoutAnnounced = true
            let now = clock.now()
            live.enqueueFind(FeedbackItem(context: context, createdAt: now, expiresAt: now + 2,
                kind: .goal, priority: 1, text: "Not observed yet. Continue, change target, or stop.",
                repeatKey: "find.timeout", source: "localSearchState"))
        }
        if awaitingCapture && [.blocked, .unavailable, .stopped].contains(live.status.phase) {
            // Start authorization is asynchronous; stopped is normal before the first callback.
            if live.status.phase != .stopped {
                awaitingCapture = false; resolver.invalidate(reason: "cameraUnavailable"); refresh(); bindReview()
                message = "Camera could not start. Check permission or device support; typed commands remain available."
            }
        }
    }
    private func refresh() {
        let next = resolver.snapshot
        // Freshness is checked at 40 Hz, but an idle screen must not redraw at that rate.
        guard next.revision != snapshot.revision || next.target != snapshot.target || next.phase != snapshot.phase
            || next.reason != snapshot.reason || next.candidate?.observation.id != snapshot.candidate?.observation.id
            || next.rememberedCandidate?.landmarkID != snapshot.rememberedCandidate?.landmarkID else { return }
        snapshot = next
    }
    private func cancelInference() { inference?.cancel() }
    private func sceneLost() {
        if inferenceID != nil { inferenceStatus = "Current image lost or expired. Pending OCR cancelled." }
        cancelInference(); resolver.tick(context: context, at: clock.now()); live.invalidateFindOutput()
        // Viewport changes can occur while an envelope is still young; invalidate its candidates too.
        resolver.clearCurrentCandidates(context: context, at: clock.now()); refresh()
    }
    private func recognize(_ image: EncodedSemanticImage, depth: DepthImage?) {
        guard inferenceID == nil, let revision = snapshot.revision, image.frame.envelope.isCurrent(in: context, at: clock.now()) else { return }
        let token = UUID(), context = context, profileRevision = profileRevision
        inferenceID = token; lastInference = clock.now(); inferenceStatus = "Reading one current image on this device."
        inference = Task { [weak self, ocr] in
            defer { if let self, self.inferenceID == token { self.inferenceID = nil; self.inference = nil } }
            do {
                let batch = try await ocr.recognize(image, context: context)
                guard let self, !Task.isCancelled, self.inferenceID == token,
                      self.context == context, self.snapshot.revision == revision, self.profileRevision == profileRevision,
                      batch.frame.envelope.isCurrent(in: context, at: self.clock.now()) else { return }
                let associations = batch.observations.map { DepthAssociator.associate($0, depth: depth, context: context, at: self.clock.now()) }
                self.receive(batch, associations: associations, revision: revision, context: context)
            } catch {
                if let self, self.inferenceID == token, !Task.isCancelled {
                    self.inferenceStatus = "No fresh OCR result. Slow or expired results are discarded; try again from a stationary position."
                }
            }
        }
    }
    /// Trusted inference boundary; the resolver independently checks generation, revision and expiry.
    func receive(_ batch: SemanticBatch, associations: [DepthAssociation], revision: UUID, context: CaptureContext) {
        if resolver.update(batch, associations: associations, revision: revision, context: context, at: clock.now()) {
            refresh(); inferenceStatus = "Current image checked. Only supported candidates are shown."
            announce(explicit: false)
        }
    }
    private func announce(explicit: Bool) {
        resolver.tick(context: context, at: clock.now()); refresh()
        guard var candidate = snapshot.candidate else { message = "No current candidate to repeat. Keep scanning or change target."; return }
        if !explicit {
            let candidates = resolver.currentCandidates.map { item in
                AttentionCandidate(id: item.observation.id, envelope: item.observation.envelope,
                    target: item.observation.target!, source: item.observation.source,
                    informationKey: "\(item.observation.target!.rawValue).\(item.imagePosition.rawValue).\(item.association?.rangeMeters.map { Int($0 * 2) } ?? -1)",
                    bearing: item.association?.bearingRadians, distance: item.association?.rangeMeters)
            }
            guard let target = snapshot.target, let id = attention.select(candidates, target: target, context: reviewContext,
                interval: live.preferences.descriptionInterval, at: clock.now()),
                let selected = resolver.currentCandidates.first(where: { $0.observation.id == id }) else { return }
            candidate = selected
            resolver.selectCandidate(id, context: context, at: clock.now()); refresh()
        }
        let text = FindPresentation.candidate(candidate, detail: detail)
        let envelope = candidate.observation.envelope
        // No recognized text is interpolated into output or a command.
        live.enqueueFind(FeedbackItem(context: context, createdAt: envelope.createdTimeMonotonic,
            expiresAt: envelope.expiresAtMonotonic, kind: .goal, priority: 1, text: text,
            repeatKey: explicit ? UUID().uuidString : "find.\(candidate.imagePosition.rawValue)", source: "currentCamera"))
    }
    func repeatCandidate() { announce(explicit: true) }
    func nextCandidate() { resolver.next(context: context, at: clock.now()); refresh(); announce(explicit: true) }
    func continueSearch() { resolver.continueSearch(context: context, at: clock.now()); timeoutAnnounced = false; refresh() }
    func complete() {
        resolver.complete(context: context, at: clock.now()); refresh()
        guard snapshot.phase == .completed else { return }
        live.stop(); message = "Search completed by you. No route or exit access was verified."; selectedTarget = nil
    }
}
