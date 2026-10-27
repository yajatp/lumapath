import SwiftUI
import LumaPathPersonalization
import LumaPathRendering
import LumaPathDomain

@MainActor final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [VisionProfile] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var issues: [String] = []
    @Published var error: String?
    private let archive: ProfileArchive
    var active: VisionProfile? { profiles.first { $0.id == activeID } }
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = ProcessInfo.processInfo.arguments.contains("-profile-testing") ? "LumaPathUITestProfiles" : "LumaPathProfiles"
        archive = ProfileArchive(directory: base.appendingPathComponent(folder, isDirectory: true))
        reload()
    }
    func reload() {
        do {
            let result = try archive.load(); profiles = result.profiles; activeID = result.activeID; issues = result.issues
            error = nil
        } catch { self.error = "Profiles could not be read. Your files were preserved. Retry when device storage is available." }
    }
    @discardableResult func save(_ profile: VisionProfile) -> Bool {
        do {
            var saved = profile; saved.updatedAt = max(Date(), profile.createdAt)
            try archive.save(saved)
            if activeID == nil { try archive.select(saved.id) }
            reload(); return error == nil
        } catch { self.error = "Could not save this profile (\(error)). Your unsaved changes remain here. Retry or use a new profile."; return false }
    }
    func select(_ profile: VisionProfile) {
        do { try archive.select(profile.id); reload() }
        catch { self.error = "Could not select the profile. Retry when device storage is available." }
    }
}

