#if os(iOS)
import Foundation
import LumaPathDomain
import LumaPathAccessories

@MainActor public final class AccessoryOutputSink: FeedbackOutputSink {
    public let phone = PhoneOutputSink()
    public let spatial = SpatialEarconAdapter()
    public let watch = PhoneWatchBridge.shared
    private lazy var combined = IndependentOutputSink(phone: phone, accessories: [spatial, watch])
    public var onCompletion: (@MainActor (UUID) -> Void)? { get { combined.onCompletion } set { combined.onCompletion = newValue } }
    public var onInterruption: (@MainActor () -> Void)? { get { phone.onInterruption } set { phone.onInterruption = newValue } }
    public var onCapabilityChange: (@MainActor () -> Void)?
    public var onAlignmentLost: (@MainActor () -> Void)?
    public var capabilities: OutputCapabilities { combined.capabilities }
    public init() {
        phone.onRouteChange = { [weak self] in
            self?.spatial.routeChanged(); self?.onAlignmentLost?(); self?.onCapabilityChange?()
        }
        phone.onCapabilityChange = { [weak self] in self?.onCapabilityChange?() }
        watch.onChange = { [weak self] in self?.onCapabilityChange?() }
    }
    public func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool { combined.play(item, channels: channels) }
    public func cancel(reason: String) { combined.cancel(reason: reason) }
    public func shutdown() { combined.cancel(reason: "shutdown"); phone.shutdown(); spatial.calibrated = false; watch.stop() }
}
#endif
