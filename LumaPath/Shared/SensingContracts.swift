import Foundation

public enum SourceMode: String, Codable, Sendable { case liveDepth, cameraOnly, demoReplay }
public enum DepthKind: String, Codable, Sendable { case sceneDepth, smoothedSceneDepth, none }
public enum ImageOrientation: String, Codable, Sendable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight }
public enum TrackingQuality: String, Codable, Sendable { case normal, limited, unavailable }

public struct CaptureContext: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let generation: UInt64
    public let mode: SourceMode
    public init(sessionID: UUID, generation: UInt64, mode: SourceMode) {
        self.sessionID = sessionID; self.generation = generation; self.mode = mode
    }
}

public struct FrameID: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public let sequence: UInt64
    public init(context: CaptureContext, sequence: UInt64) {
        sessionID = context.sessionID; generation = context.generation; self.sequence = sequence
    }
}

public struct ObservationEnvelope: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public let frameID: FrameID
    public let sourceMode: SourceMode
    public let captureTimeMonotonic: TimeInterval
    public let createdTimeMonotonic: TimeInterval
    public let expiresAtMonotonic: TimeInterval
    public init(frameID: FrameID, mode: SourceMode, capturedAt: TimeInterval, createdAt: TimeInterval, lifetime: TimeInterval) {
        schemaVersion = 2; self.frameID = frameID; sourceMode = mode
        captureTimeMonotonic = capturedAt; createdTimeMonotonic = createdAt
        expiresAtMonotonic = capturedAt + lifetime
    }
    public func validate() throws {
        guard schemaVersion == 2 else { throw ContractError.unsupportedSchema(schemaVersion) }
        guard captureTimeMonotonic.isFinite, createdTimeMonotonic.isFinite, expiresAtMonotonic.isFinite,
              captureTimeMonotonic >= 0, createdTimeMonotonic >= captureTimeMonotonic,
              expiresAtMonotonic > captureTimeMonotonic else { throw ContractError.invalidValue("timestamps") }
    }
    public func isCurrent(in context: CaptureContext, at time: TimeInterval) -> Bool {
        (try? validate()) != nil && frameID.sessionID == context.sessionID && frameID.generation == context.generation
        && sourceMode == context.mode && time >= createdTimeMonotonic && time < expiresAtMonotonic
    }
}

public struct PixelSize: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var isValid: Bool { width > 0 && height > 0 }
}

/// Pixel-center calibration in the original, unrotated image coordinate system.
public struct CameraIntrinsics: Codable, Sendable, Equatable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public init(fx: Double, fy: Double, cx: Double, cy: Double) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }
    public func scaled(from image: PixelSize, to depth: PixelSize) -> CameraIntrinsics {
        let sx = Double(depth.width) / Double(image.width), sy = Double(depth.height) / Double(image.height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }
    public var isValid: Bool { [fx, fy, cx, cy].allSatisfy(\.isFinite) && fx > 0 && fy > 0 }
}

/// x' = a*x + c*y + tx, y' = b*x + d*y + ty. Normalized image → normalized viewport.
public struct DisplayTransform: Codable, Sendable, Equatable {
    public let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = DisplayTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public func apply(x: Double, y: Double) -> SIMD2<Double> { SIMD2(a*x + c*y + tx, b*x + d*y + ty) }
    public var isValid: Bool { [a, b, c, d, tx, ty].allSatisfy(\.isFinite) && abs(a*d - b*c) > 1e-12 }
}

public struct FrameDescriptor: Codable, Sendable, Equatable {
    /// Nil denotes legacy v2 metadata, which still requires calibration and pose.
    public let metadataVersion: Int?
    public let backend: CaptureBackend?
    public let capabilityRevision: UInt64?
    public let envelope: ObservationEnvelope
    public let imageSize: PixelSize
    public let depthSize: PixelSize?
    public let confidenceSize: PixelSize?
    public let intrinsics: CameraIntrinsics?
    /// Column-major ARKit camera-to-world matrix; ARKit looks along -Z, +Y up.
    public let cameraToWorld: [Double]?
    public let orientation: ImageOrientation
    public let viewportSize: PixelSize
    public let imageToDisplay: DisplayTransform
    public let depthKind: DepthKind
    public let tracking: TrackingQuality

