import Foundation
import LumaPathDomain

public enum DepthAssociator {
    public static func associate(_ observation: SemanticObservation, depth: DepthImage?, context: CaptureContext, at now: Double) -> DepthAssociation {
        func unknown(_ reason: String) -> DepthAssociation {
            DepthAssociation(observationID: observation.id,frameID: observation.envelope.frameID,rangeMeters: nil,
                axialDepthMeters: nil,bearingRadians: nil,associationSupport: nil,uncertaintyMeters: nil,reasons: [reason])
        }
        guard observation.source == .currentCamera, observation.envelope.isCurrent(in: context,at: now),
              observation.labelScore.isFinite, (0...1).contains(observation.labelScore) else { return unknown("noncurrentSemanticEvidence") }
        guard let depth, depth.frame.envelope == observation.envelope, let size = depth.frame.depthSize else { return unknown("depthUnavailableOrDifferentFrame") }
        guard depth.confidence != nil, let bounds = observation.imageBounds.clipped,
              bounds == observation.imageBounds else { return unknown("associationCalibrationOrConfidenceUnknown") }
        let x0 = bounds.minX+(bounds.maxX-bounds.minX)*0.2, x1 = bounds.maxX-(bounds.maxX-bounds.minX)*0.2
        let y0 = bounds.minY+(bounds.maxY-bounds.minY)*0.2, y1 = bounds.maxY-(bounds.maxY-bounds.minY)*0.2
        var samples: [(z: Double,u: Int,v: Int)] = [], visited = Set<Int>()
        for y in 0..<16 { for x in 0..<16 {
            let u = min(size.width-1,max(0,Int((x0+(x1-x0)*(Double(x)+0.5)/16)*Double(size.width))))
            let v = min(size.height-1,max(0,Int((y0+(y1-y0)*(Double(y)+0.5)/16)*Double(size.height))))
            let index = v*size.width+u, z = Double(depth.values[index])
            guard visited.insert(index).inserted, depth.confidence![index] >= 1, depth.confidence![index] <= 2,
                  z.isFinite, z >= 0.3, z <= 4 else { continue }
            samples.append((z,u,v))
        } }
        guard samples.count >= 8 else { return unknown("insufficientInteriorDepth") }
        samples.sort { $0.z < $1.z }
        var clusters: [[(z: Double,u: Int,v: Int)]] = []
        for sample in samples {
            if let first = clusters.last?.first, sample.z-first.z <= 0.15 { clusters[clusters.count-1].append(sample) }
            else { clusters.append([sample]) }
        }
        let plausible = clusters.filter { $0.count >= max(5,Int(ceil(Double(samples.count)*0.2))) }
        guard plausible.count == 1, let cluster = plausible.first, cluster.count >= 8,
              Double(cluster.count)/Double(visited.count) >= 0.5 else { return unknown("ambiguousOrSparseInteriorSurfaces") }
        let middle = cluster[cluster.count/2]
        let u = cluster.map(\.u).sorted()[cluster.count/2], v = cluster.map(\.v).sorted()[cluster.count/2]
        guard let point = FrameGeometry.unproject(u: Double(u),v: Double(v),axialDepth: middle.z,frame: depth.frame),
              point.range <= 4 else { return unknown("associationOutsideRange") }
        return DepthAssociation(observationID: observation.id,frameID: observation.envelope.frameID,rangeMeters: point.range,
            axialDepthMeters: middle.z,bearingRadians: atan2(point.x,point.z),associationSupport: Double(cluster.count)/Double(visited.count),
            uncertaintyMeters: max(0.03,(cluster.last!.z-cluster.first!.z)/2),reasons: ["singleSupportedInteriorDepthCluster"])
    }
}
