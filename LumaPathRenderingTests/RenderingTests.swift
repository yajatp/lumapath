import Foundation
import Testing
@testable import LumaPathDomain
@testable import LumaPathRendering

private struct AspectFixtures: Decodable {
    struct Example: Decodable { let name: String; let frame: FrameDescriptor; let imageLandmark: [Double]; let displayLandmark: [Double] }
    let cases: [Example]
}

@Test func producerAspectFillLandmarksUseExactlyOneTransform() throws {
    let examples = try JSONDecoder().decode(AspectFixtures.self, from: Data(contentsOf: ReplayFixtures.url("aspect-fill-examples.json")))
    #expect(examples.cases.count >= 4)
    for example in examples.cases {
        let p = example.frame.imageToDisplay.apply(x: example.imageLandmark[0], y: example.imageLandmark[1])
        #expect(abs(p.x - example.displayLandmark[0]) < 1e-9)
        #expect(abs(p.y - example.displayLandmark[1]) < 1e-9)
        let f = example.frame
        let context = CaptureContext(sessionID: f.envelope.frameID.sessionID, generation: f.envelope.frameID.generation, mode: f.envelope.sourceMode)
        #expect(RenderBoundary.accepts(f, context: context, orientation: f.orientation, viewport: f.viewportSize, at: 0.1))
        #expect(!RenderBoundary.accepts(f, context: context, orientation: f.orientation, viewport: f.viewportSize, at: 0.3))
        #expect(!RenderBoundary.accepts(f, context: context, orientation: f.orientation, viewport: PixelSize(width: 7, height: 9), at: 0.1))
        let newer = CaptureContext(sessionID: context.sessionID, generation: context.generation + 1, mode: context.mode)
        #expect(!RenderBoundary.accepts(f, context: newer, orientation: f.orientation, viewport: f.viewportSize, at: 0.1))
    }
}

@Test func overlayProjectionRotatesClipsAndRejectsInvalidGeometry() throws {
    let bounds = NormalizedBounds(minX: 0.1, minY: 0.2, maxX: 0.3, maxY: 0.4)
    let rotation = DisplayTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
    let projected = try #require(RenderBoundary.project(bounds, through: rotation))
    #expect(abs(projected.minX - 0.6) < 1e-9)
    #expect(abs(projected.maxX - 0.8) < 1e-9)
    #expect(abs(projected.minY - 0.1) < 1e-9)
    #expect(abs(projected.maxY - 0.3) < 1e-9)
    #expect(RenderBoundary.project(NormalizedBounds(minX: -0.2, minY: 0, maxX: 0.4, maxY: 1.3), through: .identity)
            == NormalizedBounds(minX: 0, minY: 0, maxX: 0.4, maxY: 1))
    #expect(RenderBoundary.project(NormalizedBounds(minX: 2, minY: 0, maxX: 3, maxY: 1), through: .identity) == nil)
    #expect(RenderBoundary.project(NormalizedBounds(minX: .nan, minY: 0, maxX: 1, maxY: 1), through: .identity) == nil)
}

@Test func settingsAndOutputAllocationAreBounded() {
    var settings = EnhancementSettings()
    #expect(settings.isValid)
    settings.edges = .nan
    #expect(!settings.isValid)
    settings.edges = 0; settings.exposure = 3
    #expect(!settings.isValid)
    let size = RenderBoundary.outputSize(for: PixelSize(width: 4000, height: 3000))
    #expect(size == PixelSize(width: 1280, height: 960))
    #expect(RenderBoundary.outputSize(for: PixelSize(width: 0, height: 20)) == nil)
    #expect(RenderBoundary.outputSize(for: PixelSize(width: Int.max, height: Int.max)) == PixelSize(width: 1280, height: 1280))
}

private struct RenderClock: MonotonicClock { func now() -> TimeInterval { 10 } }
@Test func currentGeometryProjectsOriginalBoundsAndIgnoresAlreadyProjectedBounds() throws {
    let frame = try ReplayFixtures.frames()[0]
    let context = CaptureContext(sessionID: frame.envelope.frameID.sessionID, generation: frame.envelope.frameID.generation, mode: frame.envelope.sourceMode)
    let imageBounds = NormalizedBounds(minX: 0.2, minY: 0.3, maxX: 0.4, maxY: 0.5)
    let details = GeometryDetails(imageBounds: imageBounds, displayBounds: NormalizedBounds(minX: 0, minY: 0, maxX: 1, maxY: 1),
        corridor: .ahead, bearingRadians: nil, supportCount: 10, groundRelation: .unclassified,
        heightAboveGroundMeters: nil, evidence: .confidenceUnknown)
    let observation = GeometryObservation(id: UUID(), envelope: frame.envelope, opticalPoint: OpticalPoint(x: 0, y: 0, z: 2),
        axialDepthMeters: 2, rangeMeters: 2, details: details)
    let snapshot = SessionSnapshot(context: context, lifecycle: .running, quality: QualityAssessment(state: .limited, reasons: []),
        frame: frame, geometry: [observation], events: [])
    let request = try #require(RendererRequest(snapshot: snapshot, displayedFrame: frame, orientation: frame.orientation, viewport: frame.viewportSize, at: 0.1))
    let expected = try #require(RenderBoundary.project(imageBounds, through: frame.imageToDisplay))
    #expect(RenderBoundary.overlays(request, displayedFrame: frame, context: context, orientation: frame.orientation, viewport: frame.viewportSize, at: 0.1) == [expected])
}

@MainActor @Test func overlayRequestsCannotCrossDisplayFrameContextOrDeadline() throws {
    let replay = try ReplayShellService(clock: RenderClock())
    replay.perform(.startDemo)
    let snapshot = replay.snapshot
    let frame = try #require(snapshot.frame)
    let request = try #require(RendererRequest(snapshot: snapshot, displayedFrame: frame, orientation: frame.orientation, viewport: frame.viewportSize, at: 10))
    #expect(RenderBoundary.overlays(request, displayedFrame: frame, context: snapshot.context,
                                    orientation: frame.orientation, viewport: frame.viewportSize, at: 10.3).isEmpty)
    #expect(RenderBoundary.overlays(request, displayedFrame: frame, context: snapshot.context,
                                    orientation: .portraitUpsideDown, viewport: frame.viewportSize, at: 10).isEmpty)
    replay.perform(.nextFixture)
    let next = try #require(replay.snapshot.frame)
    #expect(RenderBoundary.overlays(request, displayedFrame: next, context: replay.snapshot.context,
                                    orientation: next.orientation, viewport: next.viewportSize, at: 10).isEmpty)
}
