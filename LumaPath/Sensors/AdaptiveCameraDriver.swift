#if os(iOS)
import LumaPathDomain

/// Selects one backend per start. Session replacement/fallback is explicit at the composition boundary.
@MainActor public final class AdaptiveCameraDriver: CaptureDriver {
    public typealias Payload = FrameBuffers
    public var onFrame: (@MainActor (CaptureSample<FrameBuffers>) -> Void)?
    public var onEvent: (@MainActor (CaptureDriverEvent) -> Void)?
    public var onPressureChange: (@MainActor (ResourcePressure) -> Void)?
    public var forceStandardCamera = false
    public private(set) var selectedBackend: CaptureBackend?
    private let ar = ARKitDriver()
    private let camera = StandardCameraDriver()
    public init() {
        camera.onPressureChange = { [weak self] in self?.onPressureChange?($0) }
    }
    public var capabilities: CapabilitySet {
        let hardware = ar.capabilities
        return CapabilitySet(worldTracking: hardware.worldTracking && !forceStandardCamera,
            sceneDepth: hardware.sceneDepth && !forceStandardCamera,
            smoothedSceneDepth: hardware.smoothedSceneDepth && !forceStandardCamera,
            cameraPermission: hardware.cameraPermission, rearCamera: camera.capabilities.rearCamera)
    }
    public func updateViewport(_ viewport: CaptureViewport) { ar.updateViewport(viewport); camera.updateViewport(viewport) }
    public func start(depthKind: DepthKind) {
        stop()
        if !forceStandardCamera && ar.capabilities.worldTracking {
            selectedBackend = .arkit
            ar.onFrame = { [weak self] in self?.onFrame?($0) }
            ar.onEvent = { [weak self] in self?.onEvent?($0) }
            ar.start(depthKind: depthKind)
        } else {
            selectedBackend = .avfoundation
            camera.onFrame = { [weak self] in self?.onFrame?($0) }
            camera.onEvent = { [weak self] in self?.onEvent?($0) }
            camera.start(depthKind: depthKind)
        }
    }
    public func stop() {
        ar.onFrame = nil; ar.onEvent = nil; ar.stop()
        camera.onFrame = nil; camera.onEvent = nil; camera.stop()
    }
}
#endif
