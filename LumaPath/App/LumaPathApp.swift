import SwiftUI
import LumaPathDomain
import LumaPathPersonalization

@main
struct LumaPathApp: App {
    @StateObject private var interfaceMode = InterfaceMode()
    @StateObject private var presentation = PresentationSettings.forApp()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var places = ManualPlacesStore()
    @StateObject private var spatialPlaces = SpatialPlacesModel()
    var body: some Scene { WindowGroup { LumaPathRootView(store: ShellStore()).id(interfaceMode.developer).modifier(LumaAppTheme()).preferredColorScheme(presentation.appearance.scheme).environmentObject(interfaceMode).environmentObject(presentation).environmentObject(profiles).environmentObject(places).environmentObject(spatialPlaces) } }
}

/// Explicit interface selection. Visibility never activates a Research capability or audio session.
@MainActor final class InterfaceMode: ObservableObject {
    @Published private(set) var developer = false
    func setDeveloper(_ enabled: Bool) {
        guard developer != enabled else { return }
        developer = enabled
        UIAccessibility.post(notification: .announcement, argument: enabled ? "Developer interface" : "Standard interface")
    }
}

/// One presentation consumer across tab changes. No native buffers or output queue.
@MainActor final class ShellStore: ObservableObject {
    @Published private(set) var state = ShellState()
    @Published private(set) var failure: String?
    @Published private(set) var stepName = "Ready"
    @Published private(set) var connectionRevision = 0
    let availability: any ShellAvailabilityProviding
    private let clock: any MonotonicClock
    private let makeService: @MainActor () throws -> any ShellSessionService
    private var service: (any ShellSessionService)?

    init(clock: any MonotonicClock = SystemMonotonicClock(),
         availability: any ShellAvailabilityProviding = B1FixtureServices(),
         makeService: (@MainActor () throws -> any ShellSessionService)? = nil) {
        self.clock = clock
        self.availability = availability
        self.makeService = makeService ?? { try ReplayShellService(clock: clock) }
    }
    func connect() async {
        failure = nil
        do {
            let session = try makeService()
            service = session
            synchronize(session)
            defer { session.perform(.pause) }
            for await update in session.snapshots {
                guard !Task.isCancelled else { return }
                state.receive(update, at: clock.now())
                stepName = session.stepName
            }
        } catch {
            service = nil
            failure = "The demo could not load. Retry to reload the bundled fixture."
        }
    }
    func retry() { connectionRevision += 1 }
    func select(_ tab: AppTab) { state.tab = tab }
    func apply(_ preferences: PresentationPreferences) { state.apply(preferences) }
    func send(_ command: ShellCommand) {
        guard let service, state.allows(command) else { return }
        service.perform(command)
        synchronize(service)
    }
    func tick() { service?.expire(); state.expire(at: clock.now()) }
    private func synchronize(_ service: any ShellSessionService) {
        // Bind before consuming buffered values, especially after pause/end/resume.
        state.bind(to: service.snapshot.context)
        state.receive(service.snapshot, at: clock.now())
        stepName = service.stepName
    }
}

