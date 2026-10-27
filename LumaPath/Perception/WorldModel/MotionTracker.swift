import Foundation
import LumaPathDomain

private struct TrackSample: Sendable {
    let time: Double
    let point: SIMD3<Double>
    let camera: SIMD3<Double>
}
private struct TrackedObject: Sendable {
    let id: UUID
    var samples: [TrackSample]
    var extent: Double
}
/// Greedy unique world-space associations; ambiguous or uncertain matches never produce velocity/encounter claims.
public struct MotionTracker: Sendable {
    private var tracks: [TrackedObject] = []
    private var context: CaptureContext?
    private var previousFrame: FrameDescriptor?
    private let configuration: AdvancedConfiguration
    public init(configuration: AdvancedConfiguration = .current) { self.configuration = configuration }
    public mutating func reset() { tracks = []; context = nil; previousFrame = nil }
    public mutating func update(_ depth: DepthImage, geometry: GeometryResult, context expected: CaptureContext,
                                profile: MobilityGeometryProfile = .standard, at now: Double) throws -> [MotionTrack] {
        let frame = depth.frame, cfg = configuration
        guard frame == geometry.frame, frame.envelope.isCurrent(in: expected,at: now) else { throw ContractError.invalidValue("motionFrameMismatch") }
        guard let pose = PoseBasis(frame: frame), depth.confidence != nil else { reset(); return [] }
        let time = frame.envelope.captureTimeMonotonic
        if context != expected { reset(); context = expected }
        if let previousFrame {
            guard time > previousFrame.envelope.captureTimeMonotonic, frame.envelope.frameID.sequence > previousFrame.envelope.frameID.sequence else {
                throw ContractError.invalidValue("outOfOrderMotion")
            }
            let m = previousFrame.cameraToWorld!, n = pose.matrix
            let turn = acos(max(-1,min(1,m[8]*n[8]+m[9]*n[9]+m[10]*n[10])))
            let displacement = length(SIMD3(n[12]-m[12],n[13]-m[13],n[14]-m[14]))
            if turn > cfg.maximumTurnRadians || displacement > 0.5 { tracks = [] }
        }
        previousFrame = frame
        tracks.removeAll { time-($0.samples.last?.time ?? 0) > cfg.maximumTrackAge }
        let camera = SIMD3(pose.matrix[12],pose.matrix[13],pose.matrix[14])
        var used = Set<UUID>(), output: [MotionTrack] = []
        for observation in geometry.observations.prefix(cfg.maximumTracks) {
            guard observation.envelope.frameID == frame.envelope.frameID,
                  let bounds = observation.details?.imageBounds, let size = frame.depthSize else { continue }
            var points: [SIMD3<Double>] = []
            for v in 0..<5 { for u in 0..<5 {
                let x = min(size.width-1,max(0,Int((bounds.minX+(bounds.maxX-bounds.minX)*(Double(u)+0.5)/5)*Double(size.width))))
                let y = min(size.height-1,max(0,Int((bounds.minY+(bounds.maxY-bounds.minY)*(Double(v)+0.5)/5)*Double(size.height))))
                let index = y*size.width+x, z = Double(depth.values[index])
                guard depth.confidence![index] == 2, abs(z-observation.axialDepthMeters) < 0.15,
                      let point = FrameGeometry.unproject(u: Double(x),v: Double(y),axialDepth: z,frame: frame) else { continue }
                points.append(pose.world(point))
            } }
            guard points.count >= 8 else { continue }
            func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count/2] }
            let position = SIMD3(median(points.map(\.x)),median(points.map(\.y)),median(points.map(\.z)))
            let extent = max(bounds.maxX-bounds.minX,bounds.maxY-bounds.minY)*observation.axialDepthMeters
            let matches = tracks.indices.filter { !used.contains(tracks[$0].id)
                && length(tracks[$0].samples.last!.point-position) <= cfg.associationDistance
                && abs(tracks[$0].extent-extent) < 0.25 }
                .sorted { length(tracks[$0].samples.last!.point-position) < length(tracks[$1].samples.last!.point-position) }
            var reasons: [String] = [], track: TrackedObject
            let ambiguous = matches.count > 1 && abs(length(tracks[matches[0]].samples.last!.point-position)-length(tracks[matches[1]].samples.last!.point-position)) < 0.15
            if let index = matches.first, !ambiguous { track = tracks[index] }
            else { track = TrackedObject(id: UUID(),samples: [],extent: extent); if ambiguous { reasons.append("associationAmbiguous") } }
            used.insert(track.id)
            track.samples.append(TrackSample(time: time,point: position,camera: camera)); track.extent = extent
            track.samples = Array(track.samples.filter { time-$0.time <= cfg.memoryLifetime }.suffix(16))
            var velocity: SIMD3<Double>?, uncertainty: Double?, encounter: Double?, approach: Double?, positionResidual: Double?
            if let first = track.samples.first, track.samples.count >= 3, time-first.time >= 0.25 {
                let span = time-first.time, estimate = (position-first.point)/span
                let residual = track.samples.map { length($0.point-(first.point+estimate*($0.time-first.time))) }.max() ?? 0
                positionResidual = residual
                let error = (2*cfg.positionUncertainty+residual)/span
                uncertainty = error
                let deviceVelocity = (camera-first.camera)/span
                let deviceResidual = track.samples.map { length($0.camera-(first.camera+deviceVelocity*($0.time-first.time))) }.max() ?? 0
                if error <= cfg.maximumVelocityUncertainty && deviceResidual < 0.10 && length(deviceVelocity) <= 3 {
                    velocity = estimate
                    let relative = estimate-deviceVelocity, p = position-camera, speedSquared = dot(relative,relative)
                    // Static world geometry is not a moving object, even during camera translation.
                    if length(estimate) > max(0.15,2*error), speedSquared > 0.01 {
                        let horizon = profile.earlierNotice ? 5.0 : 3.0
                        let t = max(0,min(horizon,-dot(p,relative)/speedSquared))
                        let closest = length(p+relative*t), inflated = profile.requiredWidth/2+extent/2+cfg.positionUncertainty+error*t
                        approach = closest
                        if t > 0 && closest <= inflated { encounter = t }
                    }
                } else { reasons.append("velocityUncertain") }
            } else { reasons.append("insufficientMotionBaseline") }
            if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks[index] = track } else { tracks.append(track) }
            output.append(MotionTrack(id: track.id,observationID: observation.id,worldPosition: position,
                worldVelocity: velocity,velocityUncertainty: uncertainty,encounterTime: encounter,closestApproach: approach,reasons: reasons,positionResidual: positionResidual))
        }
        // Unseen objects remain only for bounded association; never publish them as current observations.
        tracks.sort { $0.samples.last!.time > $1.samples.last!.time }; tracks = Array(tracks.prefix(cfg.maximumTracks))
        return output
    }
}
