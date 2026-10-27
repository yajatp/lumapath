import Foundation
import LumaPathDomain

private struct Cell {
    let x: Int, y: Int, support: Int
    let point: OpticalPoint
    let bounds: NormalizedBounds
    let world: SIMD3<Double>?
    let horizontal: SIMD2<Double>?
    let region: ViewRegion?
}

/// Bounded per-frame geometry; temporal state is limited to an optional calibrated-floor candidate.
public struct GeometryProcessor: Sendable {
    public let configuration: GeometryConfiguration
    private var previousGround: (context: CaptureContext, time: Double, height: Double, count: Int)?
    public init(configuration: GeometryConfiguration = .current) { self.configuration = configuration }

    public mutating func process(_ depth: DepthImage, context: CaptureContext, at now: TimeInterval) throws -> GeometryResult {
        let frame = depth.frame
        guard frame.envelope.isCurrent(in: context, at: now) else { throw ContractError.invalidValue("staleGeometryFrame") }
        guard let intrinsics = frame.intrinsics else { throw ContractError.invalidValue("calibrationUnavailable") }
        let size = frame.depthSize!, cfg = configuration, tile = cfg.tileSize
        let width = (size.width+tile-1)/tile, height = (size.height+tile-1)/tile
        let pose = PoseBasis(frame: frame)
        let k = intrinsics.scaled(from: frame.imageSize, to: size)
        var cells = [Cell?](repeating: nil, count: width*height)
        var totals = [ViewRegion: Int](), accepted = [ViewRegion: Int]()
        var validCount = 0
        func region(_ u: Double, _ v: Double) -> ViewRegion? {
            let p = frame.imageToDisplay.apply(x: u/Double(size.width), y: v/Double(size.height))
            guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
            return p.x < 1.0/3 ? .left : (p.x < 2.0/3 ? .center : .right)
        }
        for ty in 0..<height {
            try Task.checkCancellation()
            for tx in 0..<width {
                var samples: [(z: Double, u: Int, v: Int)] = []
                for v in ty*tile..<min((ty+1)*tile,size.height) {
                    for u in tx*tile..<min((tx+1)*tile,size.width) {
                        let index = v*size.width+u, z = Double(depth.values[index]), r = region(Double(u),Double(v))
                        if let r { totals[r,default:0] += 1 }
                        let confidence = depth.confidence?[index]
                        guard z.isFinite, z >= cfg.minimumDepth, z <= cfg.maximumDepth,
                              confidence == nil || (confidence! >= 1 && confidence! <= 2) else { continue }
                        let rawX = (Double(u)-k.cx)*z/k.fx, rawY = (Double(v)-k.cy)*z/k.fy
                        guard rawX*rawX+rawY*rawY+z*z <= cfg.maximumDepth*cfg.maximumDepth else { continue }
                        validCount += 1
                        if let r { accepted[r,default:0] += 1 }
                        samples.append((z,u,v))
                    }
                }
                // Use a supported depth cluster rather than averaging foreground/background together.
                samples.sort { $0.z < $1.z }
                var clusters: [[(z: Double,u: Int,v: Int)]] = []
                for sample in samples {
                    if let first = clusters.last?.first, sample.z-first.z <= cfg.depthDiscontinuity {
                        clusters[clusters.count-1].append(sample)
                    } else { clusters.append([sample]) }
                }
                guard let cluster = clusters.first(where: { $0.count >= cfg.minimumTileSupport }) else { continue }
                let z = median(cluster.map(\.z)), u = median(cluster.map { Double($0.u) }), v = median(cluster.map { Double($0.v) })
                let point = OpticalPoint(x: (u-k.cx)*z/k.fx,y: (v-k.cy)*z/k.fy,z: z)
                let bounds = NormalizedBounds(minX: Double(cluster.map(\.u).min()!)/Double(size.width),
                    minY: Double(cluster.map(\.v).min()!)/Double(size.height),
                    maxX: Double(cluster.map(\.u).max()!+1)/Double(size.width), maxY: Double(cluster.map(\.v).max()!+1)/Double(size.height))
                cells[ty*width+tx] = Cell(x: tx,y: ty,support: cluster.count,point: point,bounds: bounds,
                    world: pose?.world(point),horizontal: pose?.horizontal(point),region: region(u,v))
            }
        }
        let ground = estimateGround(cells.compactMap { $0 }, pose: pose, context: context,
                                    time: frame.envelope.captureTimeMonotonic, confidenceKnown: depth.confidence != nil)
        if ground.status == .confirmed, let floor = ground.worldHeightMeters {
            for index in cells.indices {
                if let y = cells[index]?.world?.y, abs(y-floor) <= cfg.groundResidual { cells[index] = nil }
            }
        }
        var visited = [Bool](repeating: false,count: cells.count), observations: [GeometryObservation] = []
        var small = 0
        var regionalNearest = [ViewRegion: Double]()
        for start in cells.indices where cells[start] != nil && !visited[start] {
            try Task.checkCancellation()
            var queue = [start], head = 0, component: [Cell] = []
            visited[start] = true
            while head < queue.count {
                let index = queue[head]; head += 1
                let cell = cells[index]!
                component.append(cell)
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let x = cell.x+dx, y = cell.y+dy
                    guard x >= 0,x < width,y >= 0,y < height else { continue }
                    let next = y*width+x
                    guard !visited[next], let neighbor = cells[next], abs(neighbor.point.z-cell.point.z) <= cfg.depthDiscontinuity else { continue }
                    let p = neighbor.point, q = cell.point
                    guard pow(p.x-q.x,2)+pow(p.y-q.y,2)+pow(p.z-q.z,2) <= pow(cfg.neighborDistance,2) else { continue }
                    visited[next] = true; queue.append(next)
                }
            }
            guard component.reduce(0, { $0+$1.support }) >= cfg.minimumComponentSupport else { small += 1; continue }
            for cell in component {
                if let region = cell.region { regionalNearest[region] = min(regionalNearest[region] ?? .infinity,cell.point.range) }
            }
            observations.append(observation(component, frame: frame, ground: ground, confidenceKnown: depth.confidence != nil))
        }
        observations.sort {
            $0.rangeMeters < $1.rangeMeters
        }
        var reasons = ["unvalidatedGeometry"]
        if depth.confidence == nil { reasons.append("confidenceUnknown") }
        if ground.status != .confirmed { reasons.append("groundShapeUncertain") }
        if pose == nil { reasons.append("horizontalReferenceUnavailable") }
        if small > 0 { reasons.append("insufficientConnectedSupport") }
        if observations.count > cfg.maximumComponents { reasons.append("componentBudgetExceeded") }
        let allObservations = observations
        observations = Array(observations.prefix(cfg.maximumComponents))
        let regions = ViewRegion.allCases.map { r in
            RegionSummary(region: r,sampledPixels: totals[r,default:0],usablePixels: accepted[r,default:0],
                nearestRangeMeters: regionalNearest[r])
        }
        let denominator = regions.reduce(0) { $0+$1.sampledPixels }, usable = regions.reduce(0) { $0+$1.usablePixels }
        let coverage = denominator > 0 ? Double(usable)/Double(denominator) : nil
        if (coverage ?? 0) < 0.7 { reasons.append("limitedDepthCoverage") }
        if validCount == 0 { reasons.append("noUsableDepth") }
        // The budget is explicit; nearest-first prioritization must not be mistaken for complete coverage.
        if allObservations.count > cfg.maximumComponents { reasons.append("additionalGeometryUnrepresented") }
        return GeometryResult(frame: frame, observations: observations, regions: regions, ground: ground,
            quality: QualityAssessment(state: validCount == 0 ? .unavailable : .limited,reasons: reasons,usableDepthFraction: coverage),
            discardedSmallComponents: small)
    }

    private mutating func estimateGround(_ cells: [Cell], pose: PoseBasis?, context: CaptureContext,
                                         time: Double, confidenceKnown: Bool) -> GroundEstimate {
        let cfg = configuration
        func unknown(_ reason: String) -> GroundEstimate { GroundEstimate(status: .unknown,worldHeightMeters: nil,supportingSamples: 0,reason: reason) }
        guard let height = cfg.calibratedCameraHeight, height.isFinite, height > 0, let pose, confidenceKnown else {
            previousGround = nil; return unknown("calibratedGroundUnavailable")
        }
        let expected = pose.cameraHeight-height
        let candidates = cells.filter { abs(($0.world?.y ?? .infinity)-expected) <= cfg.groundHeightTolerance }
            .sorted { $0.world!.y < $1.world!.y }
        var best: ArraySlice<Cell> = [], left = 0, bestSupport = 0, support = 0
        for right in candidates.indices {
            support += candidates[right].support
            while candidates[right].world!.y-candidates[left].world!.y > 2*cfg.groundResidual {
                support -= candidates[left].support; left += 1
            }
            if support > bestSupport { bestSupport = support; best = candidates[left...right] }
        }
        guard !best.isEmpty else { previousGround = nil; return unknown("groundSupportUnavailable") }
        let floor = median(best.map { $0.world!.y })
        let inliers = candidates.filter { abs($0.world!.y-floor) <= cfg.groundResidual }
        let count = inliers.reduce(0) { $0+$1.support }
        let xs = inliers.map { $0.world!.x }, zs = inliers.map { $0.world!.z }
        guard count >= cfg.groundMinimumSupport, Set(inliers.compactMap(\.region)).count >= 2,
              (xs.max()!-xs.min()!) >= cfg.groundMinimumSpan, (zs.max()!-zs.min()!) >= cfg.groundMinimumSpan else {
            previousGround = nil; return unknown("groundSupportNotDistributed")
        }
        var consecutive = 1
        if let previousGround, previousGround.context == context, time > previousGround.time,
           time-previousGround.time <= CaptureConfiguration.current.maximumFrameAge,
           abs(floor-previousGround.height) <= cfg.groundResidual { consecutive = previousGround.count+1 }
        previousGround = (context,time,floor,consecutive)
        let confirmed = consecutive >= cfg.groundConfirmationFrames
        return GroundEstimate(status: confirmed ? .confirmed : .candidate,worldHeightMeters: floor,supportingSamples: count,
                              reason: confirmed ? "calibratedHorizontalFloor" : "groundAwaitingConsistency")
    }

    private func observation(_ cells: [Cell], frame: FrameDescriptor, ground: GroundEstimate, confidenceKnown: Bool) -> GeometryObservation {
        // Nearest supported tile median; do not average a credible close surface into the background.
        let nearest = cells.sorted { $0.point.range < $1.point.range }
        let point = nearest[0].point
        let bounds = NormalizedBounds(minX: cells.map { $0.bounds.minX }.min()!,minY: cells.map { $0.bounds.minY }.min()!,
            maxX: cells.map { $0.bounds.maxX }.max()!,maxY: cells.map { $0.bounds.maxY }.max()!)
        let horizontal = cells.compactMap(\.horizontal)
        let corridor: CorridorRelation
        var bearing: Double?
        if horizontal.count == cells.count {
            let minX = horizontal.map(\.x).min()!, maxX = horizontal.map(\.x).max()!
            let inFront = horizontal.contains { $0.y >= configuration.minimumDepth && $0.y <= configuration.maximumDepth }
            if inFront && minX <= configuration.corridorWidth/2 && maxX >= -configuration.corridorWidth/2 { corridor = .ahead }
            else if maxX < -configuration.corridorWidth/2 { corridor = .left }
            else if minX > configuration.corridorWidth/2 { corridor = .right }
            else { corridor = .unknown }
            bearing = atan2(median(horizontal.map(\.x)),median(horizontal.map(\.y)))
        } else { corridor = .unknown }
        let heights: [Double] = ground.status == .confirmed ? cells.compactMap { cell in
            guard let y = cell.world?.y, let floor = ground.worldHeightMeters else { return nil }; return y-floor
        } : []
        let height = heights.isEmpty ? nil : median(heights)
        let details = GeometryDetails(imageBounds: bounds,displayBounds: GeometryProjection.displayBounds(bounds,frame: frame),
            corridor: corridor,bearingRadians: bearing,supportCount: cells.reduce(0) { $0+$1.support },
            groundRelation: (height ?? 0) > configuration.groundResidual ? .raised : .unclassified,
            heightAboveGroundMeters: height,evidence: confidenceKnown ? .confidenceBacked : .confidenceUnknown)
        return GeometryObservation(id: UUID(),envelope: frame.envelope,opticalPoint: point,axialDepthMeters: point.z,rangeMeters: point.range,details: details)
    }
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted(), middle = sorted.count/2
    return sorted.count%2 == 0 ? (sorted[middle-1]+sorted[middle])/2 : sorted[middle]
}

