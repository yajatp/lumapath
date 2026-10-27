#if os(iOS)
import ARKit
import AVFoundation
import Combine
import UIKit
import LumaPathDomain
import LumaPathMemory

@MainActor public final class CameraPermissionService: CameraAuthorizing {
    public init() {}
    public var status: CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
    public func request() async -> CameraPermission {
        if status == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        return status
    }
}

/// References the original SDK pixel buffers. Never serialized, mutated, or marked unchecked Sendable.
public struct FrameBuffers {
    public let image: CVPixelBuffer
    public let depth: CVPixelBuffer?
    public let confidence: CVPixelBuffer?

    fileprivate func readOnly(_ body: (FrameBuffers) -> Void) -> Bool {
        let buffers = [image, depth, confidence].compactMap { $0 }
        var locked: [CVPixelBuffer] = []
        defer { for buffer in locked.reversed() { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) } }
        for buffer in buffers {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
            locked.append(buffer)
        }
        body(self)
        return true
    }
}

extension FrameLease where Payload == FrameBuffers {
    /// Synchronous MainActor scope. Do not retain buffers/base pointers or enqueue GPU/async work
    /// using them past this closure. Copy bounded samples (or complete GPU reads) within the scope.
    @discardableResult public func withReadOnlyBuffers(_ body: @MainActor (FrameBuffers) -> Void) -> Bool {
        var read = false
        let valid = withValue { buffers in read = buffers.readOnly(body) }
        return valid && read
    }
}

/// Immutable Sendable continuations carry SDK-declared Sendable ARFrame values across the delegate queue.
/// No Task is created per frame; the stream retains only the newest pending frame.
private final class SessionDelegate: NSObject, ARSessionDelegate, Sendable {
    let frames: AsyncStream<ARFrame>.Continuation
    let event: @Sendable (CaptureDriverEvent) -> Void
    init(frames: AsyncStream<ARFrame>.Continuation, event: @escaping @Sendable (CaptureDriverEvent) -> Void) {
        self.frames = frames; self.event = event
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) { frames.yield(frame) }
    func sessionWasInterrupted(_ session: ARSession) { event(.interrupted("sessionInterrupted")) }
    func session(_ session: ARSession, didFailWithError error: any Error) {
        let error = error as NSError
        event(.failed("arkitFailure:\(error.domain):\(error.code)"))
    }
    // Interruption end never restarts automatically. The caller must supply a new generation.
}

@MainActor public final class ARKitDriver: CaptureDriver {
    public typealias Payload = FrameBuffers
    public var onFrame: (@MainActor (CaptureSample<FrameBuffers>) -> Void)?
    public var onEvent: (@MainActor (CaptureDriverEvent) -> Void)?
    private let session = ARSession()
    private let delegateQueue = DispatchQueue(label: "org.lumapath.capture", qos: .userInteractive)
    private var bridge: SessionDelegate?
    private var frameTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var backgroundObserver: AnyCancellable?
    private var eventContinuation: AsyncStream<CaptureDriverEvent>.Continuation?
    private var viewport: CaptureViewport?
    private var depthKind: DepthKind = .none

    public init() {}
    deinit { frameTask?.cancel(); eventTask?.cancel() }
    public var capabilities: CapabilitySet {
        #if targetEnvironment(simulator)
        let supported = false
        #else
        let supported = ARWorldTrackingConfiguration.isSupported
        #endif
        return CapabilitySet(worldTracking: supported,
            sceneDepth: supported && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            smoothedSceneDepth: supported && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
            cameraPermission: .notDetermined, rearCamera: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil)
    }
    public func updateViewport(_ viewport: CaptureViewport) { self.viewport = viewport }