/// M0 composition API. The live view owns one A2 provider; static previews own no camera.
@MainActor struct LumaPathRootView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var interfaceMode: InterfaceMode
    @EnvironmentObject private var presentation: PresentationSettings
    @State private var welcome = false
    @State private var editPresentation = false
    @StateObject private var store: ShellStore
    @State private var showHelp = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    init(store: ShellStore) { _store = StateObject(wrappedValue: store) }

    var body: some View {
        TabView(selection: Binding(get: { store.state.tab }, set: { store.select($0) })) {
            NavigationStack { home }.safeAreaInset(edge: .bottom) { sessionFooter }
                .tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
            NavigationStack {
                FindView(profile: profiles.active).id(profiles.active?.updatedAt)
                    .onAppear { store.send(.end) }
                    .toolbar { NavigationLink("Saved places") { places } }
            }
                .tabItem { Label("Find", systemImage: "magnifyingglass") }.tag(AppTab.find)
            NavigationStack { featurePage(.routes, title: "Routes") }.safeAreaInset(edge: .bottom) { sessionFooter }
                .tabItem { Label("Routes", systemImage: "map") }.tag(AppTab.routes)
            NavigationStack { featurePage(.community, title: "Community") }.safeAreaInset(edge: .bottom) { sessionFooter }
                .tabItem { Label("Community", systemImage: "person.2") }.tag(AppTab.community)
        }
        .sheet(isPresented: $showHelp) { help }
        .sheet(isPresented: $editPresentation) {
            PresentationSettingsView(style: presentation.style, appearance: presentation.appearance)
        }
        .fullScreenCover(isPresented: $welcome) { WelcomeView() }
        .onAppear {
            if !presentation.welcomed && !ProcessInfo.processInfo.arguments.contains("-skip-welcome") { welcome = true }
        }
        .task(id: store.connectionRevision) { await store.connect() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                store.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.send(.pause) }
        }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if interfaceMode.developer {
                    Text("Developer interface")
                        .font(.headline).accessibilityIdentifier("interface.developer")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose what you’d like to do.").foregroundStyle(LumaTheme.secondaryInk)
                    NavigationLink { LiveCameraView(profile: profiles.active).onAppear { store.send(.end) } } label: {
                        Label("Start live view", systemImage: "camera")
                    }.buttonStyle(ShellButtonStyle(prominent: true))
                    Text("Camera tools and image adjustments. Research sensing is unvalidated; no walking guidance.")
                        .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                    Button { store.select(.find) } label: {
                        ShellNavigationLabel("Find something", subtitle: "Type or speak a command, then review it", systemImage: "magnifyingglass")
                    }.buttonStyle(.plain)
                    NavigationLink { places } label: {
                        ShellNavigationLabel("Saved places", subtitle: "Place notes and historical spatial scans", systemImage: "mappin.and.ellipse")
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button("Start demo") { store.send(.startDemo) }
                        .disabled(!store.state.allows(.startDemo)).buttonStyle(ShellButtonStyle())
                    Text("Explore a sample scene without permissions. Simulated data; alerts muted.")
                        .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                    if let failure = store.failure {
                        LumaNotice(title: "Demo unavailable", detail: failure).accessibilityIdentifier("demo.failure")
                        Button("Retry demo") { store.retry() }.buttonStyle(ShellButtonStyle())
                    }
                }
                if store.state.snapshot?.lifecycle != .idle, store.state.snapshot != nil {
                    ShellCard {
                        sessionSummary
                        if store.state.isSessionOpen {
                            Button("Next fixture") { store.send(.nextFixture) }
                                .disabled(!store.state.allows(.nextFixture)).buttonStyle(ShellButtonStyle())
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    ShellSectionHeading("Make it yours", subtitle: nil)
                    Text("Active profile: \(profiles.active?.name ?? "Neutral defaults")")
                        .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk).accessibilityIdentifier("home.profile")
                    InteractionShortcut()
                    ShellCard {
                        NavigationLink { ProfilesView().onAppear { store.send(.end) } } label: {
                            ShellNavigationLabel("Profiles", subtitle: "Choose visual and feedback preferences", systemImage: "person.crop.circle")
                        }
                        Divider()
                        NavigationLink { EnhancementPreviewView() } label: {
                            ShellNavigationLabel("Enhancement preview", subtitle: "Try adjustments on a sample image", systemImage: "slider.horizontal.3")
                        }
                        Divider()
                        NavigationLink { settings } label: {
                            ShellNavigationLabel("Settings", subtitle: "Appearance, devices, privacy and Research", systemImage: "gearshape")
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("LumaPath").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    LumaBrandSignature(compact: true)
                }
            }
    }
    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = store.state.snapshot {
                LabeledContent("Session") { Text(snapshot.lifecycle.rawValue).accessibilityIdentifier("session.lifecycle") }
                LabeledContent("Sensing") {
                    Text(snapshot.lifecycle == .paused ? "paused" : snapshot.quality.state.rawValue)
                        .accessibilityIdentifier("sensing.quality")
                }
                LabeledContent("Fixture") { Text(store.stepName).accessibilityIdentifier("fixture.name") }
                if snapshot.lifecycle == .paused {
                    Text("Guidance paused. Resume requests a fresh fixture.")
                } else if snapshot.lifecycle == .ended {
                    Text("Demo ended. No current observations.")
                } else if snapshot.quality.state == .unavailable {
                    Text("Current scene information is unavailable. Next fixture supplies a fresh synthetic sample.")
                } else if snapshot.quality.state == .limited {
                    Text("Simulated depth coverage is reduced. Unobserved regions remain unknown.")
                }
                if !snapshot.events.isEmpty {
                    Text("Simulated obstacle ahead at 2 meters").font(.title2.weight(.semibold))
                }
            }
            NavigationLink("Sensing details") { sensingDetails }.buttonStyle(ShellButtonStyle())
            SyntheticReferenceView()
        }
    }
    private var sensingDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Demo — simulated data").font(.headline)
                Text("The static picture is a calibration reference. Scene observations expire after 300 milliseconds; use Next fixture to request another sample.")
                if let snapshot = store.state.snapshot {
                    Text(snapshot.frame == nil ? "No current frame." : "A current synthetic frame is present.")
                    ForEach(snapshot.quality.reasons, id: \.self) { Text($0) }
                }
                Text("Depth coverage outside the fixture is unknown. No speech, haptics, watch output, or cloud service is active.")
            }.padding()
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Sensing details").navigationBarTitleDisplayMode(.inline)
    }
    private var sessionControls: some View {
        VStack(spacing: 4) {
            Text(typeSize.isAccessibilitySize ? "Demo · muted" : "Demo — simulated data")
                .font(.headline).accessibilityIdentifier("session.demoLabel")
                .accessibilityLabel(typeSize.isAccessibilitySize ? "Demo — simulated data. Alerts muted." : "Demo — simulated data")
            if !typeSize.isAccessibilitySize {
                Text("Visual view only; alerts muted").modifier(LumaMetadataText())
            }
            ViewThatFits(in: .horizontal) {
                HStack { controlButtons }
                VStack(spacing: 4) { controlButtons }
            }
        }.padding(16).background(LumaTheme.surface)
    }
    @ViewBuilder private var sessionFooter: some View {
        if store.state.isSessionOpen { sessionControls }
    }
    @ViewBuilder private var controlButtons: some View {
        Button(store.state.snapshot?.lifecycle == .paused ? "Resume" : "Pause") {
            store.send(store.state.snapshot?.lifecycle == .paused ? .resume : .pause)
        }.disabled(!store.state.allows(.pause) && !store.state.allows(.resume))
            .buttonStyle(ShellButtonStyle())
        Button("Help") { store.send(.pause); showHelp = true }.buttonStyle(ShellButtonStyle())
        Button("End demo") { store.send(.end) }.buttonStyle(ShellButtonStyle(destructive: true))
    }
    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Guidance is paused.").font(.title2)
                    Text("Trusted contacts, calling, and message sharing are unavailable in this build. No contact or location has been accessed and no communication has been sent.")
                    Text("You can use your phone’s Phone or Messages app to contact someone you choose. Returning here does not resume the demo automatically.")
                    Button("Close Help") { showHelp = false }.buttonStyle(ShellButtonStyle())
                }.padding(24)
            }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Help").navigationBarTitleDisplayMode(.inline)
        }
    }
    private var settings: some View {
        List {
            Section("Interface") {
                LabeledContent("Current interface", value: interfaceMode.developer ? "Developer" : "Standard")
                    .accessibilityIdentifier("interface.current")
                Button(interfaceMode.developer ? "Use Standard interface" : "Use Developer interface") {
                    store.send(.end)
                    interfaceMode.setDeveloper(!interfaceMode.developer)
                }.buttonStyle(ShellButtonStyle()).accessibilityIdentifier("interface.change")
                Text("Switching returns to Home and ends the active session. Export recordings before changing. Developer shows Research tools; each feature still needs its own opt-in.")
                    .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
            }
            Section("Interaction and appearance") {
                Button { editPresentation = true } label: {
                    ShellNavigationLabel("Interaction and appearance", subtitle: "\(presentation.style.rawValue) · \(presentation.appearance.rawValue)", systemImage: "textformat.size")
                }.buttonStyle(.plain)
                Text("Use iPhone Accessibility settings for Dynamic Type, Bold Text, Increase Contrast and system assistive input.")
                    .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
            }
            Section("Personalization") {
                NavigationLink("Profiles") { ProfilesView().onAppear { store.send(.end) } }
                NavigationLink("Enhancement preview") { EnhancementPreviewView() }
                NavigationLink("Phone cue preview") { FeedbackPreviewView().onAppear { store.send(.end) } }
                NavigationLink("Preview profile and cues") { profile }
            }
            Section("Devices and privacy") {
                NavigationLink("Mount and accessory setup") { AccessoriesView().onAppear { store.send(.end) } }
                NavigationLink("On this device") { privacy }
                NavigationLink("About LumaPath") { about }
            }
            if interfaceMode.developer { Section("Diagnostics and Research") {
                Text("Deliberate opt-in tools for stationary trials. These do not provide walking guidance.")
                    .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                NavigationLink("Capture diagnostics") { CaptureDiagnosticsView().onAppear { store.send(.end) } }
                    .accessibilityIdentifier("capture.diagnostics")
                NavigationLink("Geometry research") { GeometryResearchView().onAppear { store.send(.end) } }
                    .accessibilityIdentifier("geometry.research")
            } }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
    private var privacy: some View {
        List {
            Section("Saved locally") {
                Text("Interaction style and appearance stay on this device. Profiles and manual place notes are saved separately when you explicitly save them.")
                Text("Spatial scans are historical records stored on this device. They do not establish your current location.")
            }
            Section("Camera, speech and Research") {
                Text("Ordinary live images and observations are not saved or uploaded. On-device speech starts only after you choose Speak command and access is available.")
                Text("Research recordings are an explicit exception: consented camera/depth samples remain in memory until you export or delete them. Sharing an export is your choice.")
                Text("Choosing an interaction style grants no permissions and enables no feedback channels. Phone-only local tools do not require an account.")
            }
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("On this device").navigationBarTitleDisplayMode(.inline)
    }
    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LumaBrandSignature()
                Text("Personalize your camera view, review supported Find commands and keep place notes on your device.")
                LumaNotice(title: "Research build", detail: "Sensing, object recognition and cues remain unvalidated. Use your usual aids. Routes, community reports and trusted-contact integration are unavailable in this build.")
                Button("Review setup") { welcome = true }.buttonStyle(ShellButtonStyle())
            }.padding(24)
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
    private var profile: some View { ProfilePreviewView(initial: store.state.preferences, apply: store.apply) }
    private var places: some View { ManualPlacesView().onAppear { store.send(.end) } }
    private func featurePage(_ feature: ShellFeature, title: String) -> some View {
        ScrollView {
            ContentUnavailableView {
                Label("Unavailable in this build", systemImage: feature == .routes ? "map" : "person.2")
            } description: {
                Text(store.availability.unavailableReason(for: feature))
            } actions: {
                Button("Back to Home") { store.select(.home) }.buttonStyle(ShellButtonStyle())
            }.padding()
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle(title)
    }
}

private struct SyntheticReferenceView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Static synthetic reference — not a current observation").modifier(LumaMetadataText())
            if let url = try? ReplayFixtures.url("synthetic-scene.png"), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Static synthetic landscape with a yellow center obstacle and colored calibration corners.")
            } else { Text("The reference image is unavailable. Demo controls still work.") }
        }
    }
}

