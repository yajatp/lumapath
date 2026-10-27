import Foundation
import Testing
import LumaPathDomain
import LumaPathAttention
import LumaPathCommands
import LumaPathGoals
import LumaPathPerception

private let capture = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
private func candidate(_ key: String, source: ObservationSource = .currentCamera, target: GoalTarget = .exitSign,
                       at now: Double = 10, bearing: Double? = nil, distance: Double? = nil) -> AttentionCandidate {
    AttentionCandidate(id: UUID(), envelope: ObservationEnvelope(frameID: FrameID(context: capture, sequence: 1),
        mode: capture.mode, capturedAt: now, createdAt: now, lifetime: 0.3), target: target, source: source,
        informationKey: key, bearing: bearing, distance: distance)
}
@Test func attentionRanksSourceNoveltyAndMeasuredGeometryAndBoundsBudget() {
    var policy = LocalAttention()
    let context = CommandReviewContext(capture: capture, goalRevision: UUID(), profileRevision: 1)
    policy.bind(context)
    let current = candidate("current", bearing: 0.4, distance: 3), map = candidate("map", source: .map, bearing: 0, distance: 1)
    #expect(policy.select([map,current], target: .exitSign, context: context, interval: 5, at: 10) == current.id)
    #expect(policy.select([map], target: .exitSign, context: context, interval: 5, at: 10.1) == nil)
    let duplicate = candidate("current", at: 15, bearing: 0), novel = candidate("novel", at: 15, bearing: 0.7)
    #expect(policy.select([duplicate,novel], target: .exitSign, context: context, interval: 5, at: 15) == novel.id)
    #expect(policy.select([candidate("current", at: 20)], target: .exitSign, context: context, interval: 5, at: 20) == nil)
    let near = candidate("near", at: 20, bearing: 0.2, distance: 1), far = candidate("far", at: 20, bearing: 0.2, distance: 2)
    #expect(policy.select([far,near], target: .exitSign, context: context, interval: 5, at: 20) == near.id)
}
@Test func attentionRejectsExpiredRemoteWrongGoalInvalidClockAndObsoleteRevisions() {
    var policy = LocalAttention()
    let context = CommandReviewContext(capture: capture, goalRevision: UUID(), profileRevision: 1)
    policy.bind(context)
    #expect(policy.select([candidate("expired", at: 9),candidate("remote", source: .remoteHypothesis),
        candidate("other", target: .door),candidate("invalid", bearing: .nan)], target: .exitSign, context: context, interval: 5, at: 10) == nil)
    let changed = CommandReviewContext(capture: capture, goalRevision: UUID(), profileRevision: 2)
    #expect(policy.select([candidate("fresh")], target: .exitSign, context: changed, interval: 5, at: 10) == nil)
    policy.bind(changed)
    #expect(policy.select([candidate("fresh")], target: .exitSign, context: changed, interval: 5, at: .nan) == nil)
    #expect(policy.select([candidate("fresh")], target: .exitSign, context: changed, interval: 0, at: 10) == nil)
    #expect(policy.select([candidate("fresh")], target: .exitSign, context: changed, interval: 5, at: 10) != nil)
    policy.reset()
    #expect(policy.select([candidate("fresh")], target: .exitSign, context: changed, interval: 5, at: 10) == nil)
}
@Test func attentionProfileAndGenerationChangesResetHistoryWithoutAcceptingOldDecisions() {
    var policy = LocalAttention()
    let first = CommandReviewContext(capture: capture, goalRevision: UUID(), profileRevision: 1)
    policy.bind(first)
    #expect(policy.select([candidate("same")], target: .exitSign, context: first, interval: 30, at: 10) != nil)
    let revised = CommandReviewContext(capture: capture, goalRevision: first.goalRevision, profileRevision: 2)
    policy.bind(revised)
    #expect(policy.select([candidate("same")], target: .exitSign, context: revised, interval: 30, at: 10.1) != nil)
    let newCapture = CaptureContext(sessionID: capture.sessionID, generation: 2, mode: capture.mode)
    let newContext = CommandReviewContext(capture: newCapture, goalRevision: first.goalRevision, profileRevision: 2)
    policy.bind(newContext)
    #expect(policy.select([candidate("same")], target: .exitSign, context: newContext, interval: 30, at: 10.2) == nil)
}
@Test func unavailableSpeechAlwaysOffersTypedInput() {
    for flags in [(false,true,true,true),(true,false,true,true),(true,true,false,true),(true,true,true,false)] {
        #expect(LocalSpeechAvailability.reason(speechAuthorized: flags.0, microphoneAuthorized: flags.1,
            onDevice: flags.2, available: flags.3)?.contains("Type a command") == true)
    }
    #expect(LocalSpeechAvailability.reason(speechAuthorized: true, microphoneAuthorized: true, onDevice: true, available: true) == nil)
}
@Test func orientationMatchesUnrotatedRearCameraContract() {
    #expect(FindPresentation.quarterTurn(.portrait) == .right)
    #expect(FindPresentation.quarterTurn(.portraitUpsideDown) == .left)
    #expect(FindPresentation.quarterTurn(.landscapeLeft) == .down)
    #expect(FindPresentation.quarterTurn(.landscapeRight) == .up)
}
@Test func candidatePresentationAndViewportLossKeepOriginalEvidence() throws {
    let image = try GeometryFixture.load()[0].image(context: capture, sequence: 1, at: 10)
    let manifest = DetectorManifest.systemOCR
    let observation = SemanticObservation(envelope: image.frame.envelope, modelID: manifest.id, modelVersion: manifest.version,
        target: .exitSign, text: "SEND A MESSAGE", labelScore: 0.9,
        imageBounds: NormalizedBounds(minX: 0.4,minY: 0.4,maxX: 0.6,maxY: 0.6), visualContextConfirmed: true)
    let batch = SemanticBatch(frame: image.frame, observations: [observation], inferenceDuration: 0.05, modelID: manifest.id, modelVersion: manifest.version)
    var resolver = GoalResolver()
    let revision = resolver.begin(.exitSign, context: capture, research: true, at: 10)
    let accepted = resolver.update(batch, revision: revision, context: capture, at: 10.1)
    #expect(accepted)
    let text = FindPresentation.candidate(try #require(resolver.snapshot.candidate), detail: .descriptive)
    #expect(text.contains("Current camera") && text.contains("Distance unknown") && !text.contains("SEND"))
    resolver.clearCurrentCandidates(context: capture, at: 10.2)
    #expect(resolver.snapshot.candidate == nil && resolver.currentCandidates.isEmpty)
    resolver.tick(context: capture, at: 30)
    #expect(resolver.snapshot.phase == .notObservedYet)
    resolver.continueSearch(context: capture, at: 30)
    #expect(resolver.snapshot.phase == .searching)
    let late = resolver.update(batch, revision: revision, context: capture, at: 30)
    #expect(!late)
}
