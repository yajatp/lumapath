import SwiftUI
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk

@MainActor private final class GeometryResearchModel: ObservableObject {
    @Published var name = "Ready"
    @Published var result: GeometrySnapshot?
    @Published var pendingCount = 0
    @Published var failure: String?
    @Published var busy = false
    private let pipeline = GeometryPipeline(configuration: GeometryConfiguration(calibratedCameraHeight: 1),advancedResearch: true)
    private var context = CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay)
    private var active = true
    private var runID = UUID()
    private var sequence: UInt64 = 0
    private var index = 0
    private var task: Task<Void,Never>?
    private var scenarios: [GeometryFixture] = []
    init() {
        do { scenarios = try GeometryFixture.load(); pipeline.start(context: context) }
        catch { failure = String(describing: error) }
        pipeline.ledger.onEventsAvailable = { [weak self] _ in self?.refreshLedger() }
    }
    deinit { task?.cancel() }
    func next() {
        guard !busy, !scenarios.isEmpty else { return }
        if !active {
            context = CaptureContext(sessionID: context.sessionID,generation: context.generation+1,mode: .demoReplay)
            pipeline.start(context: context); active = true
        }
        let scenario = scenarios[index % scenarios.count]; index += 1
        busy = true; sequence += 1
        let sequence = sequence, pipeline = pipeline, context = context
        let token = UUID(); runID = token
        name = scenario.name
        task = Task { [weak self] in
            defer { if self?.runID == token { self?.busy = false } }
            do {
                let depth = try scenario.image(context: context,sequence: sequence,at: SystemMonotonicClock().now())
                let snapshot = try await pipeline.process(depth)
                if !Task.isCancelled, self?.runID == token { self?.result = snapshot }
            } catch is CancellationError { return }
            catch { if self?.runID == token { self?.failure = String(describing: error) } }
            self?.refreshLedger()
        }
    }
    func refreshLedger() { pendingCount = pipeline.ledger.pending(at: SystemMonotonicClock().now()).count }
    func acknowledge() {
        let now = SystemMonotonicClock().now()
        for event in pipeline.ledger.pending(at: now) { pipeline.ledger.acknowledge(event.id,context: context,at: now) }
        refreshLedger()
    }
    func stop() { runID = UUID(); task?.cancel(); task = nil; pipeline.stop(); active = false; pendingCount = 0; busy = false; result = nil }
}

struct GeometryResearchView: View {
    @StateObject private var model = GeometryResearchModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                Text("Research — synthetic depth").font(.title2).bold()
                Text("Unvalidated geometry. These are analytic fixtures, not camera measurements. No guidance or alerts are provided.")
                LabeledContent("Fixture") { Text(model.name).accessibilityIdentifier("geometry.fixture") }
                if let result = model.result {
                    Text("Last fixture result — historical").font(.headline)
                    LabeledContent("Components") { Text("\(result.geometry.observations.count)").accessibilityIdentifier("geometry.components") }
                    LabeledContent("Ground", value: result.geometry.ground.status.rawValue)
                    ForEach(result.events,id: \.id) { event in
                        Text("\(event.messageKey) · \(event.urgency.rawValue)")
                    }
                    Text(result.geometry.quality.reasons.joined(separator: ", ")).modifier(LumaSecondaryText())
                    DisclosureGroup("Historical advanced evidence and uncertainty") { AdvancedEvidenceView(result: result.geometry.advanced) }
                }
                LabeledContent("Unacknowledged, unexpired events",value: "\(model.pendingCount)")
                if let failure = model.failure { Text(failure) }
            }.padding().frame(maxWidth: .infinity,alignment: .leading)
        }
        .scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Geometry research").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button("Next depth fixture") { model.next() }.disabled(model.busy)
                Button("Acknowledge pending research events") { model.acknowledge() }.disabled(model.pendingCount == 0)
            }.buttonStyle(.bordered).controlSize(.large).padding().frame(maxWidth: .infinity).background(LumaTheme.surface)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                model.refreshLedger()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .onDisappear { model.stop() }
    }
}
