import Foundation
import LumaPathDomain

/// Display adjustment from original luma, not a model of visibility or sensor reliability.
public struct LowLightPreviewAdjustment: Sendable {
    public enum Scene: String, Sendable { case unknown, normal, dim, veryDark }
    public let scene: Scene
    public let exposure: Double
    public let shadowLift: Double
    public let gamma: Double
    public var message: String {
        switch scene {
        case .unknown: "Lighting has not been measured from a current image."
        case .normal: "Camera lighting measured. Automatic preview lift is minimal."
        case .dim: "Dim scene. Preview brightening can reveal existing detail; add light for better camera input."
        case .veryDark: "Very dark scene. Image detail may be missing. Use the flashlight or add room lighting."
        }
    }
}

public struct LowLightPreviewPolicy: Sendable {
    private var context: CaptureContext?
    private var previousTime: Double?
    private var exposure = 0.0
    public init() {}
    public mutating func reset() { context = nil; previousTime = nil; exposure = 0 }
    public mutating func update(image: LumaImage?, context: CaptureContext, at now: Double) -> LowLightPreviewAdjustment {
        guard let image, image.frame.envelope.isCurrent(in: context, at: now), !image.values.isEmpty else {
            reset(); return .init(scene: .unknown, exposure: 0, shadowLift: 0, gamma: 1)
        }
        let mean = Double(image.values.reduce(0) { $0 + Int($1) }) / Double(image.values.count) / 255
        let clipped = Double(image.values.filter { $0 >= 245 }.count) / Double(image.values.count)
        let scene: LowLightPreviewAdjustment.Scene = mean < 0.035 ? .veryDark : mean < 0.25 && clipped < 0.2 ? .dim : .normal
        let target = scene == .normal ? 0 : min(1.5, max(0, log2(0.30 / max(0.03, mean))))
        if self.context != context || previousTime == nil || now - previousTime! > 0.3 {
            exposure = target
        } else {
            // Gradual gain changes avoid amplifying frame-to-frame exposure oscillation.
            let alpha = 1 - exp(-max(0, now - previousTime!) / 0.6)
            exposure += alpha * (target - exposure)
        }
        self.context = context; previousTime = now
        return .init(scene: scene, exposure: exposure, shadowLift: min(0.45, exposure * 0.3), gamma: max(0.7, 1 - exposure * 0.2))
    }
}
