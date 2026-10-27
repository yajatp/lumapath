import SwiftUI
import LumaPathPersonalization
import LumaPathDomain

struct ProfileExerciseView: View {
    @Binding var profile: VisionProfile
    let kind: ExerciseKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var output = FeedbackPreviewModel()
    @State private var suggestion: ExerciseSuggestion?
    @State private var order = [0.75, 1.0, 1.5].shuffled()
    @State private var color: OutlineColor = .yellow
    @State private var width = 4.0
    @State private var visibleScenes: Set<Int> = []
    @State private var scene = 0
    @State private var cue: CuePreview = .obstacle
    @State private var answer: CuePreview = .obstacle
    @State private var played: CuePreview?
    @State private var reviewed: Set<CuePreview> = []
    @State private var response = ""
    var body: some View {
        Form {
            Section {
                Text("Optional stationary preference exercise").font(.headline)
                Text("Use these supplied synthetic images while stationary. There is no score, diagnosis, or walking task. Accepting a suggestion changes only the draft; Save changes in the editor to persist it.")
            }
            if kind == .contrast {
                Section("Compare all three pairs; choose the easiest level") {
                    ForEach(0..<3, id: \.self) { index in
                        Text("Pair \(index+1)").font(.headline)
                        candidate(contrast: order[index], label: "A")
                        candidate(contrast: order[(index+1)%3], label: "B")
                    }
                }
            } else if kind == .highlights {
                Section("Compare comfort and preserved window detail") {
                    ForEach([0.25, 0.75], id: \.self) { level in
                        ProfileScenePreview(preferences: preview(highlights: level))
                        Button("Suggest compression \(level, specifier: "%.2f")") { suggestion = .highlights(level) }.frame(minHeight: 56)
                    }
                }
            } else if kind == .outline {
                Section("Check the boundary in all three scenes") {
                    Picker("Outline color", selection: $color) { ForEach(OutlineColor.allCases, id: \.self) { Text($0.rawValue.readable).tag($0) } }
                    Text("Width: \(width, specifier: "%.0f") points")
                    Slider(value: $width, in: 2...10, step: 1) { Text("Outline width") }.frame(minHeight: 56)
                    Picker("Supplied scene", selection: $scene) { Text("Bright window").tag(0); Text("Dim").tag(1); Text("Cluttered").tag(2) }
                    ProfileScenePreview(preferences: outlinePreview, scene: scene)
                    Button("Boundary is distinguishable in this scene") { visibleScenes.insert(scene) }.frame(minHeight: 56)
                    Text("Scenes checked for these choices: \(visibleScenes.count) of 3")
                    Button("Suggest this outline") { suggestion = .outline(color, width) }.disabled(visibleScenes.count != 3).frame(minHeight: 56)
                }
            } else if kind == .placement {
                Section("Compare information placement") {
                    ForEach(ProfileFocus.allCases, id: \.self) { focus in
                        Text(focus.rawValue.readable).font(.headline)
                        ProfileScenePreview(preferences: preview(focus: focus))
                        Button("Suggest \(focus.rawValue.readable)") { suggestion = .placement(focus) }.frame(minHeight: 56)
                    }
                }
            } else {
                Section("Cue meanings") {
                    Text("Play each cue, choose what it meant, then reveal the explanation. Repeat as needed. This records completion, never a comprehension score.")
                    Toggle("Exercise speech", isOn: $output.speech).disabled(!output.capabilities.speech && !output.speech)
                    Toggle("Exercise haptics", isOn: $output.haptics).disabled(!output.capabilities.haptics && !output.haptics)
                    if let reason = output.capabilities.reason { Text(reason) }
                    Picker("Cue number", selection: $cue) { ForEach(Array(CuePreview.allCases.enumerated()), id: \.element) { index, value in Text("Cue \(index+1)").tag(value) } }
                    Button("Play or repeat cue") { output.preview(cue); played = cue; response = "" }
                        .disabled(!output.speech && !output.haptics).frame(minHeight: 56)
                    Picker("What did it mean?", selection: $answer) { ForEach(CuePreview.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Button("Reveal meaning") {
                        response = "You chose: \(answer.title). This cue means: \(cue.title). \(cue.example) Pattern: \(cue.pattern)."
                        reviewed.insert(cue)
                    }.disabled(played != cue).frame(minHeight: 56)
                    Text(response)
                    Button("Try spoken alternative") { output.haptics = false; output.speech = true; output.preview(cue); played = cue }
                        .disabled(!output.capabilities.speech).frame(minHeight: 56)
                    Text("Reviewed \(reviewed.count) of \(CuePreview.allCases.count) meanings. Custom haptic pattern alternatives await device evaluation; spoken meanings are available when speech is supported.")
                    Button("Complete cue exercise") { profile.exercises[.cues] = .completed; output.stop(); dismiss() }
                        .disabled(reviewed.count != CuePreview.allCases.count).frame(minHeight: 56)
                    Button("Stop cue") { output.stop(); played = nil }.frame(minHeight: 56)
                }
            }
            if suggestion != nil {
                Section("Suggestion — not yet applied") {
                    Text("Accept this suggestion to change the draft. You can still leave the editor without saving.")
                    Button("Accept suggestion") { if let suggestion { profile.accept(suggestion) }; dismiss() }.frame(minHeight: 56)
                    Button("Discard suggestion") { suggestion = nil }.frame(minHeight: 56)
                }
            }
            Section {
                Button("Repeat exercise") { resetAttempt(); profile.exercises[kind] = .notStarted }
                Button("Reset exercise status") { resetAttempt(); profile.exercises[kind] = .notStarted }
                Text("Repeat and reset clear this attempt and its status. Existing accepted profile choices remain until you change or reset the profile.")
            }
        }.scrollContentBackground(.hidden).background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle(kind.rawValue.readable)
        .safeAreaInset(edge: .bottom) {
            Button("Skip exercise") { profile.exercises[kind] = .skipped; output.stop(); dismiss() }
                .accessibilityIdentifier("exercise.skip").frame(maxWidth: .infinity, minHeight: 56).buttonStyle(.bordered).padding(8).background(LumaTheme.surface)
        }
        .onChange(of: color) { _, _ in visibleScenes = []; suggestion = nil }
        .onChange(of: width) { _, _ in visibleScenes = []; suggestion = nil }
        .onChange(of: cue) { _, _ in output.stop(); played = nil; response = "" }
        .onChange(of: scenePhase) { _, phase in if phase != .active { output.stop(); played = nil } }
        .onDisappear { output.stop() }
    }
    private func resetAttempt() { output.stop(); suggestion = nil; order.shuffle(); visibleScenes = []; reviewed = []; played = nil; response = "" }
    private func preview(contrast: Double? = nil, highlights: Double? = nil, focus: ProfileFocus? = nil) -> ProfilePreferences {
        var p = profile.preferences
        if let contrast { p.contrast = contrast }
        if let highlights { p.highlights = highlights; p.glare = .standard }
        if let focus { p.focus = focus }
        return p
    }
    private var outlinePreview: ProfilePreferences { var p = profile.preferences; p.outlineColor = color; p.outlineWidth = width; return p }
    private func candidate(contrast: Double, label: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(label): contrast \(contrast, specifier: "%.2f")")
            ProfileScenePreview(preferences: preview(contrast: contrast))
            Button("Suggest contrast \(contrast, specifier: "%.2f")") { suggestion = .contrast(contrast) }.frame(minHeight: 56)
        }
    }
}
