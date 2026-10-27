import CoreVideo
import XCTest
import LumaPathDomain
@testable import LumaPathSensors

@MainActor final class AuthorizedCamera: CameraAuthorizing {
    let status = CameraPermission.authorized
    func request() async -> CameraPermission { status }
}

@MainActor final class BufferDriver: CaptureDriver {
    typealias Payload = FrameBuffers
    let capabilities = CapabilitySet(worldTracking: true, sceneDepth: true, smoothedSceneDepth: false, cameraPermission: .authorized)
    var onFrame: (@MainActor (CaptureSample<FrameBuffers>) -> Void)?
    var onEvent: (@MainActor (CaptureDriverEvent) -> Void)?
    func start(depthKind: DepthKind) {}
    func stop() {}
    func updateViewport(_ viewport: CaptureViewport) {}
}

final class PixelBufferLeaseTests: XCTestCase {
    @MainActor func testOriginalBuffersAndMissingConfidenceThroughReadOnlyLease() async throws {
        for includeConfidence in [true, false] {
            let template = try ReplayFixtures.frames()[0]
            let image = try buffer(width: 640, height: 480, format: kCVPixelFormatType_32BGRA)
            let depth = try buffer(width: 160, height: 120, format: kCVPixelFormatType_DepthFloat32)
            let confidence = includeConfidence ? try buffer(width: 160, height: 120, format: kCVPixelFormatType_OneComponent8) : nil
            XCTAssertEqual(CVPixelBufferLockBaseAddress(depth, []), kCVReturnSuccess)
            CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: Float32.self).pointee = 2.0
            CVPixelBufferUnlockBaseAddress(depth, [])
            if let confidence {
                XCTAssertEqual(CVPixelBufferLockBaseAddress(confidence, []), kCVReturnSuccess)
                CVPixelBufferGetBaseAddress(confidence)!.assumingMemoryBound(to: UInt8.self).pointee = 2
                CVPixelBufferUnlockBaseAddress(confidence, [])
            }
            let driver = BufferDriver()
            let provider = CaptureCoordinator(driver: driver, permission: AuthorizedCamera())
            let viewport = CaptureViewport(orientation: template.orientation, size: template.viewportSize)
            provider.updateViewport(viewport)
            await provider.start(context: CaptureContext(sessionID: UUID(), generation: 1, mode: .liveDepth))
            driver.onFrame?(CaptureSample(captureTime: SystemMonotonicClock().now(), imageSize: template.imageSize,
                depthSize: template.depthSize, confidenceSize: includeConfidence ? template.confidenceSize : nil,
                intrinsics: template.intrinsics, cameraToWorld: template.cameraToWorld, viewport: viewport,
                imageToDisplay: template.imageToDisplay, depthKind: .sceneDepth, tracking: .normal,
                payload: FrameBuffers(image: image, depth: depth, confidence: confidence)))
            let frame = try XCTUnwrap(provider.latestFrame)
            let lease = provider.lease(for: frame)
            var reads = 0
            XCTAssertTrue(lease.withReadOnlyBuffers { original in
                reads += 1
                XCTAssertTrue(original.image === image)
                XCTAssertTrue(original.depth === depth)
                XCTAssertEqual(CVPixelBufferGetWidth(original.image), frame.imageSize.width)
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(original.depth!), kCVPixelFormatType_DepthFloat32)
                XCTAssertEqual(CVPixelBufferGetBaseAddress(original.depth!)!.assumingMemoryBound(to: Float32.self).pointee, 2.0)
                if let confidence = original.confidence {
                    XCTAssertEqual(CVPixelBufferGetBaseAddress(confidence)!.assumingMemoryBound(to: UInt8.self).pointee, 2)
                } else { XCTAssertFalse(includeConfidence) }
            })
            XCTAssertEqual(reads, 1)
            provider.stop()
            XCTAssertFalse(lease.withReadOnlyBuffers { _ in XCTFail("Stopped buffers must not be accessible") })
        }
    }

    private func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &result), kCVReturnSuccess)
        return try XCTUnwrap(result)
    }
}
