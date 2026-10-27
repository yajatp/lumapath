#if os(iOS)
import Foundation
@preconcurrency import WatchConnectivity
import LumaPathDomain
import LumaPathAccessories

/// Immediate messages only. No background transfer, retry queue, or dependency on watch acknowledgement.
@MainActor public final class PhoneWatchBridge: NSObject, WCSessionDelegate, FeedbackOutputSink {
    public static let shared = PhoneWatchBridge()
    public var onCompletion: (@MainActor (UUID) -> Void)?
    public var onPause: (@MainActor () -> Void)?
    public var onChange: (@MainActor () -> Void)?
    public private(set) var status = "Watch off. Phone output is independent."
    private var current: WatchSession?
    private var offered: (nonce: UUID, time: Double)?
    private var ready: (nonce: UUID, until: Double)?
    private var sequence: UInt64 = 0
    private var pendingID: UUID?
    private var deadline: Task<Void, Never>?
    private let clock = SystemMonotonicClock()
    private var transport: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    public var capabilities: OutputCapabilities {
        OutputCapabilities(speech: false, haptics: false, watch: current != nil && transport?.isReachable == true && (ready?.until ?? 0) > clock.now())
    }
    public func start(context: CaptureContext) {
        stop(); current = WatchSession(context: context); sequence = 0
        guard let transport else { status = "Watch connectivity unavailable. Phone output continues."; onChange?(); return }
        transport.delegate = self; transport.activate()
        status = "Open the watch app and enable Research cues. Waiting for a fresh clock handshake."; onChange?()
    }
    public func stop() {
        if let current { send(.stop(session: current)) }
        current = nil; offered = nil; ready = nil; finishPending()
        status = "Watch off. Phone output is independent."; onChange?()
    }
    public func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool {
        guard channels.watch, capabilities.watch, let current, item.context == current.context, let ready,
              item.isCurrent(in: item.context, at: clock.now()) else { return false }
        // Preview has its own new lifetime; a scene event always retains its original creation/expiry.
        let expiry = min(item.expiresAt, item.createdAt + WatchReceiver.maximumCueLifetime)
        guard expiry > clock.now() else { return false }
        sequence += 1; pendingID = item.id
        let kind = WatchCueKind(rawValue: item.kind.rawValue) ?? .obstacle
        let cue = WatchCue(nonce: ready.nonce, session: current, sequence: sequence, eventID: item.id,
            createdAt: item.createdAt, expiresAt: expiry, kind: kind, text: item.text)
        send(.cue(cue)); status = "Watch cue sent; receipt unconfirmed."; onChange?()
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiry - (self?.clock.now() ?? expiry)))) } catch { return }
            guard let self, self.pendingID == item.id else { return }
            self.status = "Watch acknowledgement deadline passed; cue discarded. Phone output continues."
            self.finishPending(); self.onChange?()
        }
        return true
    }
    public func cancel(reason: String) {
        if let current, let ready { sequence += 1; send(.cancel(nonce: ready.nonce, session: current, sequence: sequence)) }
        // The coordinator owns cancellation, so no completion callback here.
        pendingID = nil; deadline?.cancel(); deadline = nil
    }
    private func finishPending() {
        let id = pendingID; pendingID = nil; deadline?.cancel(); deadline = nil
        if let id { onCompletion?(id) }
    }
    private func send(_ packet: WatchWire) {
        guard let transport, transport.activationState == .activated, transport.isReachable, let data = try? packet.encoded() else { return }
        transport.sendMessage(["packet": data], replyHandler: nil, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.disconnected() }
        })
    }
    private func disconnected() {
        offered = nil; ready = nil; finishPending()
        status = "Watch disconnected or message failed. Phone output continues; reconnect discards old cues."; onChange?()
    }
    private func receive(_ packet: WatchWire) {
        switch packet {
        case .probe(let nonce):
            ready = nil; offered = (nonce, clock.now())
            send(.probeReply(nonce: nonce, session: current, phoneTime: clock.now()))
        case .ready(let nonce, let session):
            guard session == current, offered?.nonce == nonce, let time = offered?.time,
                  clock.now()-time < WatchReceiver.maximumRoundTrip * 2 else { return }
            ready = (nonce, time + WatchReceiver.handshakeLifetime - WatchReceiver.maximumRoundTrip)
            status = "Watch reachable with bounded clock handshake. Delivery still needs acknowledgement."; onChange?()
        case .pause(let nonce, let session):
            guard session == current, ready?.nonce == nonce else { return }
            send(.acknowledgement(eventID: nonce, accepted: true)); onPause?(); stop()
        case .acknowledgement(let id, let accepted):
            guard pendingID == id else { return }
            status = accepted ? "Watch accepted the cue before expiry; physical delivery unverified." : "Watch rejected the cue. Phone output continues."
            finishPending(); onChange?()
        default: break
        }
    }
    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message["packet"] as? Data, let packet = try? WatchWire.decode(data) else { return }
        Task { @MainActor [weak self] in self?.receive(packet) }
    }
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in if !reachable { self?.disconnected() } }
    }
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) { Task { @MainActor [weak self] in self?.disconnected() } }
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