private struct ProfilePreviewView: View {
    @State private var draft: PresentationPreferences
    @State private var cue: CuePreview = .obstacle
    let apply: (PresentationPreferences) -> Void
    @Environment(\.dismiss) private var dismiss
    init(initial: PresentationPreferences, apply: @escaping (PresentationPreferences) -> Void) {
        _draft = State(initialValue: initial)
        self.apply = apply
    }
    var body: some View {
        Form {
            Section("Preview only") {
                Text("These are presentation preferences, not a vision assessment. Preview choices last for this launch. Use Profiles on Home for saved profiles and optional exercises.")
                Picker("Visual focus", selection: $draft.focus) {
                    Text("Whole scene").tag(VisualFocus.wholeScene)
                    Text("Central summary").tag(VisualFocus.centralSummary)
                    Text("Wide-scene summary").tag(VisualFocus.wideSceneSummary)
                }
                Picker("Speech detail", selection: $draft.speechDetail) {
                    Text("Minimal").tag(SpeechDetail.minimal)
                    Text("Standard").tag(SpeechDetail.standard)
                    Text("Descriptive").tag(SpeechDetail.descriptive)
                }
                SyntheticReferenceView()
                Text(draft.focus == .wideSceneSummary
                     ? "Sample summary: left unknown; center obstacle; right unknown."
                     : draft.focus == .centralSummary ? "Sample central summary: obstacle ahead. Other regions unknown."
                     : "Whole-scene reference with no moved outlines.")
                Text(draft.speechDetail == .minimal ? "Sample text: Obstacle ahead."
                     : draft.speechDetail == .standard ? "Sample text: Obstacle ahead, about two meters."
                     : "Sample text: A simulated obstacle is ahead, about two meters away. Its type is unknown.")
            }
            Section("Cue vocabulary — text preview") {
                Picker("Cue meaning", selection: $cue) {
                    ForEach(CuePreview.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(cue.example)
                Text("Proposed haptic pattern: \(cue.pattern).")
                Text("No audio or haptic playback occurs. Cue comprehension has not been validated.")
            }
            Section {
                Button("Keep preview choices") { apply(draft); dismiss() }
                Button("Reset preview") { draft = PresentationPreferences(); cue = .obstacle }
                Button("Skip preview") { dismiss() }
            }.buttonStyle(ShellButtonStyle())
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Profile preview").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor final class ManualPlacesStore: ObservableObject {
    @Published private(set) var notes: [ManualPlaceNote] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let library: ManualPlaceLibrary
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = ProcessInfo.processInfo.arguments.contains("-places-testing") ? "LumaPathUITestPlaces" : "LumaPathManualPlaces"
        library = ManualPlaceLibrary(directory: base.appendingPathComponent(folder, isDirectory: true))
    }
    func reload() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { notes = try await library.load(); loaded = true; error = nil }
        catch {
            notes = []; loaded = false
            self.error = "Place notes could not be read. Existing files were preserved. Unlock the phone and retry; damaged or newer-format files need recovery before editing."
        }
    }
    func save(id: UUID, revision: UInt64?, name: String, text: String) async -> Bool {
        guard loaded, !busy else { return false }
        busy = true; defer { busy = false }
        do {
            notes = try await library.save(id: id, expectedRevision: revision, name: name, text: text)
            error = nil; return true
        } catch { self.error = message(for: error); return false }
    }
    func delete(_ note: ManualPlaceNote) async -> Bool {
        guard loaded, !busy else { return false }
        busy = true; defer { busy = false }
        do {
            notes = try await library.delete(id: note.id, expectedRevision: note.revision)
            error = nil; return true
        } catch { self.error = message(for: error); return false }
    }
    private func message(for error: any Error) -> String {
        switch error as? ManualPlaceError {
        case .invalidName: return "Enter a place name of 1 to 80 characters. Your changes have not been saved."
        case .textTooLong: return "Keep notes within 2,000 characters. Your changes have not been saved."
        case .libraryFull: return "Place storage is full (up to 100 notes). Shorten notes or cancel and delete an unused place."
        case .conflict: return "This note changed or was deleted. Cancel and reopen the library before editing again. Your draft has not replaced it."
        default: return "The change could not be confirmed. Your draft remains here. Retry when device storage is available, or cancel and reload to check the saved record."
        }
    }
}

private struct ManualPlacesView: View {
    @EnvironmentObject private var store: ManualPlacesStore
    var body: some View {
        List {
            Section {
                Text("Save place names and notes on this device without camera, location, or network access. Nothing is uploaded.")
                Text("Manual notes only. They do not identify your current location, detect landmarks, or provide navigation. Research spatial scans have a separate library; remembered guidance remains unavailable.")
                    .accessibilityIdentifier("places.scope")
                if let error = store.error {
                    Text(error).accessibilityIdentifier("places.error")
                    Button("Retry loading place notes") { Task { await store.reload() } }
                        .frame(minHeight: 56).disabled(store.busy)
                }
                if !store.loaded && store.error == nil { ProgressView("Loading place notes") }
            }
            Section("Manual place notes") {
                if store.loaded && store.notes.isEmpty {
                    ContentUnavailableView("No place notes saved", systemImage: "mappin.and.ellipse", description: Text("Save a name and a useful note. Manual notes do not need camera or location access."))
                        .accessibilityIdentifier("places.empty")
                }
                ForEach(store.notes) { note in
                    NavigationLink {
                        ManualPlaceEditor(note: note)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(note.name, systemImage: "mappin.and.ellipse").font(.headline)
                            Text("Manual note · no spatial map").modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened)).modifier(LumaMetadataText()).foregroundStyle(LumaTheme.secondaryInk)
                        }.padding(.vertical, 8)
                    }.accessibilityIdentifier("place.\(note.id.uuidString)")
                }
            }
        }
        .scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Saved places").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            NavigationLink("Spatial scans") { SpatialPlacesView() }
                .accessibilityIdentifier("places.spatial")
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink("Add place note") { ManualPlaceEditor(note: nil) }
                .buttonStyle(ShellButtonStyle()).padding(8).background(LumaTheme.surface)
                .disabled(!store.loaded || store.busy).accessibilityIdentifier("places.add")
        }
        .task { await store.reload() }
    }
}

