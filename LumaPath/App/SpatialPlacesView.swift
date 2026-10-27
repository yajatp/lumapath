import SwiftUI
import LumaPathMemory

struct SpatialPlacesView: View {
    @EnvironmentObject private var model: SpatialPlacesModel
    var body: some View {
        List {
            Section {
                Text("Research spatial scans").font(.title2)
                Text("Maps stay on this device. A saved scan is historical and does not establish your current location. Matching and remembered guidance are not enabled.")
                Text("Scan only during a protected stationary trial. Use manual place notes when world tracking is unavailable.")
                if let error = model.error {
                    Text(error).accessibilityIdentifier("spatial.error")
                    Button("Reload spatial scans") { Task { await model.reload() } }.disabled(model.busy)
                }
                if !model.loaded && model.error == nil { ProgressView("Loading spatial scans") }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Saved scans") {
                if model.loaded && model.places.isEmpty {
                    Text("No spatial scans saved.").accessibilityIdentifier("spatial.empty")
                }
                ForEach(model.places, id: \.id) { place in
                    NavigationLink {
                        SpatialPlaceEditor(original: place)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name)
                            Text("Historical scan · alignment required").modifier(LumaMetadataText())
                        }.padding(.vertical, 8)
                    }
                }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section {
                NavigationLink("Scan a place — Research") { SpatialScanView(original: nil) }
                    .disabled(!model.loaded || model.busy || !model.canScan)
                    .accessibilityIdentifier("spatial.scan")
                if !model.canScan {
                    Text("Spatial scanning requires supported AR world tracking on a physical iPhone. Manual place notes remain available.")
                        .accessibilityIdentifier("spatial.unsupported")
                }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Spatial scans").navigationBarTitleDisplayMode(.inline)
            .task { await model.reload() }
    }
}

private struct SpatialPlaceEditor: View {
    @EnvironmentObject private var model: SpatialPlacesModel
    @Environment(\.dismiss) private var dismiss
    let original: PlaceArchive
    @State private var name: String
    @State private var rollbackAvailable = false
    @State private var confirmation: Action?
    private enum Action: String, Identifiable { case delete, rollback; var id: String { rawValue } }
    init(original: PlaceArchive) { self.original = original; _name = State(initialValue: original.name) }
    var body: some View {
        Form {
            Section("Historical scan") {
                Text("This saved map is not a current observation. It cannot suppress live obstacles or start remembered guidance.")
                TextField("Scan name", text: $name).accessibilityIdentifier("spatial.name")
                Text("Saved: \(original.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("\(original.landmarks.count) saved features. These are not user-confirmed landmark labels.")
                Text(original.qualitySummary)
                if let error = model.error { Text(error).accessibilityIdentifier("spatial.editError") }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section {
                Button("Save scan name") { Task { if await model.rename(original, to: name) { dismiss() } } }
                    .disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
                NavigationLink("Rescan and review replacement") { SpatialScanView(original: original) }
                    .disabled(!model.canScan || model.busy)
                Text("A replacement uses a new coordinate frame. Old landmarks are not copied into it. One previous revision is kept for rollback.")
                if rollbackAvailable {
                    Button("Review rollback") { confirmation = .rollback }.disabled(model.busy)
                }
                Button("Delete spatial scan", role: .destructive) { confirmation = .delete }.disabled(model.busy)
                Button("Cancel") { dismiss() }.disabled(model.busy)
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline).frame(minHeight: 56)
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Review spatial scan").navigationBarTitleDisplayMode(.inline)
            .task { rollbackAvailable = await model.hasRollback(original) }
            .onChange(of: model.places.first(where: { $0.id == original.id })?.revision) { _, revision in
                if revision != original.revision { dismiss() }
            }
            .confirmationDialog(confirmation == .delete ? "Delete this scan, its map and rollback revision?" : "Restore the previous saved revision?",
                isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                titleVisibility: .visible) {
                    if confirmation == .delete {
                        Button("Delete scan and history", role: .destructive) { Task { if await model.delete(original) { dismiss() } } }
                    } else {
                        Button("Restore previous revision") { Task { if await model.rollback(original) { dismiss() } } }
                    }
                    Button("Keep current scan", role: .cancel) { confirmation = nil }
                }
    }
}

private struct SpatialScanView: View {
    @EnvironmentObject private var model: SpatialPlacesModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let original: PlaceArchive?
    @State private var name = ""
    var body: some View {
        GeometryReader { viewport in
            Form {
                Section("Protected stationary trial") {
                    Text("Research — unvalidated. Stay stationary with a sighted helper. Look around slowly; do not walk following this scan. No guidance or alerts are played.")
                    Text("Saving stores a protected AR world map and unlabeled feature positions on this device. Nothing is uploaded.")
                    TextField("Scan name", text: $name).disabled(model.scanning || model.draft != nil)
                        .accessibilityIdentifier("spatial.scanName")
                    Text(model.status).accessibilityIdentifier("spatial.scanStatus")
                    if let error = model.error { Text(error) }
                    if !model.canScan { Text("AR world tracking is unavailable. Return to use manual notes.") }
                }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
                if let draft = model.draft {
                    Section("Review before saving") {
                        Text("Name: \(draft.name)")
                        Text("\(draft.landmarks.count) distributed features. No labels or current alignment have been confirmed.")
                        Text(original == nil ? "This creates a new historical scan." : "This replaces the selected scan’s map and coordinates. The previous revision remains available for one rollback.")
                        Button(original == nil ? "Save spatial scan" : "Confirm scan replacement") {
                            Task { if await model.saveDraft(replacing: original) { dismiss() } }
                        }.disabled(model.busy)
                        Button("Discard scan draft", role: .destructive) { model.stopScan() }.disabled(model.busy)
                    }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
                } else {
                    Section {
                        Button("Start stationary scan") { model.updateViewport(size: viewport.size); model.startScan() }
                            .disabled(!model.canScan || model.scanning || model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
                        Button(model.capturing ? "Preparing draft…" : "Review scan") { model.reviewScan(name: name) }
                            .disabled(!model.canReview)
                        Button("Stop scan") { model.stopScan() }.disabled(!model.scanning)
                    }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
                }
                Section { Button("Cancel") { model.stopScan(); dismiss() }.disabled(model.busy) }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            }.buttonStyle(.bordered).controlSize(.large)
                .onChange(of: viewport.size) { _, size in model.updateViewport(size: size) }
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle(original == nil ? "Scan a place" : "Rescan place")
            .onAppear { name = original?.name ?? "" }
            .onDisappear { model.stopScan() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.stopScan() } }
    }
}
