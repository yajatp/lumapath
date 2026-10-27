#if os(iOS)
import Foundation
import AVFoundation
import LumaPathDomain
import LumaPathAccessories

/// Explicit phone-forward reference only. No head-tracking or motion-heading claim.
@MainActor public final class SpatialEarconAdapter: FeedbackOutputSink {
    public var onCompletion: (@MainActor (UUID) -> Void)?
    public var calibrated = false
    /// A2DP can also be a speaker. Route type alone cannot establish headphones are worn.
    public var headphonesConfirmed = false {
        didSet {
            if oldValue && !headphonesConfirmed, let id = activeID {
                cancel(reason: "headphonesUnconfirmed"); onCompletion?(id)
            }
        }
    }
    private lazy var engine = AVAudioEngine()
    private var prepared = false
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private var completion: Task<Void, Never>?
    private var activeID: UUID?
    private let clock = SystemMonotonicClock()
    public init() {}
    // Merely opening a screen must not initialize RemoteIO or an audio graph.
    private func prepareEngine() {
        guard !prepared else { return }
        engine.attach(environment); engine.attach(player)
        let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        player.renderingAlgorithm = .HRTF
        player.volume = 0.15
        prepared = true
    }
    public var headphones: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return headphonesConfirmed && outputs.count == 1 && outputs.allSatisfy {
            [.headphones, .bluetoothA2DP].contains($0.portType) && ($0.channels?.count ?? 0) >= 2
        }
    }
    public var capabilities: OutputCapabilities {
        OutputCapabilities(speech: false, haptics: false, reason: calibrated && headphones ? nil :
            "Spatial cues need stereo headphones and current phone-forward alignment; enabled phone cues remain available.",
            spatial: calibrated && headphones)
    }
    public func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool {
        cancel(reason: "replacement")
        guard channels.spatial, item.isCurrent(in: item.context, at: clock.now()),
              let position = SpatialPolicy.position(bearing: item.bearingRadians, reference: .phoneForward,
                calibrated: calibrated, headphones: headphones, remainingLifetime: item.expiresAt-clock.now()) else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            prepareEngine()
            try engine.start()
            guard headphones, item.expiresAt-clock.now() >= SpatialPolicy.earconDuration else { engine.stop(); return false }
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let count = AVAudioFrameCount(44_100 * SpatialPolicy.earconDuration)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let samples = buffer.floatChannelData?[0] else { return false }
            buffer.frameLength = count
            for index in 0..<Int(count) {
                let t = Double(index)/44_100, fade = min(1, min(t/0.01, (SpatialPolicy.earconDuration-t)/0.01))
                samples[index] = Float(sin(2 * .pi * 660 * t) * max(0, fade) * 0.35)
            }
            player.position = AVAudio3DPoint(x: Float(position.x), y: 0, z: Float(position.z))
            activeID = item.id; player.scheduleBuffer(buffer); player.play()
            completion = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(min(SpatialPolicy.earconDuration, max(0, item.expiresAt - (self?.clock.now() ?? item.expiresAt))))) } catch { return }
                guard let self, self.activeID == item.id else { return }
                self.cancel(reason: "completed"); self.onCompletion?(item.id)
            }
            return true
        } catch { cancel(reason: "audioUnavailable"); return false }
    }
    public func routeChanged() {
        let id = activeID; calibrated = false; headphonesConfirmed = false; cancel(reason: "routeChanged")
        if let id { onCompletion?(id) }
    }
    public func cancel(reason: String) {
        activeID = nil; completion?.cancel(); completion = nil
        if prepared { player.stop(); engine.stop() }
    }
}
#endif
