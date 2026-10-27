import Foundation
import LumaPathDomain

/// Sparse world voxels. Free evidence applies only to sampled ray cells, never unobserved volume.
public struct RollingOccupancy: Sendable {
    private var cells: [VoxelKey: VoxelObservation] = [:]
    private var context: CaptureContext?
    private var previousFrame: FrameDescriptor?
    private let configuration: AdvancedConfiguration
    public init(configuration: AdvancedConfiguration = .current) { self.configuration = configuration }
    public mutating func reset() { cells.removeAll(keepingCapacity: true); context = nil; previousFrame = nil }

    public mutating func integrate(_ depth: DepthImage, context expected: CaptureContext, at now: Double) throws -> OccupancySnapshot {
        let frame = depth.frame, cfg = configuration
        guard frame.envelope.isCurrent(in: expected,at: now) else { throw ContractError.invalidValue("staleOccupancyInput") }
        guard let pose = PoseBasis(frame: frame), depth.confidence != nil else {
            reset(); return OccupancySnapshot(frame: frame,voxelSize: cfg.voxelSize,cells: [:],truncated: false)
        }
        if context != expected || previousFrame.map({
            frame.envelope.captureTimeMonotonic-$0.envelope.captureTimeMonotonic > cfg.memoryLifetime
        }) == true { reset(); context = expected }
        if let previousFrame {
            guard frame.envelope.frameID.sequence > previousFrame.envelope.frameID.sequence,
                  frame.envelope.captureTimeMonotonic > previousFrame.envelope.captureTimeMonotonic else {
                throw ContractError.invalidValue("outOfOrderOccupancy")
            }
            // Abrupt pose changes may be tracking resets. Drop history before making temporal claims.
            let m = previousFrame.cameraToWorld!, p = pose.matrix
            let translation = SIMD3(p[12]-m[12],p[13]-m[13],p[14]-m[14])
            let turn = acos(max(-1,min(1,m[8]*p[8]+m[9]*p[9]+m[10]*p[10])))
            if length(translation) > 0.5 || turn > cfg.maximumTurnRadians { cells.removeAll(keepingCapacity: true) }
        }
        cells = cells.filter { now-$0.value.lastObservedAt < cfg.memoryLifetime }
        let size = frame.depthSize!, step = max(1,Int(ceil(sqrt(Double(depth.values.count)/Double(cfg.maximumRays)))))
        let origin = SIMD3(pose.matrix[12],pose.matrix[13],pose.matrix[14])
        guard [origin.x,origin.y,origin.z].allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else {
            reset(); return OccupancySnapshot(frame: frame,voxelSize: cfg.voxelSize,cells: [:],truncated: false)
        }
        var free = [VoxelKey: Int](), occupied = [VoxelKey: Int]()
        var sampledRayCount = 0
        func key(_ point: SIMD3<Double>) -> VoxelKey {
            VoxelKey(x: Int(floor(point.x/cfg.voxelSize)),y: Int(floor(point.y/cfg.voxelSize)),z: Int(floor(point.z/cfg.voxelSize)))
        }
        for y in stride(from: 0,to: size.height,by: step) {
            try Task.checkCancellation()
            if sampledRayCount >= cfg.maximumRays { break }
            for x in stride(from: 0,to: size.width,by: step) {
                guard sampledRayCount < cfg.maximumRays else { break }; sampledRayCount += 1
                let index = y*size.width+x, z = Double(depth.values[index])
                guard depth.confidence![index] == 2,
                      z >= GeometryConfiguration.current.minimumDepth, z <= GeometryConfiguration.current.maximumDepth,
                      let optical = FrameGeometry.unproject(u: Double(x),v: Double(y),axialDepth: z,frame: frame),
                      optical.range <= GeometryConfiguration.current.maximumDepth else { continue }
                let endpoint = pose.world(optical), delta = endpoint-origin, range = length(delta)
                occupied[key(endpoint),default: 0] += 1
                // Sample every half voxel; stop short of the occupied endpoint by one full voxel.
                let intervals = Int(range/(cfg.voxelSize/2))
                var rayCells = Set<VoxelKey>()
                for i in 1..<max(1,intervals-2) {
                    rayCells.insert(key(origin+delta*(Double(i)/Double(intervals))))
                }
                for key in rayCells { free[key,default: 0] += 1 }
            }
        }
        let captured = frame.envelope.captureTimeMonotonic
        for (key,count) in free where count >= cfg.minimumSurfaceSupport && occupied[key] == nil {
            // A single conflicting ray cannot erase a supported occupied surface from memory.
            if cells[key]?.evidence != .occupied { cells[key] = VoxelObservation(key: key,evidence: .observedFree,lastObservedAt: captured,support: count) }
        }
        for (key,count) in occupied where count >= cfg.minimumSurfaceSupport {
            cells[key] = VoxelObservation(key: key,evidence: .occupied,lastObservedAt: captured,support: count)
        }
        let truncated = cells.count > cfg.maximumVoxels
        if truncated {
            let kept = cells.values.sorted {
                if $0.lastObservedAt != $1.lastObservedAt { return $0.lastObservedAt > $1.lastObservedAt }
                func distance(_ key: VoxelKey) -> Double {
                    length(SIMD3(Double(key.x)*cfg.voxelSize,Double(key.y)*cfg.voxelSize,Double(key.z)*cfg.voxelSize)-origin)
                }
                return distance($0.key) < distance($1.key)
            }.prefix(cfg.maximumVoxels)
            cells = Dictionary(uniqueKeysWithValues: kept.map { ($0.key,$0) })
        }
        previousFrame = frame
        return OccupancySnapshot(frame: frame,voxelSize: cfg.voxelSize,cells: cells,truncated: truncated)
    }
}

func length(_ value: SIMD3<Double>) -> Double { (value.x*value.x+value.y*value.y+value.z*value.z).squareRoot() }
func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
