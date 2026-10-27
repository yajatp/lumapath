import Foundation
import LumaPathDomain

/// Requires an actual semantic handrail detector plus elongated contiguous depth structure.
/// This rejects unsupported boxes; it does not establish rail reachability, strength, or safe use.
public struct HandrailStructureVerifier: Sendable {
    private var context: CaptureContext?
    private var modelID: String?
    private var modelVersion: String?
    private var firstTime: Double?
    private var lastTime: Double?
    private var sequence: UInt64?
    private var endpoints: (SIMD3<Double>,SIMD3<Double>)?
    private var frames = 0
    public init() {}
    public mutating func verify(_ observation: SemanticObservation, depth: DepthImage, context current: CaptureContext,
                                at now: Double) -> HandrailStructureEvidence? {
        guard observation.target == .handrail, observation.source == .currentCamera,
              observation.visualContextConfirmed, observation.labelScore.isFinite, (0.6...1).contains(observation.labelScore),
              depth.frame.envelope == observation.envelope, observation.envelope.isCurrent(in: current,at: now),
              depth.frame.tracking == .normal, let m = depth.frame.cameraToWorld, let size = depth.frame.depthSize, let confidence = depth.confidence,
              observation.imageBounds.clipped == observation.imageBounds else { reset(); return nil }
        if context != current || modelID != observation.modelID || modelVersion != observation.modelVersion {
            reset(); context = current; modelID = observation.modelID; modelVersion = observation.modelVersion
        }
        let time = depth.frame.envelope.captureTimeMonotonic
        guard sequence.map({ observation.envelope.frameID.sequence > $0 }) ?? true else { return nil }
        sequence = observation.envelope.frameID.sequence
        if let lastTime, time-lastTime > 0.3 || time <= lastTime { reset(); return nil }
        let bounds = observation.imageBounds
        var points: [SIMD3<Double>] = [], visited = Set<Int>()
        for y in 0..<12 { for x in 0..<32 {
            let u = min(size.width-1,Int((bounds.minX+(bounds.maxX-bounds.minX)*(Double(x)+0.5)/32)*Double(size.width)))
            let v = min(size.height-1,Int((bounds.minY+(bounds.maxY-bounds.minY)*(Double(y)+0.5)/12)*Double(size.height)))
            let index = v*size.width+u, z = Double(depth.values[index])
            guard visited.insert(index).inserted, confidence[index] == 2, (0.3...4).contains(z),
                  let optical = FrameGeometry.unproject(u: Double(u),v: Double(v),axialDepth: z,frame: depth.frame) else { continue }
            let p = optical.arKitCameraPoint
            points.append(SIMD3(m[0]*p.x+m[4]*p.y+m[8]*p.z+m[12],m[1]*p.x+m[5]*p.y+m[9]*p.z+m[13],m[2]*p.x+m[6]*p.y+m[10]*p.z+m[14]))
        } }
        guard points.count >= 12 else { reset(); return nil }
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
        func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = a-b; return dot(d,d).squareRoot() }
        // Two farthest-point passes produce a bounded line hypothesis; all points must support it.
        let a = points.max { distance($0,points[0]) < distance($1,points[0]) }!
        let b = points.max { distance($0,a) < distance($1,a) }!
        let length = distance(a,b)
        guard length >= 0.5 else { reset(); return nil }
        let axis = (b-a)/length
        let projected = points.map { dot($0-a,axis) }.sorted()
        let residual = points.map { p in distance(p,a+axis*dot(p-a,axis)) }.max()!
        guard residual <= 0.04, zip(projected,projected.dropFirst()).allSatisfy({ $1-$0 <= 0.2 }) else { reset(); return nil }
        if let (previousA,previousB) = endpoints {
            let displacement = min(max(distance(a,previousA),distance(b,previousB)),max(distance(a,previousB),distance(b,previousA)))
            guard displacement <= 0.15 else { reset(); return nil }
        }
        if firstTime == nil { firstTime = time }
        lastTime = time; endpoints = (a,b); frames = min(frames+1,3)
        guard frames >= 3, time-firstTime! >= 0.5 else { return nil }
        return HandrailStructureEvidence(observationID: observation.id,envelope: observation.envelope,lengthMeters: length,
            maximumResidualMeters: residual,supportedFrames: frames,duration: time-firstTime!)
    }
    public mutating func reset() { context = nil; modelID = nil; modelVersion = nil; firstTime = nil; lastTime = nil; sequence = nil; endpoints = nil; frames = 0 }
}