private struct ManualPlaceEditor: View {
    @EnvironmentObject private var store: ManualPlacesStore
    @Environment(\.dismiss) private var dismiss
    private let original: ManualPlaceNote?
    private let id: UUID
    @State private var name: String
    @State private var text: String
    @State private var confirmDelete = false
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, notes }
    init(note: ManualPlaceNote?) {
        original = note; id = note?.id ?? UUID()
        _name = State(initialValue: note?.name ?? "")
        _text = State(initialValue: note?.text ?? "")
    }
    var body: some View {
        Form {
            Section("Manual note") {
                Text("This is a user-entered reference, not a current observation. It cannot start a search or spatial guidance.")
                Text("Place name").font(.headline)
                TextField("For example: Library entrance", text: $name).focused($focused, equals: .name)
                    .submitLabel(.done).onSubmit { focused = nil }.accessibilityIdentifier("place.name")
                Text("Notes (optional)")
                TextEditor(text: $text).frame(minHeight: 140).focused($focused, equals: .notes)
                    .accessibilityLabel("Place notes").accessibilityIdentifier("place.notes")
                Text("Name: \(name.count)/80 characters. Notes: \(text.count)/2,000.").modifier(LumaMetadataText())
                Text("Changes stay in this draft until you choose Save note. Cancel discards the draft.")
                if let error = store.error { Text(error).accessibilityIdentifier("place.error") }
            }
            if let original {
                Section("Saved record") {
                    Text("Last saved: \(original.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    Button("Delete place note", role: .destructive) { focused = nil; confirmDelete = true }
                        .frame(minHeight: 56).disabled(store.busy).accessibilityIdentifier("place.delete")
                }
            }
        }
        .scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle(original == nil ? "Add place note" : "Edit place note")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done editing") { focused = nil } }
        }
        .safeAreaInset(edge: .bottom) {
            ViewThatFits(in: .horizontal) {
                HStack { editorButtons }
                VStack { editorButtons }
            }.padding(16).background(LumaTheme.surface)
        }
        .confirmationDialog("Delete \(original?.name ?? "this place note")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                guard let original else { return }
                Task { if await store.delete(original) { dismiss() } }
            }
            Button("Keep note", role: .cancel) {}
        } message: { Text("The saved name and notes will be removed from this device. This cannot be undone.") }
    }
    @ViewBuilder private var editorButtons: some View {
        Button("Save note") {
            focused = nil
            Task {
                if await store.save(id: id, revision: original?.revision, name: name, text: text) { dismiss() }
            }
        }.buttonStyle(ShellButtonStyle(prominent: true)).disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("place.save")
        Button("Cancel") { dismiss() }.buttonStyle(ShellButtonStyle()).disabled(store.busy)
            .accessibilityIdentifier("place.cancel")
    }
}