struct ProfilesView: View {
    @EnvironmentObject private var store: ProfileStore
    var body: some View {
        List {
            Section {
                Text("Profiles stay on this device. Changes apply only after Save changes. These are preferences, not a vision assessment.")
                Text("Active profile: \(store.active?.name ?? "Neutral defaults")").accessibilityIdentifier("profile.active")
                if let error = store.error { Text(error); Button("Retry loading profiles") { store.reload() } }
                ForEach(store.issues, id: \.self) { Text($0) }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Saved profiles") {
                ForEach(store.profiles) { profile in
                    VStack(alignment: .leading) {
                        NavigationLink(profile.name) { ProfileEditor(profile: profile) }
                        if store.activeID == profile.id {
                            Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(LumaTheme.selectionText)
                                .frame(minHeight: 56).accessibilityAddTraits(.isSelected)
                        } else {
                            Button("Use \(profile.name)") { store.select(profile) }.frame(minHeight: 56)
                        }
                    }.listRowBackground(store.activeID == profile.id ? LumaTheme.selection : LumaTheme.surface)
                }
                NavigationLink("New profile") { ProfileEditor(profile: VisionProfile(name: "New profile")) }
                    .frame(minHeight: 56).accessibilityIdentifier("profile.new")
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Profiles").navigationBarTitleDisplayMode(.inline)
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VisionProfile
    init(profile: VisionProfile) { _draft = State(initialValue: profile) }
    var body: some View {
        Form {
            Section("Profile") {
                TextField("Profile name", text: $draft.name).accessibilityIdentifier("profile.name")
                Text("Unsaved changes affect this preview only. Save changes to use them in a new live view.")
                if let error = store.error { Text(error) }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Preview — supplied synthetic scene") {
                ProfileScenePreview(preferences: draft.preferences)
                Text("The outlines stay aligned with their regions. Density limits visible regions; all hazard events remain eligible for the summary and enabled output channels.")
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Optional stationary exercises") {
                ForEach(ExerciseKind.allCases, id: \.self) { kind in
                    NavigationLink("\(kind.rawValue.readable): \((draft.exercises[kind] ?? .notStarted).rawValue.readable)") {
                        ProfileExerciseView(profile: $draft, kind: kind)
                    }.frame(minHeight: 56).accessibilityIdentifier("exercise.\(kind.rawValue)")
                }
                Text("Skip any exercise. Results are comfort and presentation preferences, not diagnoses. No walking, acuity measurement, or answer upload.")
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Image and glare comfort") {
                number("Exposure (EV)", key: .exposure, path: \.exposure, range: -1...2)
                number("Contrast", key: .contrast, path: \.contrast, range: 0.5...2)
                number("Highlight compression", key: .highlights, path: \.highlights, range: 0...1)
                number("Image edges", key: .edges, path: \.edges, range: 0...1)
                choice("Glare comfort", key: .glare, path: \.glare, values: GlareComfort.allCases)
                Text("Reduced highlights uses at least 0.65 compression. Interface appearance is chosen separately in Settings. It does not remove physical glare. Original image remains available in Live view.")
                ForEach(LightingPreference.allCases, id: \.self) { condition in
                    Toggle(condition.rawValue.readable, isOn: Binding(get: { draft.preferences.lighting.contains(condition) }, set: {
                        if $0 { draft.preferences.lighting.insert(condition) } else { draft.preferences.lighting.remove(condition) }
                        draft.sources[.lighting] = .manual
                    }))
                }
                if !draft.preferences.lighting.isEmpty {
                    Text("Try the optional contrast and highlight exercises for these lighting conditions. Route consumers will use these saved preferences when integrated.")
                    Button("Try lighting preset in draft") {
                        let backlit = draft.preferences.lighting.contains(.backlit)
                        draft.preferences.exposure = backlit ? 0 : 0.5
                        draft.preferences.contrast = 1.1
                        draft.preferences.highlights = backlit ? 0.75 : 0.25
                        for key in [ProfileKey.exposure, .contrast, .highlights] { draft.sources[key] = .preset }
                    }.frame(minHeight: 56)
                }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Outlines and information") {
                number("Outline width (points)", key: .outlineWidth, path: \.outlineWidth, range: 2...10)
                choice("Outline color", key: .outlineColor, path: \.outlineColor, values: OutlineColor.allCases)
                Toggle("Dark backing stroke", isOn: binding(.dualStroke, \.dualStroke))
                Stepper("Visible regions: \(draft.preferences.density)", value: binding(.density, \.density), in: 1...5).frame(minHeight: 56)
                choice("Visual focus", key: .focus, path: \.focus, values: ProfileFocus.allCases)
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Output preferences") {
                choice("Optional speech detail", key: .speechDetail, path: \.speechDetail, values: ProfileSpeechDetail.allCases)
                Text(draft.preferences.speechDetail == .minimal ? "Optional text preview: Window on the right."
                     : draft.preferences.speechDetail == .standard ? "Optional text preview: A supplied window is on the right of this static scene."
                     : "Optional text preview: This supplied static scene has a bright window on the right, with a darker wall beside it. No live observation is being described.")
                number("Optional description interval (seconds)", key: .descriptionInterval, path: \.descriptionInterval, range: 5...30)
                Toggle("Prefer phone speech", isOn: binding(.speech, \.speech))
                Toggle("Prefer phone haptics", isOn: binding(.haptics, \.haptics))
                Toggle("Prefer spatial cues", isOn: binding(.spatialCues, \.spatialCues))
                Text("Spatial preference is applied only in Research with stereo headphones and a current, explicitly confirmed phone-forward reference. Saved phone preferences are capability checked on entry to Live view; Research remains off until explicitly enabled.")
                NavigationLink("Phone cue preview") { FeedbackPreviewView() }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Mobility preferences — saved for route integration") {
                Toggle("Avoid stairs", isOn: binding(.avoidStairs, \.avoidStairs))
                Toggle("Set required route width", isOn: Binding(get: { draft.preferences.requiredWidth != nil }, set: {
                    draft.preferences.requiredWidth = $0 ? 0.9 : nil; draft.sources[.requiredWidth] = .manual
                }))
                if let width = draft.preferences.requiredWidth {
                    Text("Required width: \(width, specifier: "%.2f") meters")
                    Slider(value: Binding(get: { draft.preferences.requiredWidth ?? 0.9 }, set: {
                        draft.preferences.requiredWidth = $0; draft.sources[.requiredWidth] = .manual
                    }), in: 0.3...3, step: 0.05) { Text("Required route width") }.frame(minHeight: 56)
                }
                choice("Surface preference", key: .surface, path: \.surface, values: SurfacePreference.allCases)
                choice("Anticipation preference", key: .anticipation, path: \.anticipation, values: AnticipationPreference.allCases)
                Text("These choices do not alter measured geometry or remove close-hazard events. Route and advanced anticipation product integration remains pending.")
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section("Preference sources") {
                DisclosureGroup("How these choices were set") {
                    ForEach(ProfileKey.allCases, id: \.self) { key in
                        Text("\(key.rawValue.readable): \((draft.sources[key] ?? .preset).rawValue.readable)")
                    }
                }
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
            Section {
                Button("Reset this profile") { draft.reset() }.frame(minHeight: 56)
                Text("Reset affects this draft’s settings and exercise statuses. Name, other profiles, places and reports are preserved. Save to keep the reset.")
            }.listRowBackground(LumaTheme.surface).listSectionSeparatorTint(LumaTheme.hairline)
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Save changes") { if store.save(draft) { dismiss() } }
                .accessibilityIdentifier("profile.save").disabled(!draft.isValid)
                .frame(maxWidth: .infinity, minHeight: 56).buttonStyle(ShellButtonStyle(prominent: true)).padding(16).background(LumaTheme.surface)
        }
    }
    private func binding<T>(_ key: ProfileKey, _ path: WritableKeyPath<ProfilePreferences, T>) -> Binding<T> {
        Binding(get: { draft.preferences[keyPath: path] }, set: { draft.preferences[keyPath: path] = $0; draft.sources[key] = .manual })
    }
    private func number(_ title: String, key: ProfileKey, path: WritableKeyPath<ProfilePreferences, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(draft.preferences[keyPath: path], specifier: "%.2f")")
            Slider(value: binding(key, path), in: range, step: 0.05) { Text(title) }.frame(minHeight: 56)
        }
    }
    private func choice<T: RawRepresentable & Hashable>(_ title: String, key: ProfileKey, path: WritableKeyPath<ProfilePreferences, T>, values: [T]) -> some View where T.RawValue == String {
        Picker(title, selection: binding(key, path)) { ForEach(values, id: \.self) { Text($0.rawValue.readable).tag($0) } }.frame(minHeight: 56)
    }
}

extension String {
    var readable: String { replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized }
}
extension OutlineColor {
    var swiftUIColor: Color { self == .cyan ? .cyan : self == .white ? .white : .yellow }
}

/// Deterministic bright-window/dim/clutter targets. Never a live camera or an acuity chart.
struct ProfileScenePreview: View {
    let preferences: ProfilePreferences
    var scene = 0
    @State private var original = false
    @State private var image: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(1.5, contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            ForEach(0..<preferences.density, id: \.self) { index in
                                let rect = CGRect(x: CGFloat(index + 1) * proxy.size.width / 7, y: proxy.size.height * 0.55,
                                                  width: proxy.size.width / 9, height: proxy.size.height * 0.24)
                                let path = Path(rect)
                                if preferences.dualStroke { path.stroke(.black, lineWidth: preferences.outlineWidth + 3) }
                                path.stroke(preferences.outlineColor.swiftUIColor, lineWidth: preferences.outlineWidth)
                            }
                        }.accessibilityHidden(true)
                    }
            } else { Text("Synthetic preview could not render. Your settings remain editable.") }
            Text("Static \(scene == 0 ? "bright-window" : scene == 1 ? "dim" : "cluttered") scene. Five supplied rectangles; \(preferences.density) outlines shown. No sensing is running.")
            if preferences.focus == .wideSceneSummary { Text("Wide-scene summary: Left — supplied rectangle. Center — supplied rectangle. Right — supplied rectangle. This summary is placed together; outlines are not moved.").frame(maxWidth: .infinity, alignment: .center) }
            else if preferences.focus == .centralSummary { Text("Central summary: supplied center rectangle. Side rectangles still exist.").frame(maxWidth: .infinity, alignment: .center) }
            Toggle("Show original preview", isOn: $original)
        }.onAppear { render() }.onChange(of: preferences) { _, _ in render() }.onChange(of: scene) { _, _ in render() }.onChange(of: original) { _, _ in render() }
    }
    private func render() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let supplied = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 256), format: format).image { context in
            let c = context.cgContext
            c.setFillColor(UIColor(white: scene == 1 ? 0.09 : 0.35, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 384, height: 256))
            c.setFillColor(UIColor(white: scene == 1 ? 0.3 : 0.98, alpha: 1).cgColor); c.fill(CGRect(x: 240, y: 15, width: 120, height: 100))
            for index in 0..<5 {
                c.setFillColor(UIColor(white: scene == 1 ? 0.18 : 0.55, alpha: 1).cgColor)
                c.fill(CGRect(x: Double(index+1)*384/7, y: 256*0.55, width: 384/9, height: 256*0.24))
            }
            if scene == 2 { for index in 0..<16 { c.setFillColor(UIColor(white: index.isMultiple(of: 2) ? 0.2 : 0.7, alpha: 1).cgColor); c.fill(CGRect(x: Double(index*24), y: 90, width: 12, height: 35)) } }
        }
        guard let source = supplied.cgImage else { image = nil; return }
        var settings = preferences.enhancement; settings.enhanced = !original
        image = FrameRenderer().preview(source, settings: settings)
    }
}
