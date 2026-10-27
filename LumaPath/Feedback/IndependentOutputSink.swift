import Foundation

/// Starts phone output first. Accessories cannot delay it or stop it on disconnect.
@MainActor public final class IndependentOutputSink: FeedbackOutputSink {
    public var onCompletion: (@MainActor (UUID) -> Void)?
    private let sinks: [any FeedbackOutputSink]
    private var activeID: UUID?
    private var pending: Set<Int> = []
    private var starting = false
    public init(phone: any FeedbackOutputSink, accessories: [any FeedbackOutputSink]) {
        sinks = [phone] + accessories
        for (index, sink) in sinks.enumerated() {
            sink.onCompletion = { [weak self] id in self?.completed(index, id: id) }
        }
    }
    public var capabilities: OutputCapabilities {
        OutputCapabilities(speech: sinks.contains { $0.capabilities.speech }, haptics: sinks.contains { $0.capabilities.haptics },
            reason: sinks.compactMap { $0.capabilities.reason }.joined(separator: " "),
            spatial: sinks.contains { $0.capabilities.spatial }, watch: sinks.contains { $0.capabilities.watch })
    }
    public func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool {
        cancel(reason: "replacement"); activeID = item.id
        // Reserve all slots first so a synchronous completion cannot finish the whole item early.
        pending = Set(sinks.indices)
        starting = true
        var accepted = false
        for (index, sink) in sinks.enumerated() {
            if sink.play(item, channels: channels) { accepted = true }
            else { pending.remove(index) }
        }
        starting = false
        if !accepted { activeID = nil; return false }
        finishIfComplete()
        return true
    }
    public func cancel(reason: String) {
        activeID = nil; pending.removeAll()
        for sink in sinks { sink.cancel(reason: reason) }
    }
    private func completed(_ index: Int, id: UUID) {
        guard id == activeID else { return }
        pending.remove(index)
        finishIfComplete()
    }
    private func finishIfComplete() {
        guard !starting, pending.isEmpty, let id = activeID else { return }
        activeID = nil; onCompletion?(id)
    }
}
