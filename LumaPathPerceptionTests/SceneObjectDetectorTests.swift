import Foundation
import Testing
import LumaPathDomain
import LumaPathModels

private struct SceneFixtureClock: MonotonicClock {
    let time: Double
    func now() -> Double { time }
}
@Test(arguments: SceneDetectorPreset.allCases) func bundledSceneModelLoadsAndReturnsOnlyCurrentWhitelistedBoxes(preset: SceneDetectorPreset) async throws {
    let frame = try ReplayFixtures.frames()[0]
    let context = CaptureContext(sessionID: frame.envelope.frameID.sessionID, generation: frame.envelope.frameID.generation, mode: frame.envelope.sourceMode)
    let detector = SceneObjectDetector(preset: preset, clock: SceneFixtureClock(time: frame.envelope.captureTimeMonotonic))
    try await detector.prepare()
    let data = try Data(contentsOf: ReplayFixtures.url("synthetic-scene.png"))
    let image = try EncodedSemanticImage(frame: frame, data: data, quarterTurn: .up)
    let batch = try await detector.detect(image, context: context)
    #expect(batch.frame == frame)
    #expect(batch.modelID == preset.modelID)
    #expect(SceneObjectDetector.classes.count == 80)
    #expect(batch.observations.allSatisfy { $0.envelope == frame.envelope && SceneObjectDetector.classes.contains($0.text ?? "") && $0.imageBounds.clipped == $0.imageBounds && $0.target == nil })
}