public actor PerceptionEngine {
    private var processor: GeometryProcessor
    private var quality = QualityEvaluator()
    private var advanced = AdvancedResearchProcessor()
    public init(configuration: GeometryConfiguration = .current) { processor = GeometryProcessor(configuration: configuration) }
    public func process(_ depth: DepthImage, image: LumaImage? = nil, advancedResearch: Bool = false, profile: MobilityGeometryProfile = .standard, context: CaptureContext, at time: TimeInterval) throws -> GeometryResult {
        let assessment = try quality.evaluate(frame: depth.frame,depth: depth,image: image,context: context,at: time)
        let result = try processor.process(depth,context: context,at: time)
        // A3's unvalidated/ground/component limitations remain visible alongside A4 evidence.
        let reasons = result.quality.reasons + assessment.reasons.filter { !result.quality.reasons.contains($0) }
        let advancedResult = advancedResearch ? try advanced.process(depth,geometry: result,context: context,profile: profile,at: time) : nil
        return GeometryResult(frame: result.frame,observations: result.observations,regions: result.regions,ground: result.ground,
            quality: QualityAssessment(state: assessment.state == .unavailable ? .unavailable : .limited,
                reasons: reasons,usableDepthFraction: assessment.usableDepthFraction,details: assessment.details),
            discardedSmallComponents: result.discardedSmallComponents,advanced: advancedResult)
    }
}
