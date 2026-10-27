import SwiftUI
import LumaPathDomain
import LumaPathMemory
import LumaPathSensors

/// Protected historical map library. No alignment, goal output, or hazard suppression is issued here.
@MainActor final class SpatialPlacesModel: ObservableObject {
    @Published private(set) var places: [PlaceArchive] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var draft: PlaceArchive?
    @Published private(set) var scanning = false
    @Published private(set) var capturing = false
    @Published private(set) var status = "No scan is running."
    private let storage: PlaceStore?
    private let driver: ARKitDriver
    private let provider: ARKitSensorProvider
    private var task: Task<Void, Never>?
    private var scanToken = UUID()
    private let sessionID = UUID()
    private var generation: UInt64 = 0

    init(storage: PlaceStore? = nil) {
        let driver = ARKitDriver()
        self.driver = driver
        provider = ARKitSensorProvider(driver: driver, permission: CameraPermissionService())
        if let storage { self.storage = storage }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let folder = ProcessInfo.processInfo.arguments.contains("-spatial-places-testing") ? "LumaPathUITestSpatialPlaces" : "LumaPathSpatialPlaces"
            do { self.storage = try PlaceStore(directory: base.appendingPathComponent(folder, isDirectory: true)) }
            catch { self.storage = nil; self.error = "Spatial storage could not open. Existing files were preserved. Unlock the phone and reopen this screen." }
        }
        provider.onStatusChange = { [weak self] value in
            guard let self, self.scanning else { return }
            switch value.phase {
            case .running: self.status = "Scanning. Stay stationary and look around slowly. Choose Review scan when ready."
            case .preparing: self.status = "Preparing the scan. Wait for normal tracking."
            default:
                self.stopScan()
                self.status = "Scan stopped. Camera or tracking is unavailable. Start a new scan explicitly."
            }
        }
    }
    deinit { task?.cancel() }
    var canScan: Bool { provider.capabilities.worldTracking }
    var canReview: Bool { scanning && !capturing && provider.status.phase == .running }

    func reload() async {
        guard !busy, let storage else { return }
        busy = true; defer { busy = false }
        do { places = try await storage.list(); loaded = true; error = nil }
        catch { loaded = false; places = []; self.error = "Spatial scans could not be read. Files were preserved. Unlock the phone and retry; damaged or newer files need recovery before editing." }
    }
    func startScan() {
        guard loaded, canScan, !busy, !scanning else { return }
        stopScan()
        generation += 1
        let token = scanToken
        let context = CaptureContext(sessionID: sessionID, generation: generation,
            mode: provider.capabilities.preferredMode ?? .cameraOnly)
        scanning = true; error = nil; status = "Preparing the scan."
        task = Task { [weak self] in
            guard let self else { return }
            await self.provider.start(context: context)
            guard !Task.isCancelled, self.scanToken == token else { return }
        }
    }
    func reviewScan(name: String) {
        guard canReview else { return }
        capturing = true; error = nil
        let token = scanToken
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await self.driver.capturePlaceDraft(name: name,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
                guard !Task.isCancelled, self.scanToken == token else { return }
                self.stopScan()
                self.draft = draft
                self.status = "Scan stopped. Review this historical draft before saving."
            } catch {
                guard !Task.isCancelled, self.scanToken == token else { return }
                self.capturing = false
                self.error = "The scan is not ready to save. Use a name of 1–120 characters, wait for mapped tracking and more distributed features, then retry. No map was saved."
            }
        }
    }
    func stopScan() {
        scanToken = UUID(); task?.cancel(); task = nil
        scanning = false; capturing = false; provider.stop(); draft = nil
        status = "No scan is running."
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
    func saveDraft(replacing original: PlaceArchive? = nil) async -> Bool {
        guard let draft else { return false }
        let saved = await mutate { storage in
            if let original { try await storage.update(original.replacingScan(with: draft), reviewedRevision: original.revision) }
            else { try await storage.save(draft) }
        }
        if saved { self.draft = nil }
        return saved
    }
    func rename(_ place: PlaceArchive, to name: String) async -> Bool {
        await mutate { try await $0.update(place.renamed(name), reviewedRevision: place.revision) }
    }
    func rollback(_ place: PlaceArchive) async -> Bool {
        await mutate { _ = try await $0.rollback(place.id, reviewedRevision: place.revision) }
    }
    func delete(_ place: PlaceArchive) async -> Bool {
        await mutate { try await $0.delete(place.id, reviewedRevision: place.revision) }
    }
    func hasRollback(_ place: PlaceArchive) async -> Bool {
        (try? await storage?.hasRollback(place.id)) ?? false
    }
    private func mutate(_ operation: (PlaceStore) async throws -> Void) async -> Bool {
        guard loaded, !busy, let storage else { return false }
        busy = true; defer { busy = false }
        do {
            try await operation(storage)
            places = try await storage.list(); error = nil
            return true
        } catch {
            self.error = "The change could not be confirmed. Your draft remains available. Cancel and reload if this scan changed or was deleted; unlock the phone and retry if storage is unavailable."
            return false
        }
    }
}