    public init(envelope: ObservationEnvelope, imageSize: PixelSize, depthSize: PixelSize?, confidenceSize: PixelSize?,
                intrinsics: CameraIntrinsics?, cameraToWorld: [Double]?, orientation: ImageOrientation,
                viewportSize: PixelSize, imageToDisplay: DisplayTransform, depthKind: DepthKind, tracking: TrackingQuality, backend: CaptureBackend? = nil, capabilityRevision: UInt64? = nil) {
        self.metadataVersion = 3; self.backend = backend; self.capabilityRevision = capabilityRevision
        self.envelope = envelope; self.imageSize = imageSize; self.depthSize = depthSize; self.confidenceSize = confidenceSize
        self.intrinsics = intrinsics; self.cameraToWorld = cameraToWorld; self.orientation = orientation
        self.viewportSize = viewportSize; self.imageToDisplay = imageToDisplay; self.depthKind = depthKind; self.tracking = tracking
    }
    public func validate() throws {
        try envelope.validate()
        guard metadataVersion == nil || metadataVersion == 3 else { throw ContractError.unsupportedSchema(metadataVersion!) }
        let validPose = cameraToWorld.map { $0.count == 16 && $0.allSatisfy(\.isFinite) } ?? false
        guard imageSize.isValid, viewportSize.isValid, imageToDisplay.isValid,
              intrinsics == nil || intrinsics?.isValid == true,
              cameraToWorld == nil || validPose,
              metadataVersion != nil || (intrinsics != nil && validPose),
              depthKind == .none || intrinsics?.isValid == true,
              tracking == .unavailable || validPose,
              backend != .avfoundation || (depthKind == .none && cameraToWorld == nil && tracking == .unavailable),
              depthSize?.isValid != false, confidenceSize?.isValid != false,
              (depthKind == .none) == (depthSize == nil), confidenceSize == nil || confidenceSize == depthSize,
              envelope.sourceMode != .cameraOnly || depthKind == .none else {
            throw ContractError.invalidValue("frame calibration or depth metadata")
        }
    }
    public func matches(_ other: FrameDescriptor) -> Bool {
        envelope.frameID == other.envelope.frameID && orientation == other.orientation && viewportSize == other.viewportSize
    }
}

public enum CameraPermission: String, Sendable { case notDetermined, authorized, denied, restricted }
public struct CapabilitySet: Sendable, Equatable {
    public let rearCamera: Bool
    public let worldTracking: Bool
    public let sceneDepth: Bool
    public let smoothedSceneDepth: Bool
    public let cameraPermission: CameraPermission
    public var preferredMode: SourceMode? { rearCamera ? (worldTracking && (sceneDepth || smoothedSceneDepth) ? .liveDepth : .cameraOnly) : nil }
    public init(worldTracking: Bool, sceneDepth: Bool, smoothedSceneDepth: Bool, cameraPermission: CameraPermission, rearCamera: Bool = true) {
        self.rearCamera = rearCamera
        self.worldTracking = worldTracking; self.sceneDepth = sceneDepth
        self.smoothedSceneDepth = smoothedSceneDepth; self.cameraPermission = cameraPermission
    }
}

public enum CapturePhase: String, Sendable { case stopped, preparing, running, unavailable, interrupted, blocked }
public struct CaptureStatus: Sendable, Equatable {
    public let phase: CapturePhase
    public let reason: String?
    public init(_ phase: CapturePhase, reason: String? = nil) { self.phase = phase; self.reason = reason }
}

/// MainActor confines buffer access; frames are latest-only presentation/processing input, never an event bus.
@MainActor public protocol SensorProvider: AnyObject {
    var frames: AsyncStream<FrameDescriptor> { get }
    var onStatusChange: (@MainActor (CaptureStatus) -> Void)? { get set }
    func start(context: CaptureContext) async
    func stop()
}

extension DisplayTransform {
    /// Unrotated rear-camera pixels, rotated then aspect-filled into the actual viewport.
    public static func aspectFill(image: PixelSize, viewport: PixelSize, orientation: ImageOrientation) -> DisplayTransform {
        let rotation: DisplayTransform
        let portrait: Bool
        switch orientation {
        case .landscapeRight: rotation = .identity; portrait = false
        case .portrait: rotation = .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0); portrait = true
        case .landscapeLeft: rotation = .init(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1); portrait = false
        case .portraitUpsideDown: rotation = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1); portrait = true
        }
        let width = Double(portrait ? image.height : image.width), height = Double(portrait ? image.width : image.height)
        let scale = max(Double(viewport.width)/width, Double(viewport.height)/height)
        let sx = width*scale/Double(viewport.width), sy = height*scale/Double(viewport.height)
        return .init(a: sx*rotation.a, b: sy*rotation.b, c: sx*rotation.c, d: sy*rotation.d,
                     tx: sx*rotation.tx+(1-sx)/2, ty: sy*rotation.ty+(1-sy)/2)
    }
}
