import Foundation
import LumaPathDomain

public enum GeometryProjection {
    public static func displayPoint(_ point: OpticalPoint, frame: FrameDescriptor) -> SIMD2<Double>? {
        guard point.z.isFinite, point.z > 0, point.x.isFinite, point.y.isFinite,
              (try? frame.validate()) != nil, let k = frame.intrinsics else { return nil }
        return frame.imageToDisplay.apply(x: (k.fx * point.x / point.z + k.cx) / Double(frame.imageSize.width),
                                          y: (k.fy * point.y / point.z + k.cy) / Double(frame.imageSize.height))
    }
    static func displayBounds(_ bounds: NormalizedBounds, frame: FrameDescriptor) -> NormalizedBounds? {
        let points = [(bounds.minX,bounds.minY), (bounds.minX,bounds.maxY), (bounds.maxX,bounds.minY), (bounds.maxX,bounds.maxY)]
            .map { frame.imageToDisplay.apply(x: $0.0, y: $0.1) }
        return NormalizedBounds(minX: points.map(\.x).min()!, minY: points.map(\.y).min()!,
                                maxX: points.map(\.x).max()!, maxY: points.map(\.y).max()!).clipped
    }
}

/// Gravity-aligned world basis; horizontal phone-forward is never assumed to be walking direction.
struct PoseBasis {
    let matrix: [Double]
    let forward: SIMD3<Double>
    let right: SIMD3<Double>
    var cameraHeight: Double { matrix[13] }
    init?(frame: FrameDescriptor) {
        guard frame.tracking == .normal, let m = frame.cameraToWorld, m.count == 16 else { return nil }
        let x = SIMD3(m[0],m[1],m[2]), y = SIMD3(m[4],m[5],m[6]), z = SIMD3(m[8],m[9],m[10])
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
        guard m.allSatisfy(\.isFinite), abs(m[3])+abs(m[7])+abs(m[11])+abs(m[15]-1) < 1e-5,
              abs(dot(x,x)-1)<1e-3, abs(dot(y,y)-1)<1e-3, abs(dot(z,z)-1)<1e-3,
              abs(dot(x,y))+abs(dot(x,z))+abs(dot(y,z))<1e-3 else { return nil }
        let cross = SIMD3(x.y*y.z-x.z*y.y, x.z*y.x-x.x*y.z, x.x*y.y-x.y*y.x)
        guard dot(cross,z) > 0.999 else { return nil }
        let length = hypot(m[8],m[10])
        guard length >= 0.25 else { return nil }
        forward = SIMD3(-m[8]/length,0,-m[10]/length)
        right = SIMD3(-forward.z,0,forward.x)
        matrix = m
    }
    func world(_ point: OpticalPoint) -> SIMD3<Double> {
        let p = point.arKitCameraPoint, m = matrix
        return SIMD3(m[0]*p.x+m[4]*p.y+m[8]*p.z+m[12],
                     m[1]*p.x+m[5]*p.y+m[9]*p.z+m[13],
                     m[2]*p.x+m[6]*p.y+m[10]*p.z+m[14])
    }
    func horizontal(_ point: OpticalPoint) -> SIMD2<Double> {
        let p = world(point)-SIMD3(matrix[12],matrix[13],matrix[14])
        return SIMD2(p.x*right.x+p.z*right.z,p.x*forward.x+p.z*forward.z)
    }
}
