import Foundation
import LumaPathDomain

/// Analytic, labeled synthetic depth scenes. They never masquerade as captured device evidence.
public struct GeometryFixture: Codable, Sendable {
    public struct Patch: Codable, Sendable {
        public let x: Int, y: Int, width: Int, height: Int
        public let depth: Float
        public let confidence: UInt8
    }
    public let name: String
    public let floor: Bool
    public let confidencePresent: Bool
    public let patches: [Patch]
    public let expectedCorridor: CorridorRelation?
    public static func load() throws -> [GeometryFixture] {
        try JSONDecoder().decode([GeometryFixture].self,from: Data(contentsOf: ReplayFixtures.url("A3-scenes.json")))
    }
    public func image(context: CaptureContext,sequence: UInt64,at time: Double) throws -> DepthImage {
        guard context.mode == .demoReplay else { throw ContractError.invalidValue("syntheticModeRequired") }
        let width = 64, height = 48
        var values = [Float](repeating: 0,count: width*height), confidence = [UInt8](repeating: 0,count: width*height)
        // Level stationary rig: camera 1 m above y=0, optical +Y down. No image/depth values are recorded.
        if floor {
            for v in 25..<height {
                for u in 0..<width { values[v*width+u] = Float(50.0/Double(v-24)); confidence[v*width+u] = 2 }
            }
        }
        for patch in patches {
            guard patch.x >= 0,patch.y >= 0,patch.width > 0,patch.height > 0,
                  patch.x+patch.width <= width,patch.y+patch.height <= height else { throw ContractError.invalidValue("fixturePatch") }
            for v in patch.y..<patch.y+patch.height {
                for u in patch.x..<patch.x+patch.width { values[v*width+u] = patch.depth; confidence[v*width+u] = patch.confidence }
            }
        }
        let envelope = ObservationEnvelope(frameID: FrameID(context: context,sequence: sequence),mode: .demoReplay,
            capturedAt: time,createdAt: time,lifetime: CaptureConfiguration.current.maximumFrameAge)
        let frame = FrameDescriptor(envelope: envelope,imageSize: PixelSize(width: 640,height: 480),
            depthSize: PixelSize(width: width,height: height),confidenceSize: confidencePresent ? PixelSize(width: width,height: height) : nil,
            intrinsics: CameraIntrinsics(fx: 500,fy: 500,cx: 320,cy: 240),
            cameraToWorld: [1,0,0,0,0,1,0,0,0,0,1,0,0,1,0,1],orientation: .landscapeRight,
            viewportSize: PixelSize(width: 640,height: 480),imageToDisplay: .identity,depthKind: .sceneDepth,tracking: .normal)
        return try DepthImage(frame: frame,values: values,confidence: confidencePresent ? confidence : nil)
    }
}
