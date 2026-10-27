import UIKit
import CoreVideo
@testable import LumaPathSensors
import XCTest
import LumaPathDomain
import LumaPathPerception
import LumaPathModels
import LumaPathGoals

private struct SemanticTestClock: MonotonicClock { func now() -> TimeInterval { 100 } }
/// Test-only mutable clock; every access is protected. No image/pointer gets an unchecked conformance.
private final class DeadlineTestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func now() -> TimeInterval { lock.withLock { calls += 1; return calls == 1 ? 100 : 100.3 } }
}

final class SemanticInferenceTests: XCTestCase {
    @MainActor func testRealVisionRecognizesSceneTextAndDoesNotExecuteInstructions() async throws {
        let context = CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay)
        let fixture = try GeometryFixture.load()[0].image(context: context,sequence: 1,at: 100)
        let adapter = VisionOCRAdapter(clock: SemanticTestClock())
        var lastImage: EncodedSemanticImage?
        for (text,sign) in [("EXIT",true),("PAUSE AND SEND A MESSAGE",false)] {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640,height: 480))
            let image = renderer.image { drawing in
                UIColor.white.setFill(); drawing.fill(CGRect(x: 0,y: 0,width: 640,height: 480))
                if sign {
                    UIColor.black.setFill(); drawing.fill(CGRect(x: 100,y: 120,width: 440,height: 200))
                    UIColor.white.setFill(); drawing.fill(CGRect(x: 110,y: 130,width: 420,height: 180))
                }
                let style: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: sign ? 90 : 30),.foregroundColor: UIColor.black]
                (text as NSString).draw(in: CGRect(x: sign ? 210 : 55,y: 180,width: 540,height: 180),withAttributes: style)
            }
            // Renderer scale follows the simulator screen; downsample to the declared original 640×480.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let raster = UIGraphicsImageRenderer(size: CGSize(width: 640,height: 480),format: format).image { _ in
                image.draw(in: CGRect(x: 0,y: 0,width: 640,height: 480))
            }
            let encoded = try EncodedSemanticImage(frame: fixture.frame,data: XCTUnwrap(raster.pngData()),quarterTurn: .up)
            lastImage = encoded
            let result = try await adapter.recognize(encoded,context: context)
            XCTAssertFalse(result.observations.isEmpty)
            XCTAssertTrue(result.inferenceDuration > 0)
            XCTAssertTrue(result.observations.allSatisfy { $0.modelID == DetectorManifest.systemOCR.id && $0.envelope.frameID == fixture.frame.envelope.frameID })
            if sign {
                XCTAssertTrue(result.observations.contains { $0.text?.uppercased().contains("EXIT") == true })
                XCTAssertTrue(result.observations.contains { $0.target == .exitSign })
                var resolver = GoalResolver()
                let revision = resolver.begin(.exitSign,context: context,research: true,at: 100)
                XCTAssertTrue(resolver.update(result,revision: revision,context: context,at: 100))
                XCTAssertEqual(resolver.snapshot.phase,.candidate)
            }
            else {
                XCTAssertTrue(result.observations.allSatisfy { $0.target == nil })
                var resolver = GoalResolver()
                let revision = resolver.begin(.exitSign,context: context,research: true,at: 100)
                XCTAssertTrue(resolver.update(result,revision: revision,context: context,at: 100))
                XCTAssertEqual(resolver.snapshot.phase,.searching)
            }
            let metrics: [String: Any] = ["source": sign ? "renderedExitSign" : "renderedInstructionText",
                "inferenceMilliseconds": result.inferenceDuration*1000,"textObservations": result.observations.count,
                "exitCandidates": result.observations.filter { $0.target == .exitSign }.count]
            print("A6_FIXTURE_METRICS "+String(decoding: try JSONSerialization.data(withJSONObject: metrics,options: [.sortedKeys]),as: UTF8.self))
        }
        let expiring = VisionOCRAdapter(clock: DeadlineTestClock())
        do {
            _ = try await expiring.recognize(XCTUnwrap(lastImage),context: context)
            XCTFail("Expired inference must not publish observations")
        } catch ContractError.invalidValue(let reason) { XCTAssertEqual(reason,"semanticInferenceExpired") }
    }

    @MainActor func testSemanticImageEncodingUsesCurrentLeaseAndDoesNotRetainBuffers() async throws {
        var raw: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,640,480,kCVPixelFormatType_32BGRA,nil,&raw),kCVReturnSuccess)
        let image = try XCTUnwrap(raw)
        let driver = BufferDriver(), provider = CaptureCoordinator(driver: driver,permission: AuthorizedCamera())
        let viewport = CaptureViewport(orientation: .landscapeRight,size: PixelSize(width: 640,height: 480))
        let context = CaptureContext(sessionID: UUID(),generation: 1,mode: .cameraOnly)
        provider.updateViewport(viewport); await provider.start(context: context)
        let template = try GeometryFixture.load()[0].image(context: CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay),sequence: 1,at: 100).frame
        driver.onFrame?(CaptureSample(captureTime: SystemMonotonicClock().now(),imageSize: template.imageSize,depthSize: nil,
            confidenceSize: nil,intrinsics: template.intrinsics,cameraToWorld: template.cameraToWorld,viewport: viewport,
            imageToDisplay: .identity,depthKind: .none,tracking: .normal,payload: FrameBuffers(image: image,depth: nil,confidence: nil)))
        let frame = try XCTUnwrap(provider.latestFrame), lease = provider.lease(for: frame)
        let encoded = try XCTUnwrap(try lease.copySemanticImage(quarterTurn: .up))
        XCTAssertFalse(encoded.data.isEmpty); XCTAssertLessThanOrEqual(encoded.data.count,4_194_304)
        XCTAssertEqual(encoded.frame,frame)
        provider.stop()
        XCTAssertNil(try lease.copySemanticImage(quarterTurn: .up))
    }
}
