#if os(iOS)
import AVFoundation
import CoreMedia
import UIKit
import Combine
import LumaPathDomain

/// Only session start/stop crosses queues. All access to this SDK object is serialized by queue.
/// Pixel buffers never enter this wrapper or cross an actor boundary.
private final class CameraSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "org.lumapath.standard-camera")
    func configure(_ body: (AVCaptureSession) throws -> Void) rethrows { try queue.sync { try body(session) } }
    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.sync { if session.isRunning { session.stopRunning() } } }
}

@MainActor private final class CameraSampleDelegate: NSObject, @preconcurrency AVCaptureVideoDataOutputSampleBufferDelegate {
    let receive: @MainActor (CMSampleBuffer) -> Void
    init(receive: @escaping @MainActor (CMSampleBuffer) -> Void) { self.receive = receive }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // setSampleBufferDelegate below always uses DispatchQueue.main; consume buffers synchronously.
        receive(sampleBuffer)
    }
}

@MainActor public final class StandardCameraDriver: CaptureDriver {
    public typealias Payload = FrameBuffers
    public var onFrame: (@MainActor (CaptureSample<FrameBuffers>) -> Void)?
    public var onEvent: (@MainActor (CaptureDriverEvent) -> Void)?
    public var onPressureChange: (@MainActor (ResourcePressure) -> Void)?
    private let runner = CameraSessionRunner()
    private var output: AVCaptureVideoDataOutput?
    private var bridge: CameraSampleDelegate?
    private var observers: [AnyCancellable] = []
    private var pressureObservation: NSKeyValueObservation?
    private var viewport: CaptureViewport?
    private var runID: UUID?
    public init() {}
    public var capabilities: CapabilitySet {
        CapabilitySet(worldTracking: false, sceneDepth: false, smoothedSceneDepth: false,
            cameraPermission: .notDetermined,
            rearCamera: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil)
    }
    public func updateViewport(_ viewport: CaptureViewport) { self.viewport = viewport }
    public func start(depthKind: DepthKind) {
        stop()
        guard depthKind == .none else { onEvent?(.failed("depthUnsupported")); return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            onEvent?(.failed("rearCameraUnavailable")); return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            try runner.configure { session in
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                else if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw ContractError.invalidValue("cameraConfigurationUnavailable")
                }
                session.addInput(input); session.addOutput(output)
                // Keep sensor pixels unrotated; the descriptor carries the display rotation.
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
            }
            let token = UUID(); runID = token
            pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                let pressure: ResourcePressure
                switch device.systemPressureState.level {
                case .nominal: pressure = .nominal
                case .fair: pressure = .elevated
                case .serious: pressure = .serious
                default: pressure = .critical
                }
                Task { @MainActor [weak self] in
                    guard self?.runID == token else { return }
                    self?.onPressureChange?(pressure)
                }
            }
            let bridge = CameraSampleDelegate { [weak self] sample in
                guard let self, self.runID == token else { return }
                self.deliver(sample)
            }
            self.bridge = bridge; self.output = output
            output.setSampleBufferDelegate(bridge, queue: .main)
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
                         UIApplication.willResignActiveNotification] {
                observers.append(NotificationCenter.default.publisher(for: name)
                    .receive(on: DispatchQueue.main).sink { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard self?.runID == token else { return }
                            self?.onEvent?(.interrupted("standardCameraInterrupted"))
                        }
                    })
            }
            runner.start()
        } catch { stop(); onEvent?(.failed("standardCameraConfigurationFailed")) }
    }
    public func stop() {
        runID = nil; output?.setSampleBufferDelegate(nil, queue: nil)
        runner.stop()
        runner.configure { session in
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
        output = nil; bridge = nil; observers.removeAll(); pressureObservation = nil
        onPressureChange?(.nominal)
    }
    private func deliver(_ sample: CMSampleBuffer) {
        guard let viewport, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let size = PixelSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        onFrame?(CaptureSample(captureTime: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            imageSize: size, depthSize: nil, confidenceSize: nil, intrinsics: nil, cameraToWorld: nil,
            viewport: viewport, imageToDisplay: .aspectFill(image: size, viewport: viewport.size, orientation: viewport.orientation),
            depthKind: .none, tracking: .unavailable,
            payload: FrameBuffers(image: image, depth: nil, confidence: nil), backend: .avfoundation))
    }
}
#endif
