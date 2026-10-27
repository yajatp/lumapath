import Foundation
import Testing
import LumaPathDomain
import LumaPathPerception

private let railContext = CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay)
private func railFixture(sequence: UInt64, at time: Double, gap: Bool = false, plane: Bool = false) throws -> (SemanticObservation,DepthImage) {
    let frame = FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: railContext,sequence: sequence),mode: .demoReplay,
        capturedAt: time,createdAt: time,lifetime: 0.3),imageSize: PixelSize(width: 128,height: 32),depthSize: PixelSize(width: 128,height: 32),
        confidenceSize: PixelSize(width: 128,height: 32),intrinsics: CameraIntrinsics(fx: 100,fy: 100,cx: 64,cy: 16),
        cameraToWorld: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],orientation: .portrait,
        viewportSize: PixelSize(width: 128,height: 32),imageToDisplay: .identity,depthKind: .sceneDepth,tracking: .normal)
    let bounds = NormalizedBounds(minX: 0.1,minY: plane ? 0.1 : 0.49,maxX: 0.9,maxY: plane ? 0.9 : 0.54)
    let observation = SemanticObservation(envelope: frame.envelope,modelID: "synthetic.rail",modelVersion: "1",target: .handrail,
        labelScore: 0.9,imageBounds: bounds,visualContextConfirmed: true)
    var values = [Float](repeating: .nan,count: 128*32)
    for y in 0..<32 { for x in 0..<128 {
        if (plane || y == 16) && (!gap || x < 50 || x > 80) { values[y*128+x] = 2 }
    } }
    return (observation,try DepthImage(frame: frame,values: values,confidence: [UInt8](repeating: 2,count: values.count)))
}
@Test func handrailRequiresActualDepthLineAndTemporalSupportAndExpiresWithItsFrame() throws {
    var verifier = HandrailStructureVerifier()
    for i in 0..<3 {
        let time = 100+Double(i)*0.25
        let (observation,depth) = try railFixture(sequence: UInt64(i+1),at: time)
        let evidence = verifier.verify(observation,depth: depth,context: railContext,at: time)
        if i < 2 { #expect(evidence == nil) }
        else {
            let accepted = try #require(evidence)
            #expect(accepted.lengthMeters > 0.5)
            #expect(accepted.supports(observation,context: railContext,at: time))
            #expect(!accepted.supports(observation,context: railContext,at: time+0.3))
        }
    }
    let (lost,depth) = try railFixture(sequence: 4,at: 101)
    #expect(verifier.verify(lost,depth: depth,context: railContext,at: 101) == nil)
}
@Test func handrailRejectsDiscontinuityPlanarSurfacesAndRepeatedFrames() throws {
    for (gap,plane) in [(true,false),(false,true)] {
        var verifier = HandrailStructureVerifier()
        for i in 0..<4 {
            let time = 100+Double(i)*0.25
            let (observation,depth) = try railFixture(sequence: UInt64(i+1),at: time,gap: gap,plane: plane)
            let evidence = verifier.verify(observation,depth: depth,context: railContext,at: time)
            #expect(evidence == nil)
        }
    }
    var verifier = HandrailStructureVerifier()
    let (observation,depth) = try railFixture(sequence: 1,at: 100)
    for _ in 0..<4 {
        let evidence = verifier.verify(observation,depth: depth,context: railContext,at: 100)
        #expect(evidence == nil)
    }
}
