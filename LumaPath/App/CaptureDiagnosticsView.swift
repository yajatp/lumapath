import SwiftUI
import LumaPathDomain
import LumaPathSensors
import LumaPathRisk

@MainActor private final class CaptureDiagnosticsModel: ObservableObject {
    let provider = ARKitSensorProvider()
    @Published var status = CaptureStatus(.stopped)
    @Published var frame: FrameDescriptor?
    @Published var mode: SourceMode?
    @Published var geometry: GeometrySnapshot?
    @Published var researchFailure: String?
    @Published var researchEnabled = false {
        didSet { invalidateGeometry() }
    }
    private let pipeline = GeometryPipeline(advancedResearch: true)
    private var geometryContext: CaptureContext?
    private var task: Task<Void, Never>?
    private let sessionID = UUID()
    private var generation: UInt64 = 0

    init() {
        provider.onStatusChange = { [weak self] status in
            self?.status = status
            if status.phase != .running { self?.frame = nil; self?.invalidateGeometry() }
        }
        provider.onFreshnessLoss = { [weak self] _ in self?.frame = nil; self?.invalidateGeometry() }
    }
    deinit { task?.cancel() }
    var capabilities: CapabilitySet { provider.capabilities }
    var isStartingOrRunning: Bool { provider.activeContext != nil }

    func start() {
        guard let mode = capabilities.preferredMode else { return }
        task?.cancel()
        generation += 1
        self.mode = mode
        let context = CaptureContext(sessionID: sessionID, generation: generation, mode: mode)
        let provider = provider
        task = Task { [weak self] in
            defer { if provider.activeContext == context { provider.stop() } }
            await provider.start(context: context)
            guard !Task.isCancelled else { return }
            for await frame in provider.frames {
                guard !Task.isCancelled else { return }
                guard provider.activeContext == context,
                      frame.envelope.isCurrent(in: context, at: SystemMonotonicClock().now()) else { continue }
                // Exercise the renderer's actual lease boundary; no image processing or rendering is performed here.
                let lease = provider.lease(for: frame)
                if lease.withReadOnlyBuffers({ _ in }) { self?.frame = frame }
                guard self?.researchEnabled == true else { continue }
                do {
                    if self?.geometryContext != context {
                        self?.pipeline.start(context: context); self?.geometryContext = context
                    }
                    if let depth = try lease.copyDepthImage(), let pipeline = self?.pipeline {
                        // Image diagnostics may fail independently; preserve supported depth geometry.
                        let image = try? lease.copyLumaImage()
                        let result = try await pipeline.process(depth,image: image)
                        if !Task.isCancelled, self?.researchEnabled == true, provider.activeContext == context {
                            self?.geometry = result
                            if result != nil { self?.researchFailure = nil }
                        }
                    }
                } catch is CancellationError { return }
                catch { self?.geometry = nil; self?.researchFailure = String(describing: error) }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; provider.stop(); frame = nil; invalidateGeometry() }
    private func invalidateGeometry() {
        pipeline.stop(); geometryContext = nil; geometry = nil; researchFailure = nil
    }

    func updateViewport(size: CGSize) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let orientation: ImageOrientation
        switch scene.interfaceOrientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: return
        }
        provider.updateViewport(CaptureViewport(orientation: orientation,
            size: PixelSize(width: Int((size.width * scene.screen.scale).rounded()), height: Int((size.height * scene.screen.scale).rounded()))))
    }
}

/// A2 diagnostics only. B2 supplies the image renderer and the exact rendering viewport.
struct CaptureDiagnosticsView: View {
    @StateObject private var model = CaptureDiagnosticsModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Capture metadata only").font(.title2).bold()
                    Text("Open Home → Live view for image enhancement. Research geometry is unvalidated and provides no live guidance.")
                    if model.capabilities.preferredMode == nil {
                        Text("World tracking is unavailable on this device. Return to try the labeled demo.")
                            .accessibilityIdentifier("capture.unsupported")
                    }
                    LabeledContent("Camera permission", value: String(describing: model.capabilities.cameraPermission))
                    LabeledContent("Depth support", value: model.capabilities.sceneDepth || model.capabilities.smoothedSceneDepth ? "Available" : "Unavailable")
                    LabeledContent("Capture state", value: model.status.phase.rawValue)
                    if let mode = model.mode {
                        Text(mode == .liveDepth ? "Live depth capture" : "Camera-only capture")
                    }
                    Toggle("Analyze depth in Research", isOn: $model.researchEnabled)
                    if model.researchEnabled {
                        Text("Research — unvalidated geometry").font(.headline)
                        Text("Ground shape stays uncertain without a measured camera-height calibration. No alerts are played.")
                        if let geometry = model.geometry {
                            LabeledContent("Research components", value: "\(geometry.geometry.observations.count)")
                            LabeledContent("Ground evidence", value: geometry.geometry.ground.status.rawValue)
                            Text(geometry.geometry.quality.reasons.joined(separator: ", "))
                        }
                        if let failure = model.researchFailure { Text(failure) }
                    }
                    if let reason = model.status.reason { Text(reason).modifier(LumaSecondaryText()) }
                    if let frame = model.frame {
                        LabeledContent("Frame", value: "\(frame.envelope.frameID.sequence)")
                        LabeledContent("Generation", value: "\(frame.envelope.frameID.generation)")
                        LabeledContent("Image", value: "\(frame.imageSize.width) × \(frame.imageSize.height)")
                        LabeledContent("Depth kind", value: frame.depthKind.rawValue)
                        LabeledContent("Confidence map", value: frame.confidenceSize == nil ? "Unknown" : "Present")
                        LabeledContent("Orientation", value: frame.orientation.rawValue)
                        LabeledContent("Tracking", value: frame.tracking.rawValue)
                    }
                    if model.capabilities.cameraPermission == .denied || model.capabilities.cameraPermission == .restricted {
                        Text("Camera permission is unavailable. Review the app’s camera permission in Settings.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onAppear { model.updateViewport(size: geometry.size) }
            .onChange(of: geometry.size) { _, size in model.updateViewport(size: size) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.stop() }
                else { model.updateViewport(size: geometry.size) }
            }
        }
        .scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Capture diagnostics").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button("Start capture") { model.start() }
                    .disabled(model.capabilities.preferredMode == nil || model.isStartingOrRunning)
                Button("Stop capture") { model.stop() }
                    .disabled(!model.isStartingOrRunning)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .padding().frame(maxWidth: .infinity).background(LumaTheme.surface)
        }
        .onDisappear { model.stop() }
    }
}
