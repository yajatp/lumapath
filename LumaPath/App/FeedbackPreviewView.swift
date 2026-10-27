import SwiftUI
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk
import LumaPathRendering
import LumaPathFeedback

@MainActor final class FeedbackPreviewModel: ObservableObject {
    private let output = PhoneOutputSink()
    private lazy var feedback = FeedbackCoordinator(sink: output)
    private let pipeline = GeometryPipeline()
    private var context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
    private var task: Task<Void, Never>?
    private var fixtures: [GeometryFixture] = []
    private var index = 0
    private var sequence: UInt64 = 0
    @Published var speech = false { didSet { updateChannels() } }
    @Published var haptics = false { didSet { updateChannels() } }
    @Published private(set) var status = "Ready — no output playing"
    @Published private(set) var request: RendererRequest?
    @Published private(set) var fixture: GeometryFixture?
    @Published private(set) var summary = "No current synthetic observation."
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    var capabilities: OutputCapabilities { feedback.capabilities }
    var trace: [FeedbackTrace] { feedback.trace }
    var channelsText: String { speech || haptics ? "Preview channels selected" : "Visual view only; alerts muted" }
    init() {
        do { fixtures = try GeometryFixture.load() } catch { failure = "Synthetic fixtures could not load." }
        feedback.start(context: context, allowResearch: true); pipeline.start(context: context)
        feedback.onChange = { [weak self] in self?.objectWillChange.send() }
        output.onInterruption = { [weak self] in self?.stop() }
        output.onCapabilityChange = { [weak self] in self?.objectWillChange.send() }
        pipeline.ledger.onEventsAvailable = { [weak self] _ in
            guard let self else { return }; self.feedback.consume(self.pipeline.ledger)
        }
    }
    deinit { task?.cancel() }
    func preview(_ cue: CuePreview) {
        resetContext()
        let kind: FeedbackKind = switch cue {
        case .obstacle: .obstacle
        case .urgent: .urgent
        case .limitation: .limitation
        case .goal: .goal
        case .paused: .paused
        }
        let now = SystemMonotonicClock().now()
        feedback.enqueue(FeedbackItem(context: context, createdAt: now, expiresAt: now + 8, kind: kind,
            priority: 1, text: cue.example, repeatKey: "preview.\(cue.rawValue)", source: "explicitCuePreview"))
        status = "Preview: \(cue.title)"
    }
    func runFixture() {
        guard !busy, !fixtures.isEmpty else { return }
        resetContext()
        let fixture = fixtures[index % fixtures.count]; index += 1; self.fixture = fixture
        sequence += 1; let sequence = sequence, context = context, pipeline = pipeline
        busy = true; status = "Synthetic request: \(fixture.name)"
        task = Task { [weak self] in
            do {
                let depth = try fixture.image(context: context, sequence: sequence, at: SystemMonotonicClock().now())
                let snapshot = try await pipeline.process(depth)
                guard !Task.isCancelled, self?.context == context else { return }
                if let snapshot {
                    self?.request = RendererRequest(frame: snapshot.geometry.frame, geometry: snapshot.geometry.observations,
                        context: context, at: SystemMonotonicClock().now())
                    self?.summary = snapshot.events.compactMap { FeedbackCoordinator.item(for: $0, context: context)?.text }.joined(separator: " ")
                    if self?.summary.isEmpty == true { self?.summary = "No supported observation; unobserved regions remain unknown." }
                } else { self?.summary = "Synthetic computation expired before presentation." }
            } catch is CancellationError { return }
            catch { self?.failure = "Synthetic processing stopped: \(error)"; self?.stop() }
            if self?.context == context { self?.busy = false }
        }
    }
    func tick() {
        feedback.consume(pipeline.ledger)
        if let request, !request.frame.envelope.isCurrent(in: context, at: SystemMonotonicClock().now()) {
            self.request = nil; summary = "No current synthetic observation."
        }
    }
    func stop() {
        task?.cancel(); task = nil; busy = false; pipeline.stop(); feedback.cancel(reason: "previewStopped")
        output.shutdown(); request = nil; summary = "No current synthetic observation."; status = "Preview stopped"
    }
    private func resetContext() {
        stop(); context = CaptureContext(sessionID: context.sessionID, generation: context.generation + 1, mode: .demoReplay)
        feedback.start(context: context, allowResearch: true); pipeline.start(context: context)
    }
    private func updateChannels() { feedback.setChannels(OutputChannels(speech: speech, haptics: haptics)) }
}

struct FeedbackPreviewView: View {
    @StateObject private var model = FeedbackPreviewModel()
    @State private var cue: CuePreview = .obstacle
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Stationary cue preview — no live sensing").font(.headline)
                Text("Choose a channel, then play a cue. Patterns are proposed; comprehension and physical latency have not been validated.")
                Toggle("Preview phone speech", isOn: $model.speech).disabled(!model.capabilities.speech && !model.speech)
                Toggle("Preview phone haptics", isOn: $model.haptics).disabled(!model.capabilities.haptics && !model.haptics)
                if let reason = model.capabilities.reason { Text(reason).accessibilityIdentifier("feedback.capability") }
                Picker("Cue meaning", selection: $cue) {
                    ForEach(CuePreview.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(cue.example).accessibilityIdentifier("feedback.example")
                Text("Pattern: \(cue.pattern)")
                Button("Play selected cue") { model.preview(cue) }
                    .disabled(!model.speech && !model.haptics).frame(minHeight: 56).buttonStyle(.borderedProminent)
                Text(model.status).accessibilityIdentifier("feedback.previewStatus")
                DisclosureGroup("Synthetic obstacle-to-output demo") {
                    Text("Analytic depth diagram — simulated data. Outlines and scene cues expire after 300 ms; speech may be cut short. The diagram remains a historical reference.")
                    Canvas { canvas, size in
                        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                        for patch in model.fixture?.patches ?? [] {
                            let rect = CGRect(x: Double(patch.x)/64 * size.width, y: Double(patch.y)/48 * size.height,
                                width: Double(patch.width)/64 * size.width, height: Double(patch.height)/48 * size.height)
                            canvas.fill(Path(rect), with: .color(.gray))
                        }
                    }.aspectRatio(4/3, contentMode: .fit).overlay {
                        if let request = model.request {
                            FrameOverlayView(request: request, displayedFrame: request.frame,
                                context: CaptureContext(sessionID: request.frame.envelope.frameID.sessionID, generation: request.frame.envelope.frameID.generation, mode: .demoReplay),
                                orientation: request.frame.orientation, viewport: request.frame.viewportSize)
                        }
                    }.accessibilityLabel("Historical analytic depth patches; active yellow outlines require current synthetic evidence.")
                    Text(model.summary)
                    Button("Run next obstacle fixture") { model.runFixture() }.disabled(model.busy).frame(minHeight: 56)
                }
                DisclosureGroup("Output timing trace") {
                    Text("Local monotonic time and disposition; at most 128 rows. Nothing is saved or uploaded.")
                    ForEach(Array(model.trace.suffix(8).enumerated()), id: \.offset) { _, entry in
                        Text(String(format: "%.3f · %@", entry.time, entry.action)).modifier(LumaMetadataText())
                    }
                }
                if let failure = model.failure { Text(failure) }
            }.padding()
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Phone cue preview").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack { Text(model.channelsText); Button("Stop preview") { model.stop() }.frame(minHeight: 56).buttonStyle(.bordered) }
                .padding(8).frame(maxWidth: .infinity).background(LumaTheme.surface)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                model.tick()
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
    }
}
