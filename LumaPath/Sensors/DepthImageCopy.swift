#if os(iOS)
import CoreVideo
import LumaPathDomain

extension FrameLease where Payload == FrameBuffers {
    /// Copies only bounded depth/confidence values, honoring row padding. No raw pointer escapes the lease.
    public func copyDepthImage() throws -> DepthImage? {
        guard let size = descriptor.depthSize, descriptor.depthKind != .none else { return nil }
        let (count, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        guard !overflow, count <= GeometryConfiguration.current.maximumDepthPixels else { throw ContractError.invalidValue("depthCopyBudget") }
        var result: Result<DepthImage, any Error>?
        let accessed = withReadOnlyBuffers { buffers in
            result = Result {
                guard let depth = buffers.depth, CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
                      CVPixelBufferGetWidth(depth) == size.width, CVPixelBufferGetHeight(depth) == size.height,
                      CVPixelBufferGetBytesPerRow(depth) >= size.width*MemoryLayout<Float>.stride,
                      let base = CVPixelBufferGetBaseAddress(depth) else { throw ContractError.invalidValue("depthBufferFormat") }
                var values: [Float] = []; values.reserveCapacity(count)
                for row in 0..<size.height {
                    let pointer = base.advanced(by: row*CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
                    values.append(contentsOf: UnsafeBufferPointer(start: pointer,count: size.width))
                }
                var confidence: [UInt8]?
                if let map = buffers.confidence {
                    guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent8,
                          CVPixelBufferGetWidth(map) == size.width, CVPixelBufferGetHeight(map) == size.height,
                          CVPixelBufferGetBytesPerRow(map) >= size.width,
                          let confidenceBase = CVPixelBufferGetBaseAddress(map) else { throw ContractError.invalidValue("confidenceBufferFormat") }
                    var copied: [UInt8] = []; copied.reserveCapacity(count)
                    for row in 0..<size.height {
                        let pointer = confidenceBase.advanced(by: row*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: UInt8.self)
                        copied.append(contentsOf: UnsafeBufferPointer(start: pointer,count: size.width))
                    }
                    confidence = copied
                }
                return try DepthImage(frame: descriptor,values: values,confidence: confidence)
            }
        }
        guard accessed, let result else { return nil }
        return try result.get()
    }
}
#endif
