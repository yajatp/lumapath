import Foundation
import LumaPathDomain

public enum MountMode: String, Codable, CaseIterable, Sendable { case handheld, chestMounted }
public enum AudioReference: String, Sendable { case phoneForward, headForward, motionHeading }
public struct SpatialPosition: Sendable, Equatable { public let x: Double; public let y: Double; public let z: Double }

/// No head pose or walking heading is inferred from a phone. Calibration is ephemeral and session bound.
public struct MountCalibration: Sendable {
    public static let maximumRotationRadians = 25.0 * Double.pi / 180
    public private(set) var context: CaptureContext?
    public private(set) var orientation: ImageOrientation?
    private var rotation: [Double]?
    public init() {}
    @discardableResult public mutating func confirm(frame: FrameDescriptor, context: CaptureContext, at now: Double) -> Bool {
        reset()
        guard frame.envelope.isCurrent(in: context, at: now), frame.tracking == .normal,
              let pose = frame.cameraToWorld, validRotation(pose) else { return false }
        self.context = context; orientation = frame.orientation; rotation = pose; return true
    }
    public mutating func validate(frame: FrameDescriptor, context: CaptureContext, at now: Double) -> Bool {
        guard self.context == context, orientation == frame.orientation,
              frame.envelope.isCurrent(in: context, at: now), frame.tracking == .normal,
              let original = rotation, let pose = frame.cameraToWorld, validRotation(pose) else { reset(); return false }
        let trace = (0..<3).reduce(0.0) { total, column in
            total + (0..<3).reduce(0.0) { $0 + original[column*4+$1] * pose[column*4+$1] }
        }
        let angle = acos(min(1, max(-1, (trace-1)/2)))
        guard angle <= Self.maximumRotationRadians else { reset(); return false }
        return true
    }
    public mutating func reset() { context = nil; orientation = nil; rotation = nil }
    private func validRotation(_ p: [Double]) -> Bool {
        guard p.count == 16, p.allSatisfy(\.isFinite) else { return false }
        for column in 0..<3 {
            let length = (0..<3).reduce(0.0) { $0 + p[column*4+$1]*p[column*4+$1] }
            guard abs(length-1) < 0.02 else { return false }
        }
        for a in 0..<3 { for b in (a+1)..<3 {
            let dot = (0..<3).reduce(0.0) { $0 + p[a*4+$1]*p[b*4+$1] }
            guard abs(dot) < 0.02 else { return false }
        } }
        let determinant = p[0]*(p[5]*p[10]-p[9]*p[6])-p[4]*(p[1]*p[10]-p[9]*p[2])+p[8]*(p[1]*p[6]-p[5]*p[2])
        return abs(determinant-1) < 0.03
    }
}
public enum SpatialPolicy {
    public static let earconDuration = 0.12
    public static func position(bearing: Double?, reference: AudioReference, calibrated: Bool,
                                headphones: Bool, remainingLifetime: Double) -> SpatialPosition? {
        guard reference == .phoneForward, calibrated, headphones,
              remainingLifetime.isFinite, remainingLifetime >= earconDuration,
              let bearing, bearing.isFinite, abs(bearing) <= Double.pi else { return nil }
        // Unit radius, constant gain: never encode exact measured distance in loudness.
        return SpatialPosition(x: sin(bearing), y: 0, z: -cos(bearing))
    }
}
