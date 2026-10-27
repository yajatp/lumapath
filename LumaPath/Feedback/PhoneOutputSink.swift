#if os(iOS)
import Foundation
import AVFoundation
import CoreHaptics
import Combine
import UIKit
import LumaPathDomain

/// One synthesizer and one cancellable pattern player. No utterance backlog or scheduled UIImpact pulses.
@MainActor public final class PhoneOutputSink: NSObject, FeedbackOutputSink, AVSpeechSynthesizerDelegate {
    public var onCompletion: (@MainActor (UUID) -> Void)?
    public var onInterruption: (@MainActor () -> Void)?
    public var onRouteChange: (@MainActor () -> Void)?
    public var onCapabilityChange: (@MainActor () -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var deadline: Task<Void, Never>?
    private var hapticCompletion: Task<Void, Never>?
    private var notifications: [AnyCancellable] = []
    private var active: FeedbackItem?
    private var playbackID = UUID()
    private var utteranceID: ObjectIdentifier?
    private var speechFinished = true
    private var hapticFinished = true
    private var failure: String?
    private var hapticFailed = false
    private var lastRouteSignature = ""
    private let clock: any MonotonicClock
    public init(clock: any MonotonicClock = SystemMonotonicClock()) {
        self.clock = clock
        super.init(); synthesizer.delegate = self; lastRouteSignature = Self.routeSignature()
        notifications.append(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel(reason: "audioInterruption"); self?.onInterruption?() }
            })
        notifications.append(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                let value = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let signature = Self.routeSignature()
                    // Setting our mixing category without changing hardware does not invalidate alignment.
                    if value == AVAudioSession.RouteChangeReason.categoryChange.rawValue && signature == self.lastRouteSignature { return }
                    self.lastRouteSignature = signature
                    if let callback = self.onRouteChange { callback() }
                    else { self.cancel(reason: "audioRouteChanged"); self.onInterruption?() }
                }
            })
    }
    deinit { deadline?.cancel(); hapticCompletion?.cancel() }
    private static func routeSignature() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.uid):\($0.portType.rawValue):\($0.channels?.count ?? 0)" }.joined(separator: "|")
    }
    public var capabilities: OutputCapabilities {
        let speech = AVSpeechSynthesisVoice(language: "en-US") != nil
        let haptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        var reasons = [String]()
        if !speech { reasons.append("English phone speech is unavailable. Text remains available.") }
        if !haptics { reasons.append("Custom phone haptics are unavailable on this device.") }
        if let failure { reasons.append(failure) }
        return OutputCapabilities(speech: speech, haptics: haptics && !hapticFailed,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: " "))
    }
    public func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool {
        cancel(reason: "replacement")
        guard item.isCurrent(in: item.context, at: clock.now()) else { return false }
        let token = playbackID
        active = item; speechFinished = true; hapticFinished = true
        if channels.haptics && capabilities.haptics {
            do {
                if engine == nil {
                    let created = try CHHapticEngine()
                    engine = created
                }
                engine?.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in guard self?.playbackID == token else { return }; self?.hapticsStopped() }
                }
                engine?.resetHandler = { [weak self] in
                    Task { @MainActor in guard self?.playbackID == token else { return }; self?.hapticsStopped() }
                }
                try engine?.start()
                // Engine initialization can outlive the request. Check again before starting either channel.
                guard item.isCurrent(in: item.context, at: clock.now()) else { cancel(reason: "expiredDuringPreparation"); return false }
                let events = Self.events(for: item.kind)
                let pattern = try CHHapticPattern(events: events, parameters: [])
                player = try engine?.makePlayer(with: pattern)
                try player?.start(atTime: CHHapticTimeImmediate)
                hapticFinished = false
                hapticCompletion = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(0.29)) } catch { return }
                    guard self?.playbackID == token else { return }
                    self?.hapticFinished = true; self?.finishIfReady()
                }
            } catch { hapticFailed = true; failure = "Phone haptics could not start. Text remains available."; onCapabilityChange?() }
        }
        if channels.speech, let voice = AVSpeechSynthesisVoice(language: "en-US"), item.isCurrent(in: item.context, at: clock.now()) {
            let utterance = AVSpeechUtterance(string: item.text)
            utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utteranceID = ObjectIdentifier(utterance); speechFinished = false
            synthesizer.speak(utterance)
        }
        guard !speechFinished || !hapticFinished else { active = nil; return false }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, item.expiresAt - (self?.clock.now() ?? item.expiresAt)))) } catch { return }
            guard self?.playbackID == token else { return }
            self?.cancel(reason: "expired"); self?.onCompletion?(item.id)
        }
        return true
    }
    public func cancel(reason: String) {
        playbackID = UUID()
        active = nil; utteranceID = nil; deadline?.cancel(); deadline = nil
        hapticCompletion?.cancel(); hapticCompletion = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? player?.stop(atTime: CHHapticTimeImmediate); player = nil
        speechFinished = true; hapticFinished = true
    }
    public func shutdown() {
        cancel(reason: "shutdown"); engine?.stop(completionHandler: nil); engine = nil
        hapticFailed = false; failure = nil
    }
    private func hapticsStopped() {
        guard !hapticFinished else { return }
        try? player?.stop(atTime: CHHapticTimeImmediate); player = nil; hapticFinished = true
        hapticFailed = true; failure = "Phone haptics stopped. Text and enabled speech remain available."
        onCapabilityChange?(); finishIfReady()
    }
    private func finishIfReady() {
        guard speechFinished && hapticFinished, let item = active else { return }
        active = nil; utteranceID = nil; deadline?.cancel(); deadline = nil
        player = nil; onCompletion?(item.id)
    }
    private func finishedSpeech(_ id: ObjectIdentifier) {
        guard utteranceID == id else { return }
        speechFinished = true; finishIfReady()
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeech(id) }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeech(id) }
    }
    static func events(for kind: FeedbackKind) -> [CHHapticEvent] {
        let times: [TimeInterval] = kind == .urgent ? [0, 0.09, 0.18] : kind == .obstacle ? [0, 0.14] : [0]
        if kind == .limitation {
            return [CHHapticEvent(eventType: .hapticContinuous, parameters: [], relativeTime: 0, duration: 0.15),
                    CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0.24)]
        }
        return times.map { CHHapticEvent(eventType: .hapticTransient,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: kind == .goal ? 0.35 : 0.8),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: kind == .paused ? 0.2 : 0.7)], relativeTime: $0) }
    }
}
#endif
