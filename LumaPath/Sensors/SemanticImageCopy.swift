#if os(iOS)
import CoreImage
import CoreVideo
import LumaPathDomain

@MainActor private enum SemanticImageEncoding {
    // Reuse the encoder rather than rebuilding a GPU context for each requested frame.
    static let context = CIContext(options: [.cacheIntermediates: false])
}

extension FrameLease where Payload == FrameBuffers {
    /// Explicit requested inference only; do not encode images for every camera frame.
    /// The caller supplies the documented sensor-to-upright quarter turn; no EXIF rotation is baked in.
    public func copySemanticImage(quarterTurn: InputQuarterTurn) throws -> EncodedSemanticImage? {
        var result: Result<EncodedSemanticImage, any Error>?
        let accessed = withReadOnlyBuffers { buffers in
            result = Result {
                let source = CIImage(cvPixelBuffer: buffers.image)
                guard source.extent.width == Double(descriptor.imageSize.width), source.extent.height == Double(descriptor.imageSize.height) else {
                    throw ContractError.invalidValue("semanticBufferShape")
                }
                let scale = min(1,1024/max(source.extent.width,source.extent.height))
                let bounded = source.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
                let context = SemanticImageEncoding.context
                guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                      let data = context.jpegRepresentation(of: bounded,colorSpace: color,options: [:]) else {
                    throw ContractError.invalidValue("semanticImageEncoding")
                }
                return try EncodedSemanticImage(frame: descriptor,data: data,quarterTurn: quarterTurn)
            }
        }
        guard accessed, let result else { return nil }
        return try result.get()
    }
}
#endif
