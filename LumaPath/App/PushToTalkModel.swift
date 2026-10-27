import Foundation
import SwiftUI
@preconcurrency import Speech
@preconcurrency import AVFAudio
import LumaPathCommands

/// One user-started, bounded on-device utterance. No transcript persistence or automatic execution.
@MainActor final class PushToTalkModel: ObservableObject {
    @Published private(set) var status = "English on-device speech. Tap Speak, then Review speech. Typed input is always available."
    @Published private(set) var transcript = ""
    @Published private(set) var listening = false
    @Published private(set) var requesting = false
    private var token: UUID?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var limit: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var ownsAudio = false
    private var tapInstalled = false
    private let authorize: @MainActor () async -> Bool
    private let microphone: @MainActor () async -> Bool
    init(authorize: @escaping @MainActor () async -> Bool = {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }, microphone: @escaping @MainActor () async -> Bool = {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }) { self.authorize = authorize; self.microphone = microphone }
    func start() {
        cancel(); transcript = ""
        let id = UUID(); token = id; requesting = true; status = "Checking speech and microphone permission…"
        Task { [weak self] in
            guard let authorize = self?.authorize else { return }
            let authorized = await authorize()
            guard let self, self.token == id else { return }
            guard authorized else { self.fail("Speech permission was denied or restricted. Type a command instead."); return }
            let microphone = await self.microphone()
            guard self.token == id else { return }
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            if let reason = LocalSpeechAvailability.reason(speechAuthorized: authorized, microphoneAuthorized: microphone,
                onDevice: recognizer?.supportsOnDeviceRecognition == true, available: recognizer?.isAvailable == true) {
                self.fail(reason); return
            }
            guard let recognizer else { self.fail("Speech unavailable. Type a command instead."); return }
            self.begin(recognizer, id: id)
        }
    }
    private func begin(_ recognizer: SFSpeechRecognizer, id: UUID) {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true); ownsAudio = true
            let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            request.taskHint = .confirmation
            self.engine = engine; self.request = request
            let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { fail("Microphone input unavailable. Type a command instead."); return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result.map { String($0.bestTranscription.formattedString.prefix(1_001)) }
                let finished = result?.isFinal == true, failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.token == id else { return }
                    if let text { self.transcript = text }
                    if finished || failed {
                        self.cancel()
                        self.status = failed ? "Speech ended or became unavailable. Review the text or type a command." : "Speech captured. Review before confirming."
                    }
                }
            }
            engine.prepare(); try engine.start(); listening = true; requesting = false
            status = "Listening on this device, up to 15 seconds. No command runs until you review and confirm."
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.token == id else { return }
                        self?.fail("Audio route changed or speech was interrupted. Type a command or tap Speak again.")
                    }
                })
            }
            limit = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.token == id else { return }
                self.cancel(); self.status = "Listening limit reached. Review captured text or type a command."
            }
        } catch { fail("Microphone could not start. Type a command instead.") }
    }
    private func fail(_ reason: String) { cancel(); status = reason }
    func finish() -> String { let text = transcript; cancel(); return text }
    func cancel(clearTranscript: Bool = false) {
        if clearTranscript { transcript = "" }
        token = nil; requesting = false; listening = false; limit?.cancel(); limit = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        if let engine { engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0) } }; engine = nil; tapInstalled = false
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
        if ownsAudio { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); ownsAudio = false }
        status = "Microphone off. Type a command or tap Speak."
    }
}
