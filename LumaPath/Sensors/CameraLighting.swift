#if os(iOS)
import ARKit
import AVFoundation
import LumaPathDomain

/// User-controlled illumination only. Never silently turns on the camera light.
@MainActor public final class CameraLighting {
    private var ownedDevice: AVCaptureDevice?
    public init() {}
    public var enabled: Bool { ownedDevice?.torchMode == .on }
    public func setEnabled(_ enabled: Bool, backend: CaptureBackend?) throws {
        if !enabled { try turnOff(); return }
        let device = backend == .arkit ? ARConfiguration.configurableCaptureDeviceForPrimaryCamera
            : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device, device.hasTorch, device.isTorchAvailable, device.isTorchModeSupported(.on) else {
            throw ContractError.invalidValue("cameraLightUnavailable")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        try device.setTorchModeOn(level: 0.25)
        ownedDevice = device
    }
    public func turnOff() throws {
        guard let device = ownedDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.torchMode = .off; ownedDevice = nil
    }
}
#endif
