#if os(iOS)
import CoreVideo
import LumaPathDomain

extension FrameLease where Payload == FrameBuffers {
    /// Samples at most 128×128 luma values while the original buffer is locked by the lease.
    /// This is an image-condition diagnostic, not a restoration or semantic detector.
    public func copyLumaImage() throws -> LumaImage? {
        var result: Result<LumaImage, any Error>?
        let accessed = withReadOnlyBuffers { buffers in
            result = Result {
                let buffer = buffers.image, format = CVPixelBufferGetPixelFormatType(buffer)
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                guard width == descriptor.imageSize.width, height == descriptor.imageSize.height else {
                    throw ContractError.invalidValue("lumaBufferShape")
                }
                let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                guard planar || format == kCVPixelFormatType_32BGRA else { throw ContractError.invalidValue("lumaBufferFormat") }
                let base: UnsafeMutableRawPointer?, stride: Int
                if planar {
                    guard CVPixelBufferGetPlaneCount(buffer) == 2,
                          CVPixelBufferGetWidthOfPlane(buffer,0) == width,
                          CVPixelBufferGetHeightOfPlane(buffer,0) == height else { throw ContractError.invalidValue("lumaPlaneShape") }
                    base = CVPixelBufferGetBaseAddressOfPlane(buffer,0); stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
                } else { base = CVPixelBufferGetBaseAddress(buffer); stride = CVPixelBufferGetBytesPerRow(buffer) }
                guard let base, stride >= width*(planar ? 1 : 4) else { throw ContractError.invalidValue("lumaRowStride") }
                let size = PixelSize(width: min(128,width),height: min(128,height))
                var values: [UInt8] = []; values.reserveCapacity(size.width*size.height)
                for row in 0..<size.height {
                    let y = min(height-1,Int((Double(row)+0.5)*Double(height)/Double(size.height)))
                    let pointer = base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)
                    for column in 0..<size.width {
                        let x = min(width-1,Int((Double(column)+0.5)*Double(width)/Double(size.width)))
                        let luma: Int
                        if planar {
                            let raw = Int(pointer[x])
                            luma = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? max(0,min(255,(raw-16)*255/219)) : raw
                        } else {
                            luma = (29*Int(pointer[x*4])+150*Int(pointer[x*4+1])+77*Int(pointer[x*4+2]))/256
                        }
                        values.append(UInt8(luma))
                    }
                }
                return try LumaImage(frame: descriptor,size: size,values: values)
            }
        }
        guard accessed, let result else { return nil }
        return try result.get()
    }
}
#endif