    public func start(depthKind: DepthKind) { start(depthKind: depthKind, initialMap: nil) }
    /// Caller must start a new capture generation and a new alignment gate before restoring.
    /// Loading an initial map is only a hypothesis; it does not authorize remembered overlays.
    public func restore(worldMapData: Data, depthKind: DepthKind) throws {
        let map = try WorldMapArchive.decode(worldMapData)
        start(depthKind: depthKind, initialMap: map)
    }
    public func captureWorldMap() async throws -> Data {
        guard let activeBridge = bridge, let frame = session.currentFrame,
              case .normal = frame.camera.trackingState,
              frame.worldMappingStatus == .mapped else { throw ContractError.invalidValue("worldMapCaptureQuality") }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { map, error in
                if let error { continuation.resume(throwing: error); return }
                guard let map else {
                    continuation.resume(throwing: ContractError.invalidValue("worldMapCaptureUnavailable"))
                    return
                }
                // Archive on the callback queue so the non-Sendable map never crosses actors.
                continuation.resume(with: Result { try WorldMapArchive.encode(map) })
            }
        }
        // Recheck after suspension: a stopped/interrupted session must not report a successful scan.
        guard bridge === activeBridge, let latest = session.currentFrame,
              case .normal = latest.camera.trackingState, latest.worldMappingStatus == .mapped else {
            throw ContractError.invalidValue("worldMapCaptureInterrupted")
        }
        return data
    }
    /// Uses current independently observed features, never anchors loaded from a saved map.
    public func capturePlaceDraft(name: String, appVersion: String) async throws -> PlaceArchive {
        let data = try await captureWorldMap()
        guard !Task.isCancelled, let frame = session.currentFrame,
              case .normal = frame.camera.trackingState, frame.worldMappingStatus == .mapped,
              let features = frame.rawFeaturePoints else { throw ContractError.invalidValue("scanInterrupted") }
        let positions = features.points.prefix(512).map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
        return try PlaceScan.draft(name: name, appVersion: appVersion, worldMap: data, positions: positions)
    }
    private func start(depthKind: DepthKind, initialMap: ARWorldMap?) {
        stop()
        guard capabilities.worldTracking else { onEvent?(.failed("worldTrackingUnsupported")); return }
        self.depthKind = depthKind
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = initialMap
        configuration.worldAlignment = .gravity
        configuration.providesAudioData = false
        switch depthKind {
        case .sceneDepth:
            guard capabilities.sceneDepth else { onEvent?(.failed("depthUnsupported")); return }
            configuration.frameSemantics = .sceneDepth
        case .smoothedSceneDepth:
            guard capabilities.smoothedSceneDepth else { onEvent?(.failed("depthUnsupported")); return }
            configuration.frameSemantics = .smoothedSceneDepth
        case .none: configuration.frameSemantics = []
        }
        let (stream, frames) = AsyncStream<ARFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Session interruptions/failures are low-volume control events, separate from frame coalescing.
        let (events, eventContinuation) = AsyncStream<CaptureDriverEvent>.makeStream()
        self.eventContinuation = eventContinuation
        let bridge = SessionDelegate(frames: frames, event: { eventContinuation.yield($0) })
        self.bridge = bridge
        session.delegateQueue = delegateQueue
        session.delegate = bridge
        frameTask = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { return }
                self?.deliver(frame)
            }
        }
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.onEvent?(event)
            }
        }
        backgroundObserver = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.interrupted("appInactive")) }
            }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    public func stop() {
        session.pause()
        session.delegate = nil
        bridge?.frames.finish(); bridge = nil
        eventContinuation?.finish(); eventContinuation = nil
        frameTask?.cancel(); frameTask = nil
        eventTask?.cancel(); eventTask = nil
        backgroundObserver?.cancel(); backgroundObserver = nil
    }

    private func deliver(_ frame: ARFrame) {
        guard let viewport else { return }
        let depth: ARDepthData? = switch depthKind {
        case .sceneDepth: frame.sceneDepth
        case .smoothedSceneDepth: frame.smoothedSceneDepth
        case .none: nil
        }
        let imageSize = size(frame.capturedImage)
        let cameraSize = PixelSize(width: Int(frame.camera.imageResolution.width), height: Int(frame.camera.imageResolution.height))
        let matrix = frame.camera.intrinsics
        let intrinsics = CameraIntrinsics(fx: Double(matrix[0, 0]), fy: Double(matrix[1, 1]),
            cx: Double(matrix[2, 0]), cy: Double(matrix[2, 1])).scaled(from: cameraSize, to: imageSize)
        let transform = frame.displayTransform(for: viewport.orientation.uiOrientation,
            viewportSize: CGSize(width: viewport.size.width, height: viewport.size.height))
        let world = frame.camera.transform
        let cameraToWorld = (0..<4).flatMap { column in (0..<4).map { row in Double(world[column, row]) } }
        let tracking: TrackingQuality = switch frame.camera.trackingState {
        case .normal: .normal
        case .limited: .limited
        case .notAvailable: .unavailable
        }
        onFrame?(CaptureSample(captureTime: frame.timestamp, imageSize: imageSize,
            depthSize: depth.map { size($0.depthMap) }, confidenceSize: depth?.confidenceMap.map(size),
            intrinsics: intrinsics, cameraToWorld: cameraToWorld, viewport: viewport,
            imageToDisplay: DisplayTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx, ty: transform.ty),
            depthKind: depth == nil ? .none : depthKind, tracking: tracking,
            payload: FrameBuffers(image: frame.capturedImage, depth: depth?.depthMap, confidence: depth?.confidenceMap), backend: .arkit))
    }
    private func size(_ buffer: CVPixelBuffer) -> PixelSize {
        PixelSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }
}

private extension ImageOrientation {
    var uiOrientation: UIInterfaceOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}

public typealias ARKitSensorProvider = CaptureCoordinator<ARKitDriver>
extension CaptureCoordinator where Driver == ARKitDriver {
    public convenience init() { self.init(driver: ARKitDriver(), permission: CameraPermissionService()) }
}
#endif
