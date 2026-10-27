import SwiftUI
import LumaPathDomain
import LumaPathFeedback
import LumaPathAccessories

struct MountInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up while stationary").font(.headline)
            Text("Use your usual mobility aid and a protected trial area. Use a comfortable existing handheld or chest support; no purchase is required. Keep the rear camera unobstructed, facing the intended view. Check coverage with a sighted helper if needed.")
            HStack(alignment: .top, spacing: 20) {
                VStack { Image(systemName: "iphone"); Image(systemName: "arrow.up"); Text("Phone forward") }
                VStack { Image(systemName: "person.crop.circle"); Image(systemName: "arrow.turn.up.right"); Text("Head direction") }
                VStack { Image(systemName: "figure.walk"); Image(systemName: "arrow.right"); Text("Walking direction") }
            }.font(.title3).accessibilityElement(children: .ignore)
                .accessibilityLabel("Phone forward, head direction, and walking direction are three different references. Only phone forward is supported.")
            Text("In Live view, start Research capture, check the three setup boxes, and confirm phone-forward alignment. Turning more than 25 degrees, losing tracking, pausing, or changing headphones requires rechecking. This provisional limit is not a validated mount tolerance.")
            Text("Spatial cues mean left, ahead, or right of the phone. Head direction is unavailable. If alignment or stereo headphones are unavailable, use enabled phone speech/haptics and text. No distance is encoded by loudness. Keep environmental sounds audible and choose a comfortable system volume.")
        }
    }
}

@MainActor final class AccessoryPreviewModel: ObservableObject {
    let output = AccessoryOutputSink()
    private lazy var feedback = FeedbackCoordinator(sink: output)
    private let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
    @Published var speech = false { didSet { update() } }
    @Published var haptics = false { didSet { update() } }
    @Published var spatial = false { didSet { update() } }
    @Published var watch = false { didSet { update(); if watch { output.watch.start(context: context) } else { output.watch.stop() } } }
    @Published var referenceConfirmed = false { didSet { output.spatial.calibrated = referenceConfirmed; update() } }
    @Published var headphonesConfirmed = false { didSet { output.spatial.headphonesConfirmed = headphonesConfirmed; update() } }
    @Published private(set) var status = "No preview playing."
    var capabilities: OutputCapabilities { output.capabilities }
    init() {
        feedback.start(context: context, allowResearch: true)
        output.onInterruption = { [weak self] in self?.stop() }
        output.watch.onPause = { [weak self] in self?.stop() }
        output.onAlignmentLost = { [weak self] in self?.referenceConfirmed = false; self?.headphonesConfirmed = false }
        output.onCapabilityChange = { [weak self] in self?.objectWillChange.send() }
    }
    func play(_ family: AdvancedHazardFamily, bearing: Double) {
        let meanings: [AdvancedHazardFamily: String] = [.overhead: "overhead obstacle", .narrowPassage: "narrow passage",
            .stepUp: "step up", .stepDown: "step down", .stairs: "stairs", .movingObstacle: "moving obstacle"]
        let direction = bearing < 0 ? "left of the phone" : bearing > 0 ? "right of the phone" : "ahead of the phone"
        let now = SystemMonotonicClock().now()
        feedback.invalidateScene(reason: "newExplicitPreview")
        feedback.enqueue(FeedbackItem(context: context, createdAt: now, expiresAt: now+8, kind: .obstacle, priority: 3,
            text: "Preview. Possible \(meanings[family] ?? "obstacle") \(direction). Research estimate; uncertain.",
            repeatKey: "preview.\(family.rawValue)", source: "explicitCuePreview", bearingRadians: bearing))
        status = "Preview: \(meanings[family] ?? "obstacle") \(direction)."
    }
    func tick() { feedback.tick() }
    private func update() { feedback.setChannels(OutputChannels(speech: speech, haptics: haptics, spatial: spatial && referenceConfirmed, watch: watch)) }
    func stop() {
        feedback.cancel(reason: "previewStopped"); output.shutdown()
        watch = false; referenceConfirmed = false; headphonesConfirmed = false; status = "Preview stopped."
        feedback.start(context: context, allowResearch: true)
    }
}

