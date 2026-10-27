import Foundation
import LumaPathDomain

private struct SurfacePoint {
    let x: Double, forward: Double, height: Double
    let key: VoxelKey
}
/// Conservative candidate geometry only; every family remains Research-only until separate physical gates pass.
public struct AdvancedDetector: Sendable {
    private let configuration: AdvancedConfiguration
    private var previous: (context: CaptureContext, time: Double, signatures: [String: Int], pose: [Double])?
    public init(configuration: AdvancedConfiguration = .current) { self.configuration = configuration }
    public mutating func detect(_ model: OccupancySnapshot, ground: GroundEstimate, context: CaptureContext,
                                profile: MobilityGeometryProfile = .standard, at now: Double) throws -> [AdvancedHazardCandidate] {
        let frame = model.frame, cfg = configuration
        guard frame.envelope.isCurrent(in: context,at: now) else { throw ContractError.invalidValue("staleAdvancedGeometry") }
        guard let pose = PoseBasis(frame: frame), ground.status == .confirmed, let floorHeight = ground.worldHeightMeters,
              floorHeight.isFinite, !model.truncated, model.voxelSize == cfg.voxelSize else {
            previous = nil; return []
        }
        let origin = SIMD3(pose.matrix[12],pose.matrix[13],pose.matrix[14])
        let points: [SurfacePoint] = model.cells.values.compactMap { cell in
            // Historical occupancy never refreshes a candidate's measurement deadline.
            guard cell.evidence == .occupied, cell.support >= cfg.minimumSurfaceSupport,
                  cell.lastObservedAt == frame.envelope.captureTimeMonotonic else { return nil }
            let world = SIMD3((Double(cell.key.x)+0.5)*model.voxelSize,
                (Double(cell.key.y)+0.5)*model.voxelSize,(Double(cell.key.z)+0.5)*model.voxelSize)
            let delta = world-origin, forward = dot(delta,pose.forward), x = dot(delta,pose.right)
            guard forward >= 0.3, forward <= 4 else { return nil }
            return SurfacePoint(x: x,forward: forward,height: world.y-floorHeight,key: cell.key)
        }
        var proposals: [(signature: String, candidate: AdvancedHazardCandidate)] = []
        func candidate(_ family: AdvancedHazardFamily, x: Double, z: Double, width: Double? = nil,
                       height: Double? = nil, reason: String) -> AdvancedHazardCandidate {
            AdvancedHazardCandidate(envelope: frame.envelope,family: family,rangeMeters: hypot(x,z),bearingRadians: atan2(x,z),
                measuredWidth: width,heightChange: height,uncertaintyMeters: model.voxelSize*sqrt(3),reasons: [reason,"researchOnly"])
        }
        if let overhead = points.filter({ abs($0.x) <= profile.requiredWidth/2+0.1
            && $0.height >= max(1.2,profile.clearanceHeight-0.4) && $0.height <= profile.clearanceHeight+0.1 }).min(by: { $0.forward < $1.forward }) {
            proposals.append(("overhead",candidate(.overhead,x: overhead.x,z: overhead.forward,reason: "supportedClearanceBand")))
        }
        // Ground patches must span the corridor, rather than treating an isolated table point as terrain.
        var patchBins: [Int: [SurfacePoint]] = [:]
        for point in points where abs(point.x) <= profile.requiredWidth/2 && abs(point.height) <= 0.65 {
            patchBins[Int(floor(point.forward/0.2)),default: []].append(point)
        }
        var patches: [(bin: Int, height: Double, lateral: Set<Int>)] = []
        for (bin,points) in patchBins {
            let lateral = Set(points.map { Int(floor($0.x/0.2)) })
            let ys = points.map(\.height).sorted()
            guard lateral.count >= 3, lateral.max()!-lateral.min()!+1 == lateral.count,
                  let lo = ys.first, let hi = ys.last, hi-lo <= 0.06 else { continue }
            patches.append((bin,ys[ys.count/2],lateral))
        }
        patches.sort { $0.bin < $1.bin }
        var transitions: [(bin: Int, delta: Double)] = []
        for pair in zip(patches,patches.dropFirst()) where pair.1.bin-pair.0.bin == 1
            && pair.0.lateral.intersection(pair.1.lateral).count >= 3 {
            let change = pair.1.height-pair.0.height
            if abs(change) >= cfg.minimumStepHeight && abs(change) <= cfg.maximumStepHeight {
                transitions.append((pair.1.bin,change))
                let family: AdvancedHazardFamily = change > 0 ? .stepUp : .stepDown
                proposals.append(("\(family.rawValue).\(pair.1.bin)",candidate(family,x: 0,z: Double(pair.1.bin)*0.2,height: change,
                    reason: "adjacentMeasuredGroundSurfaces")))
            }
        }
        if transitions.count >= 3 {
            for start in 0...transitions.count-3 {
                let group = Array(transitions[start..<start+3])
                let reference = group[0].delta
                if group.allSatisfy({ $0.delta*reference > 0 && abs($0.delta-reference) < 0.04 })
                    && group[2].bin-group[0].bin <= 5 {
                    proposals.append(("stairs.\(group[0].bin)",candidate(.stairs,x: 0,z: Double(group[0].bin)*0.2,
                        height: reference,reason: "threeConsistentMeasuredRisers")))
                }
            }
        }
        // Two body-height boundaries need measured free cells between them at multiple heights.
        let walls = Dictionary(grouping: points.filter { $0.height >= 0.3 && $0.height <= profile.clearanceHeight },by: { Int(floor($0.forward/0.2)) })
        for (bin,wall) in walls {
            guard let left = wall.filter({ $0.x < -0.15 }).max(by: { $0.x < $1.x }),
                  let right = wall.filter({ $0.x > 0.15 }).min(by: { $0.x < $1.x }) else { continue }
            let width = right.x-left.x-model.voxelSize
            guard width > 0.2, width < profile.requiredWidth+0.4 else { continue }
            let z = (Double(bin)+0.5)*0.2
            var supported = true
            for x in stride(from: left.x+model.voxelSize,to: right.x-model.voxelSize/2,by: model.voxelSize) {
                for height in [0.5,1.0,min(1.5,profile.clearanceHeight-0.1)] {
                    let world = origin+pose.right*x+pose.forward*z
                    let key = VoxelKey(x: Int(floor(world.x/model.voxelSize)),y: Int(floor((floorHeight+height)/model.voxelSize)),z: Int(floor(world.z/model.voxelSize)))
                    guard let cell = model.cells[key], cell.evidence == .observedFree,
                          cell.lastObservedAt == frame.envelope.captureTimeMonotonic else { supported = false; continue }
                }
            }
            if supported { proposals.append(("passage.\(bin)",candidate(.narrowPassage,x: (left.x+right.x)/2,z: z,width: width,
                reason: "twoBoundariesAndSampledInterveningVolumeNotClearance"))) }
        }
        var counts: [String: Int] = [:]
        let consecutive = previous.map { prior in
            let m = pose.matrix, p = prior.pose
            let displacement = length(SIMD3(m[12]-p[12],m[13]-p[13],m[14]-p[14]))
            let turn = acos(max(-1,min(1,m[8]*p[8]+m[9]*p[9]+m[10]*p[10])))
            return prior.context == context && frame.envelope.captureTimeMonotonic > prior.time
                && frame.envelope.captureTimeMonotonic-prior.time < CaptureConfiguration.current.maximumFrameAge
                && displacement <= 0.05 && turn <= 0.08
        } ?? false
        let result = proposals.compactMap { proposal -> AdvancedHazardCandidate? in
            let count = consecutive ? min(cfg.confirmationFrames,(previous?.signatures[proposal.signature] ?? 0)+1) : 1
            counts[proposal.signature] = count
            return count >= cfg.confirmationFrames ? proposal.candidate : nil
        }
        previous = (context,frame.envelope.captureTimeMonotonic,counts,pose.matrix)
        return Array(result.sorted { $0.rangeMeters < $1.rangeMeters }.prefix(32))
    }
}
