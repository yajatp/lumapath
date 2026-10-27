import Foundation
import LumaPathDomain

@MainActor public protocol CameraAuthorizing: AnyObject {
    var status: CameraPermission { get }
    func request() async -> CameraPermission
}

public struct CaptureViewport: Sendable, Equatable {
    public let orientation: ImageOrientation
    /// Pixel dimensions, not UIKit points. Rotation or resize invalidates existing leases.
    public let size: PixelSize
    public init(orientation: ImageOrientation, size: PixelSize) { self.orientation = orientation; self.size = size }
}

public enum CaptureDriverEvent: Sendable {
    case interrupted(String)
    case failed(String)
}

/// Non-Sendable by design. The driver produces samples and accesses payloads only on MainActor.
public struct CaptureSample<Payload> {
    public let captureTime: TimeInterval
    public let imageSize: PixelSize
    public let depthSize: PixelSize?
    public let confidenceSize: PixelSize?
    public let intrinsics: CameraIntrinsics?
    public let cameraToWorld: [Double]?
    public let viewport: CaptureViewport
    public let imageToDisplay: DisplayTransform
    public let depthKind: DepthKind
    public let tracking: TrackingQuality
    public let backend: CaptureBackend?
    public let payload: Payload
    public init(captureTime: TimeInterval, imageSize: PixelSize, depthSize: PixelSize?, confidenceSize: PixelSize?,
                intrinsics: CameraIntrinsics?, cameraToWorld: [Double]?, viewport: CaptureViewport,
                imageToDisplay: DisplayTransform, depthKind: DepthKind, tracking: TrackingQuality, payload: Payload, backend: CaptureBackend? = nil) {
        self.captureTime = captureTime; self.imageSize = imageSize; self.depthSize = depthSize; self.confidenceSize = confidenceSize
        self.intrinsics = intrinsics; self.cameraToWorld = cameraToWorld; self.viewport = viewport
        self.imageToDisplay = imageToDisplay; self.depthKind = depthKind; self.tracking = tracking; self.payload = payload; self.backend = backend
    }
    func descriptor(context: CaptureContext, sequence: UInt64, createdAt: TimeInterval) -> FrameDescriptor {
        FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: context, sequence: sequence), mode: context.mode,
            capturedAt: captureTime, createdAt: createdAt, lifetime: CaptureConfiguration.current.maximumFrameAge),
            imageSize: imageSize, depthSize: depthSize, confidenceSize: confidenceSize, intrinsics: intrinsics,
            cameraToWorld: cameraToWorld, orientation: viewport.orientation, viewportSize: viewport.size,
            imageToDisplay: imageToDisplay, depthKind: depthKind, tracking: tracking, backend: backend,
            capabilityRevision: context.generation)
    }
}

@MainActor public protocol CaptureDriver: AnyObject, Sendable {
    associatedtype Payload
    /// Permission is provided separately by CameraAuthorizing.
    var capabilities: CapabilitySet { get }
    var onFrame: (@MainActor (CaptureSample<Payload>) -> Void)? { get set }
    var onEvent: (@MainActor (CaptureDriverEvent) -> Void)? { get set }
    func start(depthKind: DepthKind)
    func stop()
    func updateViewport(_ viewport: CaptureViewport)
}

/// Non-owning access handle. No payload survives eviction/stop through a lease.
@MainActor public struct FrameLease<Payload> {
    public let descriptor: FrameDescriptor
    let access: (@MainActor (Payload) -> Void) -> Bool
    public var isValid: Bool { access { _ in } }
    // Internal generic access; the native extension exposes read-only pixel-buffer access.
    @discardableResult func withValue(_ body: @MainActor (Payload) -> Void) -> Bool { access(body) }
}
