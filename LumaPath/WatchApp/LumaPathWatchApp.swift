import SwiftUI
import WatchKit
@preconcurrency import WatchConnectivity
import LumaPathDomain
import LumaPathAccessories

@main struct LumaPathWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LumaPath Research").font(.headline)
                    Text(model.status)
                    Text(model.cueText).accessibilityIdentifier("watch.cue")
                    Toggle("Research cues", isOn: $model.enabled)
                    Text("Phone-forward directions, not walking directions. Phone alerts work without this watch.")
                    Button("Pause both") { model.pause() }
                    Text("Preview: one tap = attention. Read the cue meaning; no directional haptic code is validated.")
                    ForEach(WatchCueKind.allCases, id: \.self) { kind in
                        Button("Preview \(kind.rawValue)") { model.preview(kind) }
                    }
                    Text("Preview only. A system tap already issued cannot be retracted. No queued patterns.").font(.footnote)
                }.padding()
            }
            .onAppear { model.foreground = phase == .active }
            .onChange(of: phase) { _, value in model.foreground = value == .active }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                    model.tick()
                }
            }
        }
    }
}

@MainActor final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var enabled = false { didSet { reset(); if enabled { connect() } else { status = "Watch cues off." } } }
    @Published private(set) var status = "Watch cues off."
    @Published private(set) var cueText = "No current cue."
    var foreground = false { didSet { if !foreground { enabled = false; reset() } else if enabled { connect() } } }
    private var receiver = WatchReceiver()
    private let clock = SystemMonotonicClock()
    private var nextProbe = 0.0
    private var probePending = false
    private var pauseID: UUID?
    private var previewDeadline = 0.0
    override init() { super.init(); WCSession.default.delegate = self; WCSession.default.activate() }
    private func connect() { nextProbe = 0; status = "Waiting for a fresh phone handshake." }
    private func reset() { receiver.disconnect(); probePending = false; cueText = "No current cue."; previewDeadline = 0 }
    func tick() {
        let now = clock.now()
        guard foreground else { return }
        if previewDeadline > 0 {
            if now >= previewDeadline { previewDeadline = 0; cueText = "No current cue." }
            else { return }
        }
        guard enabled else { return }
        guard WCSession.default.isReachable else { reset(); status = "Phone unreachable. Phone pause is unconfirmed; phone output is independent."; return }
        if !probePending { receiver.expire(at: now) }
        cueText = receiver.current?.text ?? "No current cue."
        if now >= nextProbe {
            let nonce = receiver.beginProbe(at: now); probePending = true; nextProbe = now + 1
            send(.probe(nonce: nonce))
        }
    }
    func preview(_ kind: WatchCueKind) {
        guard foreground else { return }
        enabled = false; cueText = "Preview: \(kind.rawValue)."; previewDeadline = clock.now()+2
        status = "Local preview; live cues off."; WKInterfaceDevice.current().play(.click)
    }
    func pause() {
        let session = receiver.session, nonce = receiver.nonce
        enabled = false; status = "Watch paused. Phone pause unconfirmed."
        if let session, let nonce, WCSession.default.isReachable {
            pauseID = nonce; send(.pause(nonce: nonce, session: session))
        }
    }
    private func send(_ packet: WatchWire) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let data = try? packet.encoded() else { return }
        WCSession.default.sendMessage(["packet": data], replyHandler: nil, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.reset(); self?.status = "Connection failed. Phone pause/delivery unconfirmed." }
        })
    }
    private func receive(_ packet: WatchWire) {
        switch packet {
        case .probeReply(let nonce, let session, let phoneTime):
            guard foreground, enabled, receiver.completeProbe(nonce: nonce, session: session, phoneTime: phoneTime, at: clock.now()), let session else { return }
            probePending = false; send(.ready(nonce: nonce, session: session)); status = "Research connected; no validated guidance."
        case .cue(let cue):
            let accepted = foreground && enabled && receiver.receive(cue, at: clock.now())
            if accepted {
                cueText = cue.text
                // Single immediate system tap. WatchKit supplies no stop API; physical gate remains open.
                WKInterfaceDevice.current().play(.click)
            }
            send(.acknowledgement(eventID: cue.eventID, accepted: accepted))
        case .cancel(let nonce, let session, let sequence):
            if receiver.cancel(nonce: nonce, session: session, sequence: sequence) { cueText = "No current cue." }
        case .stop(let session):
            if receiver.session == session { reset(); status = "Phone session ended. No current cue." }
        case .acknowledgement(let id, let accepted):
            if id == pauseID && accepted { pauseID = nil; status = "Phone and watch paused." }
        default: break
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message["packet"] as? Data, let packet = try? WatchWire.decode(data) else { return }
        Task { @MainActor [weak self] in self?.receive(packet) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {}
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.reset(); self?.connect() }
    }
}
