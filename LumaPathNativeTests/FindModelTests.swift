import XCTest
import LumaPathDomain
import LumaPathPerception
import LumaPathGoals
@testable import LumaPath

final class FindModelTests: XCTestCase {
    @MainActor func testEditingInputInvalidatesReviewBeforeConfirmation() {
        let model = FindModel()
        model.input = "minimal detail"
        model.submit(model.input)
        XCTAssertNotNil(model.proposal)
        model.input = "descriptive detail"
        XCTAssertNil(model.proposal)
        model.confirm()
        XCTAssertEqual(model.detail, .standard)
        model.submit(model.input)
        model.confirm()
        XCTAssertEqual(model.detail, .descriptive)
    }

    @MainActor func testCompletionSurvivesCaptureShutdownAndRejectsLateCandidates() throws {
        let model = FindModel(clock: FindCompletionClock())
        model.live.researchEnabled = true
        model.submit("find exit sign"); model.confirm()
        let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
        model.captureStarted(context)
        let revision = try XCTUnwrap(model.snapshot.revision)
        let frame = try GeometryFixture.load()[0].image(context: context, sequence: 1, at: 100).frame
        let manifest = DetectorManifest.systemOCR
        let observation = SemanticObservation(envelope: frame.envelope, modelID: manifest.id,
            modelVersion: manifest.version, target: .exitSign, labelScore: 0.95,
            imageBounds: NormalizedBounds(minX: 0.2, minY: 0.2, maxX: 0.6, maxY: 0.6),
            visualContextConfirmed: true)
        let batch = SemanticBatch(frame: frame, observations: [observation], inferenceDuration: 0.01,
            modelID: manifest.id, modelVersion: manifest.version)
        model.receive(batch, associations: [], revision: revision, context: context)
        XCTAssertEqual(model.snapshot.phase, .candidate)
        model.complete()
        XCTAssertEqual(model.snapshot.phase, .completed)
        XCTAssertNil(model.snapshot.candidate)
        XCTAssertFalse(model.live.active)
        XCTAssertTrue(model.message.contains("completed by you"))
        model.receive(batch, associations: [], revision: revision, context: context)
        model.tick()
        XCTAssertEqual(model.snapshot.phase, .completed)
        XCTAssertNil(model.snapshot.candidate)
        model.stop()
        XCTAssertEqual(model.snapshot.phase, .cancelled)
    }
    @MainActor func testCaptureFallbackRebindsGoalAndInvalidatesOldReview() {
        let model = FindModel()
        model.live.researchEnabled = true
        model.submit("find exit sign"); model.confirm()
        // Inject trusted producer callbacks without opening a simulator camera.
        let session = UUID()
        model.captureStarted(CaptureContext(sessionID: session, generation: 1, mode: .liveDepth))
        let oldRevision = model.snapshot.revision
        model.submit("minimal detail")
        XCTAssertNotNil(model.proposal)
        model.captureStarted(CaptureContext(sessionID: session, generation: 2, mode: .cameraOnly))
        XCTAssertEqual(model.snapshot.phase, .searching)
        XCTAssertEqual(model.reviewContext.capture.mode, .cameraOnly)
        XCTAssertEqual(model.reviewContext.capture.generation, 2)
        XCTAssertNotEqual(model.snapshot.revision, oldRevision)
        XCTAssertNil(model.proposal)
        model.confirm()
        XCTAssertEqual(model.detail, .standard)
        model.stop()
        model.captureStarted(CaptureContext(sessionID: session, generation: 3, mode: .cameraOnly))
        XCTAssertEqual(model.snapshot.phase, .cancelled)
    }
    @MainActor func testDeniedPermissionsNeverStartMicrophone() async throws {
        var microphoneRequests = 0
        let deniedSpeech = PushToTalkModel(authorize: { false }, microphone: { microphoneRequests += 1; return true })
        deniedSpeech.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(deniedSpeech.listening)
        XCTAssertEqual(microphoneRequests, 0)
        XCTAssertTrue(deniedSpeech.status.contains("Type a command"))
        let deniedMicrophone = PushToTalkModel(authorize: { true }, microphone: { false })
        deniedMicrophone.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(deniedMicrophone.listening)
        XCTAssertTrue(deniedMicrophone.status.contains("Microphone permission was denied"))
    }
    @MainActor func testCancellationBeforePermissionResultPreventsLaterRecording() async throws {
        var finish: CheckedContinuation<Bool, Never>?
        var microphoneRequests = 0
        let speech = PushToTalkModel(authorize: { await withCheckedContinuation { finish = $0 } },
            microphone: { microphoneRequests += 1; return true })
        speech.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(finish)
        speech.cancel()
        finish?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(speech.listening)
        XCTAssertFalse(speech.requesting)
        XCTAssertEqual(microphoneRequests, 0)
    }
    @MainActor func testTypedReviewRequiresConfirmationAndUnavailableTargetDoesNotStartCapture() {
        let model = FindModel()
        model.submit("find door")
        XCTAssertNotNil(model.proposal)
        XCTAssertFalse(model.live.active)
        model.confirm()
        XCTAssertNil(model.proposal)
        XCTAssertEqual(model.snapshot.phase, .unavailable)
        XCTAssertTrue(model.message.contains("detector is not installed"))
        XCTAssertFalse(model.live.active)
        model.captureStarted(CaptureContext(sessionID: UUID(), generation: 2, mode: .cameraOnly))
        XCTAssertEqual(model.snapshot.phase, .unavailable)
        XCTAssertTrue(model.message.contains("detector is not installed"))
        model.submit("find exit sign and send message")
        XCTAssertNil(model.proposal)
        XCTAssertTrue(model.message.contains("Nothing was sent"))
        model.confirm()
        XCTAssertEqual(model.snapshot.target, .door)
    }
    @MainActor func testOrdinaryExitIsUnavailableAndPauseInvalidatesPendingReview() {
        let model = FindModel()
        model.submit("find exit sign"); model.confirm()
        XCTAssertEqual(model.snapshot.phase, .unavailable)
        XCTAssertTrue(model.message.contains("Research only"))
        model.submit("descriptive detail")
        model.pause(); model.confirm()
        XCTAssertEqual(model.detail, .standard)
        model.submit("minimal detail"); model.confirm()
        XCTAssertEqual(model.detail, .minimal)
        model.stop()
        XCTAssertNil(model.proposal)
        XCTAssertNil(model.snapshot.candidate)
        XCTAssertFalse(model.speech.listening)
    }
    @MainActor func testSceneDataCannotReplaceUserReviewOrProduceOutput() {
        let model = FindModel()
        model.submit("minimal detail")
        let id = model.proposal?.id
        model.submit("find exit sign", source: .sceneText)
        XCTAssertEqual(model.proposal?.id, id)
        model.confirm()
        XCTAssertEqual(model.detail, .minimal)
        XCTAssertFalse(model.live.active)
    }
}

private struct FindCompletionClock: MonotonicClock { func now() -> TimeInterval { 100 } }
