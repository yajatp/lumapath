import XCTest
import CoreImage
import LumaPathDomain
@testable import LumaPathSensors
@testable import LumaPathRendering

final class FrameRendererTests: XCTestCase {
    @MainActor func testDimImageLiftChangesPixelsAndOriginalStillBypassesIt() throws {
        let renderer = FrameRenderer(), size = PixelSize(width: 32, height: 32)
        let image = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        var original = EnhancementSettings(); original.enhanced = false
        let base = try XCTUnwrap(renderer.materialize(image, imageSize: size, viewport: size, transform: .identity, settings: original))
        var lifted = original; lifted.enhanced = true; lifted.exposure = 1.5; lifted.shadowLift = 0.45; lifted.gamma = 0.7
        let changed = try XCTUnwrap(renderer.materialize(image, imageSize: size, viewport: size, transform: .identity, settings: lifted))
        XCTAssertGreaterThan([UInt8](data(changed))[0], [UInt8](data(base))[0])
        lifted.enhanced = false
        let bypass = try XCTUnwrap(renderer.materialize(image, imageSize: size, viewport: size, transform: .identity, settings: lifted))
        XCTAssertEqual(data(base), data(bypass))
    }
    @MainActor func testOriginalBypassesEveryEnhancementAndEnhancementsChangePixels() throws {
        let renderer = FrameRenderer()
        let image = CIImage(color: CIColor(red: 0.7, green: 0.6, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let size = PixelSize(width: 100, height: 100)
        var original = EnhancementSettings(); original.enhanced = false
        let base = try XCTUnwrap(renderer.materialize(image, imageSize: size, viewport: size, transform: .identity, settings: original))
        var altered = original; altered.exposure = 2; altered.contrast = 2; altered.edges = 1; altered.highlightCompression = 1
        let bypass = try XCTUnwrap(renderer.materialize(image, imageSize: size, viewport: size, transform: .identity, settings: altered))
        XCTAssertEqual(data(base), data(bypass))
        for variant in 0..<3 {
            var settings = EnhancementSettings(); settings.highlightCompression = 0
            if variant == 0 { settings.exposure = 1 }
            if variant == 1 { settings.contrast = 1.8 }
            if variant == 2 { settings.highlightCompression = 1 }
            let changed = try XCTUnwrap(renderer.materialize(image, imageSize: size, viewport: size, transform: .identity, settings: settings))
            XCTAssertNotEqual(data(base), data(changed), "Adjustment \(variant) must change the pixels")
        }
    }

    @MainActor func testPixelLandmarksFollowTopLeftTransformsWithoutMirroring() throws {
        let renderer = FrameRenderer()
        let size = PixelSize(width: 100, height: 100)
        let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        // Red at top-left (CI bottom-left y=60..100), blue at bottom-right.
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 60, width: 40, height: 40))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 60, y: 0, width: 40, height: 40))
        let source = red.composited(over: blue.composited(over: background))
        var settings = EnhancementSettings(); settings.enhanced = false
        for transform in [DisplayTransform.identity,
                          DisplayTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0),
                          DisplayTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1),
                          DisplayTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1),
                          DisplayTransform(a: 1.2, b: 0, c: 0, d: 1, tx: -0.1, ty: 0)] {
            let rendered = try XCTUnwrap(renderer.materialize(source, imageSize: size, viewport: size, transform: transform, settings: settings))
            let bytes = [UInt8](data(rendered))
            let point = transform.apply(x: 0.2, y: 0.2)
            let offset = Int(point.y * 100) * rendered.bytesPerRow + Int(point.x * 100) * 4
            XCTAssertGreaterThan(bytes[offset], 240, "Red calibration landmark must match top-left viewport coordinates")
            XCTAssertLessThan(bytes[offset + 2], 10)
        }
        var edges = settings; edges.enhanced = true; edges.highlightCompression = 0; edges.edges = 1
        let edged = try XCTUnwrap(renderer.materialize(source, imageSize: size, viewport: size, transform: .identity, settings: edges))
        let plain = try XCTUnwrap(renderer.materialize(source, imageSize: size, viewport: size, transform: .identity, settings: settings))
        XCTAssertNotEqual(data(edged), data(plain))
    }

    @MainActor func testLeaseInvalidationAndMissingConfidenceDoNotLeakNativeBuffers() async throws {
        let template = try ReplayFixtures.frames()[0]
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        let driver = BufferDriver()
        let provider = CaptureCoordinator(driver: driver, permission: AuthorizedCamera())
        let viewport = CaptureViewport(orientation: template.orientation, size: template.viewportSize)
        provider.updateViewport(viewport)
        await provider.start(context: CaptureContext(sessionID: UUID(), generation: 1, mode: .cameraOnly))
        driver.onFrame?(CaptureSample(captureTime: SystemMonotonicClock().now(), imageSize: template.imageSize,
            depthSize: nil, confidenceSize: nil, intrinsics: nil, cameraToWorld: nil,
            viewport: viewport, imageToDisplay: template.imageToDisplay, depthKind: .none, tracking: .unavailable,
            payload: FrameBuffers(image: image, depth: nil, confidence: nil), backend: .avfoundation))
        let frame = try XCTUnwrap(provider.latestFrame)
        let lease = provider.lease(for: frame)
        let renderer = FrameRenderer()
        let owned = try XCTUnwrap(renderer.render(lease: lease, frame: frame, settings: EnhancementSettings()))
        provider.stop()
        XCTAssertNil(renderer.render(lease: lease, frame: frame, settings: EnhancementSettings()))
        XCTAssertFalse(data(owned).isEmpty) // Output owns its bytes after capture stops.
    }

    private func data(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
}
