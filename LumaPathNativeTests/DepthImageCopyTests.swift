import CoreVideo
import XCTest
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk
@testable import LumaPathSensors

private struct QualityNativeClock: MonotonicClock { let time: TimeInterval; func now() -> TimeInterval { time } }

final class DepthImageCopyTests: XCTestCase {
    @MainActor func testPaddedDepthCopyFeedsGeometryAndLedgerBeforePresentation() async throws {
        let fixtureContext = CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay)
        let fixture = try GeometryFixture.load()[0].image(context: fixtureContext,sequence: 1,at: 100)
        let image = try makeBuffer(width: 640,height: 480,format: kCVPixelFormatType_32BGRA)
        let depth = try makeBuffer(width: 64,height: 48,format: kCVPixelFormatType_DepthFloat32)
        let confidence = try makeBuffer(width: 64,height: 48,format: kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(depth,[]),kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(confidence,[]),kCVReturnSuccess)
        for row in 0..<48 {
            let d = CVPixelBufferGetBaseAddress(depth)!.advanced(by: row*CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
            let c = CVPixelBufferGetBaseAddress(confidence)!.advanced(by: row*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
            for column in 0..<64 { d[column] = fixture.values[row*64+column]; c[column] = fixture.confidence![row*64+column] }
        }
        CVPixelBufferUnlockBaseAddress(confidence,[]); CVPixelBufferUnlockBaseAddress(depth,[])
        let driver = BufferDriver(), provider = CaptureCoordinator(driver: driver,permission: AuthorizedCamera())
        let viewport = CaptureViewport(orientation: .landscapeRight,size: PixelSize(width: 640,height: 480))
        let context = CaptureContext(sessionID: UUID(),generation: 1,mode: .liveDepth)
        provider.updateViewport(viewport)
        await provider.start(context: context)
        let template = fixture.frame
        driver.onFrame?(CaptureSample(captureTime: SystemMonotonicClock().now(),imageSize: template.imageSize,
            depthSize: template.depthSize,confidenceSize: template.confidenceSize,intrinsics: template.intrinsics,
            cameraToWorld: template.cameraToWorld,viewport: viewport,imageToDisplay: .identity,depthKind: .sceneDepth,tracking: .normal,
            payload: FrameBuffers(image: image,depth: depth,confidence: confidence)))
        let frame = try XCTUnwrap(provider.latestFrame), lease = provider.lease(for: frame)
        let copied = try XCTUnwrap(try lease.copyDepthImage())
        XCTAssertEqual(copied.values,fixture.values)
        XCTAssertEqual(copied.confidence,fixture.confidence)
        let pipeline = GeometryPipeline()
        pipeline.start(context: context)
        let processed = try await pipeline.process(copied)
        let result = try XCTUnwrap(processed)
        XCTAssertEqual(result.geometry.observations.count,1)
        XCTAssertEqual(result.events.first?.envelope.frameID,frame.envelope.frameID)
        XCTAssertEqual(result.events.first?.corridor,.ahead)
        XCTAssertEqual(pipeline.ledger.pending(at: SystemMonotonicClock().now()).count,1)
        provider.stop(); pipeline.stop()
        XCTAssertNil(try lease.copyDepthImage())
        XCTAssertTrue(pipeline.ledger.pending(at: SystemMonotonicClock().now()).isEmpty)
    }
    @MainActor func testLumaSamplingHonorsPlanarVideoRangeBGRAAndExpiredLeases() async throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] {
            let image = try makeBuffer(width: 640,height: 480,format: format)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(image,[]),kCVReturnSuccess)
            let planar = format != kCVPixelFormatType_32BGRA
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image,0)! : CVPixelBufferGetBaseAddress(image)!
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image,0) : CVPixelBufferGetBytesPerRow(image)
            for y in 0..<480 {
                let row = base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<640 {
                    if planar {
                        row[x] = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? (x < 320 ? 16 : 235) : (x < 320 ? 0 : 255)
                    } else {
                        let value: UInt8 = x < 320 ? 0 : 255
                        row[x*4] = value; row[x*4+1] = value; row[x*4+2] = value; row[x*4+3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(image,[])
            let driver = BufferDriver(), provider = CaptureCoordinator(driver: driver,permission: AuthorizedCamera())
            let viewport = CaptureViewport(orientation: .landscapeRight,size: PixelSize(width: 640,height: 480))
            let context = CaptureContext(sessionID: UUID(),generation: 1,mode: .cameraOnly)
            provider.updateViewport(viewport); await provider.start(context: context)
            let template = try GeometryFixture.load()[0].image(context: CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay),sequence: 1,at: 100).frame
            driver.onFrame?(CaptureSample(captureTime: SystemMonotonicClock().now(),imageSize: template.imageSize,
                depthSize: nil,confidenceSize: nil,intrinsics: template.intrinsics,cameraToWorld: template.cameraToWorld,
                viewport: viewport,imageToDisplay: .identity,depthKind: .none,tracking: .normal,
                payload: FrameBuffers(image: image,depth: nil,confidence: nil)))
            let frame = try XCTUnwrap(provider.latestFrame), lease = provider.lease(for: frame)
            let copied = try XCTUnwrap(try lease.copyLumaImage())
            XCTAssertEqual(copied.values.count,128*128)
            XCTAssertEqual(copied.values.first,0); XCTAssertEqual(copied.values.last,255)
            XCTAssertEqual(copied.values.filter { $0 == 0 }.count,128*64)
            XCTAssertEqual(copied.values.filter { $0 == 255 }.count,128*64)
            // Real native lease -> bounded luma -> shared camera-only session, with no depth processing.
            let quality = QualitySessionPipeline(clock: QualityNativeClock(time: frame.envelope.createdTimeMonotonic))
            quality.start(context: context)
            let snapshot = try await quality.process(frame: frame, depth: nil, image: copied)
            XCTAssertEqual(snapshot?.frame, frame)
            XCTAssertTrue(snapshot?.quality.reasons.contains("cameraOnlyNoDepth") == true)
            XCTAssertTrue(snapshot?.quality.reasons.contains("darkImage") == true)
            XCTAssertNil(snapshot?.quality.usableDepthFraction)
            XCTAssertTrue(snapshot?.geometry.isEmpty == true)
            XCTAssertEqual(quality.ledger.pending(at: frame.envelope.createdTimeMonotonic).count, 1)
            quality.stop()

            provider.stop()
            XCTAssertNil(try lease.copyLumaImage())
        }
    }
    private func makeBuffer(width: Int,height: Int,format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 512] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,width,height,format,attributes,&buffer),kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
