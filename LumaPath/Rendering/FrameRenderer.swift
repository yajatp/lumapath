#if os(iOS)
import Foundation
import CoreImage
import CoreGraphics
import CoreVideo
import LumaPathDomain
import LumaPathSensors

/// Synchronous materialization is intentional: no CIImage, pixel buffer, or GPU work escapes a lease.
/// One reusable context and one owned output; the caller replaces the previous displayed image.
@MainActor public final class FrameRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    public init() {}
    public func purgeCaches() { context.clearCaches() }

    public func render(lease: FrameLease<FrameBuffers>, frame: FrameDescriptor,
                       settings: EnhancementSettings) -> CGImage? {
        guard lease.descriptor == frame, (try? frame.validate()) != nil else { return nil }
        var result: CGImage?
        let accessed = lease.withReadOnlyBuffers { buffers in
            guard CVPixelBufferGetWidth(buffers.image) == frame.imageSize.width,
                  CVPixelBufferGetHeight(buffers.image) == frame.imageSize.height else { return }
            result = materialize(CIImage(cvPixelBuffer: buffers.image), imageSize: frame.imageSize,
                                 viewport: frame.viewportSize, transform: frame.imageToDisplay, settings: settings)
        }
        return accessed ? result : nil
    }

    /// Static fixtures have no live lifetime or sensor authority. This method never opens a camera.
    public func preview(_ image: CGImage, settings: EnhancementSettings) -> CGImage? {
        let size = PixelSize(width: image.width, height: image.height)
        return materialize(CIImage(cgImage: image), imageSize: size, viewport: size, transform: .identity, settings: settings)
    }

    // Internal for native calibration tests. CI uses bottom-left pixel coordinates; contracts use top-left normalized.
    func materialize(_ image: CIImage, imageSize: PixelSize, viewport: PixelSize,
                     transform t: DisplayTransform, settings: EnhancementSettings) -> CGImage? {
        guard settings.isValid, imageSize.isValid, t.isValid, let size = RenderBoundary.outputSize(for: viewport) else { return nil }
        let w = Double(size.width), h = Double(size.height), iw = Double(imageSize.width), ih = Double(imageSize.height)
        let mapping = CGAffineTransform(a: w*t.a/iw, b: -h*t.b/iw, c: -w*t.c/ih, d: h*t.d/ih,
                                        tx: w*(t.c+t.tx), ty: h*(1-t.d-t.ty))
        guard [mapping.a, mapping.b, mapping.c, mapping.d, mapping.tx, mapping.ty].allSatisfy(\.isFinite) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var output = image.transformed(by: mapping).cropped(to: rect)
        if settings.enhanced {
            output = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: settings.contrast])
            if settings.highlightCompression > 0 || settings.shadowLift > 0 {
                output = output.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1-settings.highlightCompression, "inputShadowAmount": settings.shadowLift])
            }
            if settings.gamma != 1 { output = output.applyingFilter("CIGammaAdjust", parameters: ["inputPower": settings.gamma]) }
            if settings.edges > 0 {
                // Image gradients only, not detected objects or an indication of a safe path.
                let edges = output.clampedToExtent().applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: settings.edges]).cropped(to: rect)
                output = edges.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: output])
            }
        }
        let rowBytes = size.width * 4
        var bytes = Data(count: rowBytes * size.height)
        bytes.withUnsafeMutableBytes { memory in
            context.render(output, toBitmap: memory.baseAddress!, rowBytes: rowBytes, bounds: rect, format: .RGBA8, colorSpace: colorSpace)
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