struct AccessoriesView: View {
    @StateObject private var model = AccessoryPreviewModel()
    @State private var family = AdvancedHazardFamily.overhead
    @State private var bearing = 0.0
    @AppStorage("mount.mode") private var mount = MountMode.handheld.rawValue
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Stationary setup and preview — no live sensing").font(.headline)
                MountInstructions()
                Picker("Preferred mount", selection: $mount) {
                    Text("Handheld").tag(MountMode.handheld.rawValue)
                    Text("Chest mounted").tag(MountMode.chestMounted.rawValue)
                }.accessibilityIdentifier("accessory.mount")
                Text("The mount preference is saved locally. This preview does not calibrate a live session.")
                Toggle("Preview phone speech", isOn: $model.speech).disabled(!model.capabilities.speech)
                Toggle("Preview phone haptics", isOn: $model.haptics).disabled(!model.capabilities.haptics)
                Toggle("I am stationary and understand phone-relative preview", isOn: $model.referenceConfirmed)
                Toggle("Stereo headphones are worn; output is not a speaker", isOn: $model.headphonesConfirmed)
                Toggle("Preview spatial earcon", isOn: $model.spatial).disabled(!model.referenceConfirmed)
                Toggle("Preview on reachable watch", isOn: $model.watch)
                Text(model.output.watch.status).accessibilityIdentifier("accessory.watchStatus")
                Text("Open the watch app, enable Research cues, and leave it in the foreground. Each live cue needs a fresh handshake and receipt before expiry. Disconnects discard cues; there is no replay backlog. Pause both requests phone pause; only a received acknowledgement confirms it.")
                if let reason = model.capabilities.reason { Text(reason) }
                Picker("Hazard family", selection: $family) {
                    ForEach(AdvancedHazardFamily.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Phone-relative direction", selection: $bearing) {
                    Text("Left").tag(-Double.pi/4); Text("Ahead").tag(0.0); Text("Right").tag(Double.pi/4)
                }
                Button("Play accessory preview") { model.play(family, bearing: bearing) }
                    .disabled(!model.speech && !model.haptics && !(model.spatial && model.referenceConfirmed) && !model.watch)
                    .frame(minHeight: 56).buttonStyle(.borderedProminent)
                Text(model.status).accessibilityIdentifier("accessory.status")
                Text("Phone preview may last up to 8 seconds. The spatial earcon lasts 120 ms; watch transport keeps a 300 ms deadline. Acknowledgement confirms software acceptance, not a felt tap. Physical watch, route-change, mount comfort and comprehension trials are pending.")
            }.padding()
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Mount and accessories").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Stop accessory preview") { model.stop() }.accessibilityIdentifier("accessory.stop")
                .frame(maxWidth: .infinity, minHeight: 56).buttonStyle(.bordered).padding(8).background(LumaTheme.surface)
        }
        .onDisappear { model.stop() }
        .onChange(of: phase) { _, value in if value != .active { model.stop() } }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                model.tick()
            }
        }
    }
}


/// Display-only evidence. Never used to schedule, suppress, or renew an event.
struct AdvancedEvidenceView: View {
    let result: AdvancedGeometryResult?
    private func number(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "unknown / withheld" }
        return String(format: "%.2f %@", value, unit)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced geometry configuration \(AdvancedConfiguration.current.configurationVersion). Estimates are unvalidated; no fit or traversal guarantee.")
            ForEach(result?.activations ?? FeatureActivation.researchOnly, id: \.family) { activation in
                Text("\(activation.family.rawValue): \(activation.researchAvailable ? "Research only" : "unavailable"). Ordinary guidance unavailable.")
            }
            if let result {
                if result.candidates.isEmpty { Text("No supported advanced candidate. Unknown space remains unknown.") }
                ForEach(result.candidates, id: \.id) { candidate in
                    VStack(alignment: .leading) {
                        Text("Possible \(candidate.family.rawValue)").font(.headline)
                        Text("Range estimate: \(number(candidate.rangeMeters, unit: "m")); producer uncertainty: ±\(number(candidate.uncertaintyMeters, unit: "m")).")
                        if candidate.family == .narrowPassage {
                            Text("Measured width: \(number(candidate.measuredWidth, unit: "m")). This does not establish that you will fit.")
                        }
                        if [.stepUp, .stepDown, .stairs].contains(candidate.family) {
                            Text("Measured height change: \(number(candidate.heightChange, unit: "m")). No traversal instruction.")
                        }
                        Text("Encounter estimate: \(number(candidate.encounterTime, unit: "s")).")
                        Text("Evidence reasons: \(candidate.reasons.joined(separator: ", "))")
                    }
                }
                ForEach(result.tracks, id: \.id) { track in
                    Text("Motion residual: \(number(track.positionResidual, unit: "m")); velocity uncertainty: \(number(track.velocityUncertainty, unit: "m/s")); encounter estimate: \(number(track.encounterTime, unit: "s")). \(track.reasons.joined(separator: ", "))")
                }
                Text("Coverage/association reasons: \(result.reasons.joined(separator: ", "))")
            } else { Text("No current advanced evidence.") }
        }
    }
}
