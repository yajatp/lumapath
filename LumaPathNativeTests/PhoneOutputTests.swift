import XCTest
import CoreHaptics
import LumaPathDomain
@testable import LumaPathFeedback

private struct NativeFeedbackClock: MonotonicClock { func now() -> TimeInterval { 100 } }
final class PhoneOutputTests: XCTestCase {
    @MainActor func testAccessoryRouteChangeInvalidatesSpatialReferenceWithoutPhoneInterruption() {
        let sink = AccessoryOutputSink()
        var interruptions = 0, alignmentLosses = 0
        sink.onInterruption = { interruptions += 1 }
        sink.onAlignmentLost = { alignmentLosses += 1 }
        sink.spatial.calibrated = true; sink.spatial.headphonesConfirmed = true
        sink.phone.onRouteChange?()
        XCTAssertFalse(sink.spatial.calibrated)
        XCTAssertFalse(sink.spatial.headphonesConfirmed)
        XCTAssertEqual(alignmentLosses, 1)
        XCTAssertEqual(interruptions, 0)
        sink.shutdown()
    }
    @MainActor func testNativePatternVocabularyIsBoundedAndDistinct() throws {
        XCTAssertEqual(PhoneOutputSink.events(for: .obstacle).count, 2)
        XCTAssertEqual(PhoneOutputSink.events(for: .urgent).count, 3)
        XCTAssertEqual(PhoneOutputSink.events(for: .goal).count, 1)
        for kind in [FeedbackKind.obstacle, .urgent, .limitation, .goal, .paused] {
            let pattern = try CHHapticPattern(events: PhoneOutputSink.events(for: kind), parameters: [])
            XCTAssertLessThanOrEqual(pattern.duration, 0.29)
        }
    }
    @MainActor func testNativeSinkRejectsExpiredAndDisabledOutputAndCancelsIdempotently() {
        let sink = PhoneOutputSink(clock: NativeFeedbackClock())
        let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
        let old = FeedbackItem(context: context, createdAt: 90, expiresAt: 99, kind: .urgent, priority: 6,
            text: "Expired test", repeatKey: "old", source: "nativeTest")
        XCTAssertFalse(sink.play(old, channels: OutputChannels(speech: true, haptics: true)))
        let fresh = FeedbackItem(context: context, createdAt: 100, expiresAt: 101, kind: .preview, priority: 1,
            text: "Muted test", repeatKey: "muted", source: "nativeTest")
        XCTAssertFalse(sink.play(fresh, channels: OutputChannels()))
        sink.cancel(reason: "pause"); sink.cancel(reason: "end"); sink.shutdown()
        #if targetEnvironment(simulator)
        XCTAssertFalse(sink.capabilities.haptics)
        #endif
    }
}
