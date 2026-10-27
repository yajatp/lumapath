import SwiftUI
import LumaPathDomain
import LumaPathCommands
import LumaPathPersonalization

struct FindView: View {
    @StateObject private var model: FindModel
    init(profile: VisionProfile? = nil) { _model = StateObject(wrappedValue: FindModel(profile: profile)) }
    var body: some View { FindContent(model: model, live: model.live, speech: model.speech) }
}

private struct FindContent: View {
    @EnvironmentObject private var interfaceMode: InterfaceMode
    @ObservedObject var model: FindModel
    @ObservedObject var live: LiveRenderModel
    @ObservedObject var speech: PushToTalkModel
    @EnvironmentObject private var presentation: PresentationSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var help = false
    @FocusState private var editing: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    ShellSectionHeading("What would you like to find?", subtitle: "Choose a supported target or enter one command. Review it before anything starts.")
                    if presentation.style == .voice { voiceInput }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find command").font(.headline)
                        TextField("Find command", text: $model.input, prompt: Text("For example: find exit sign").foregroundStyle(LumaTheme.secondaryInk), axis: .vertical)
                            .padding(16).background(LumaTheme.sunken, in: RoundedRectangle(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(LumaTheme.boundary, lineWidth: 1.5) }
                            .focused($editing).accessibilityIdentifier("find.input").accessibilityLabel("Find command")
                            .textInputAutocapitalization(.sentences)
                            .onChange(of: model.input) { _, value in
                                if value.count > 1_001 { model.input = String(value.prefix(1_001)) }
                            }
                    }
                    Button("Review typed command") { editing = false; model.submit(model.input) }
                        .accessibilityIdentifier("find.review")
                        .buttonStyle(ShellButtonStyle(prominent: model.proposal == nil))
                        .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(model.message).foregroundStyle(LumaTheme.secondaryInk).accessibilityIdentifier("find.message")
                    if presentation.style != .voice { voiceInput }
                }
                if let proposal = model.proposal {
                    ShellCard {
                        ShellSectionHeading("Review your command", subtitle: "Nothing starts until you confirm.")
                        Text(model.reviewedWords).font(.title2).accessibilityLabel("Captured command: \(model.reviewedWords)")
                        Text("Review: \(FindPresentation.interpretation(proposal.command))").font(.title2.weight(.semibold))
                        Button("Confirm command") { model.confirm() }.accessibilityIdentifier("find.confirm")
                            .buttonStyle(ShellButtonStyle(prominent: true))
                        Button("Dismiss command") { model.dismissReview() }.buttonStyle(ShellButtonStyle())
                    }
                }
                if model.snapshot.target != nil || model.paused { currentSearch }
                VStack(alignment: .leading, spacing: 12) {
                    ShellSectionHeading("Targets", subtitle: "Exit-sign text is available only in a stationary Research trial. Other targets explain their current limits.")
                    ForEach(GoalTarget.allCases, id: \.self) { target in
                        Button { editing = false; model.submit("find \(FindPresentation.name(target))") } label: {
                            ShellNavigationLabel("Find \(FindPresentation.name(target))",
                                subtitle: FindPresentation.unavailable(target, research: false), systemImage: "magnifyingglass")
                        }.buttonStyle(.plain)
                    }
                }
                InteractionShortcut()
                VStack(alignment: .leading, spacing: 16) {
                    ShellSectionHeading("Current camera", subtitle: live.qualitySummary)
                    CameraSurface(image: live.image, updateViewport: live.updateViewport)
                        .frame(height: typeSize.isAccessibilitySize || presentation.style == .voice ? 120 : 200).clipped()
                        .overlay {
                            if live.image == nil {
                                Text("No current camera image").padding(16)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(LumaTheme.sunken).foregroundStyle(LumaTheme.ink)
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 20))
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                Text(live.qualitySummary)
                                SensingQualityDetailsView(quality: live.qualitySnapshot?.quality)
                                Text(live.resourceSummary)
                                Text("Capture: \(live.status.phase.rawValue)")
                                if let reason = live.status.reason { Text(reason) }
                            }.padding(24)
                        }.background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Sensing details").navigationBarTitleDisplayMode(.inline)
                    } label: { Label("Sensing details", systemImage: "info.circle") }.buttonStyle(ShellButtonStyle())
                    if live.capabilities.cameraPermission == .denied || live.capabilities.cameraPermission == .restricted {
                        LumaNotice(title: "Camera access unavailable", detail: "Typed commands and saved place notes remain available. Review camera access in iPhone Settings.")
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                            .buttonStyle(ShellButtonStyle())
                    }
                }
                if interfaceMode.developer { DisclosureGroup("Stationary Research trial") { researchControls.padding(.top, 16) } }
                DisclosureGroup("More command examples") {
                    Text("Pause, resume, repeat, next, cancel search, minimal detail, standard detail, descriptive detail. Enter one command at a time. Communication actions use a separate workflow.").padding(.top, 12)
                }
            }.padding(.horizontal, typeSize.isAccessibilitySize ? 16 : 24).padding(.vertical, 16)
        }.background(LumaTheme.canvas).scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Group {
                if typeSize.isAccessibilitySize { VStack(spacing: 12) { searchControls } }
                else { HStack(spacing: 12) { searchControls } }
            }.padding(16).background(LumaTheme.surface)
        }
        .modifier(LumaReading()).navigationTitle("Find").navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $help) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Find paused").font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text("Close Help, then resume explicitly for fresh observations. Typed input and target buttons work without speech permission.")
                        Text("This trial supplies current-camera exit-sign candidates only. Remembered places and map information are separate sources. Keep using your usual aids.")
                        Button("Close Help") { help = false }.buttonStyle(ShellButtonStyle())
                    }.padding(24)
                }.background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Help").navigationBarTitleDisplayMode(.inline)
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.pause() } }
        .task {
            while !Task.isCancelled {
                model.tick()
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
    }
    private var voiceInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(speech.listening ? "Listening" : speech.requesting ? "Checking microphone access" : "Microphone off", systemImage: speech.listening ? "mic.fill" : "mic.slash")
                .font(.headline)
            Text(speech.status).modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                .accessibilityIdentifier("find.speechStatus")
            if speech.listening || speech.requesting {
                Button("Review speech") { model.useTranscript() }.disabled(speech.requesting).buttonStyle(ShellButtonStyle())
                Button("Cancel microphone") { speech.cancel() }.buttonStyle(ShellButtonStyle())
            } else {
                Button { editing = false; model.startSpeech() } label: { Label("Speak command", systemImage: "mic") }
                    .buttonStyle(ShellButtonStyle())
                if !speech.transcript.isEmpty {
                    Button("Review captured speech") { model.useTranscript() }.buttonStyle(ShellButtonStyle())
                }
            }
            if !speech.transcript.isEmpty {
                Text(speech.transcript).font(.title2).accessibilityLabel("Captured speech: \(speech.transcript)")
            }
        }
    }
    private var currentSearch: some View {
        ShellCard {
            ShellSectionHeading("Current search", subtitle: "Current camera · Research")
            Text("Current goal: \(model.snapshot.target.map(FindPresentation.name) ?? "none")").font(.title.weight(.semibold))
            if let candidate = model.snapshot.candidate {
                Text(FindPresentation.candidate(candidate, detail: model.detail)).modifier(LumaObservationText()).accessibilityIdentifier("find.candidate")
                Button("Repeat candidate") { model.repeatCandidate() }.buttonStyle(ShellButtonStyle())
                Button("Next candidate") { model.nextCandidate() }.buttonStyle(ShellButtonStyle())
                Button("I found the target — complete") { model.complete() }.buttonStyle(ShellButtonStyle(prominent: true))
            } else if model.snapshot.phase == .notObservedYet {
                Text("Not observed yet. This does not mean the target is absent.").accessibilityIdentifier("find.timeout")
                Button("Continue scanning") { model.continueSearch() }.buttonStyle(ShellButtonStyle())
                Button("Change target") { model.stop(); editing = true }.buttonStyle(ShellButtonStyle())
            } else if model.snapshot.phase == .searching { Text("No current candidate. Scanning for supported evidence.") }
            else { Text("No current candidate.") }
            if model.paused { Button("Resume search") { model.submit("resume") }.buttonStyle(ShellButtonStyle()) }
        }
    }
    private var researchControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            LumaNotice(title: "Stationary trial only", detail: "Only exit-sign OCR is installed. Target accuracy and physical trials are pending. Use a protected setting with your usual aids. A candidate does not establish a safe or accessible exit.")
            Toggle("Enable Research Find", isOn: $live.researchEnabled).onChange(of: live.researchEnabled) { _, _ in model.researchChanged() }
            Toggle("Use camera only", isOn: $live.cameraOnlySelected)
            Toggle("Phone speech", isOn: $live.speechEnabled).disabled(!live.researchEnabled)
            Toggle("Phone haptics", isOn: $live.hapticsEnabled).disabled(!live.researchEnabled)
            Text("Enable Research Find to choose optional phone feedback. Changing capture options stops the current search. Current image evidence expires after 300 ms; speech may be cut short.")
            Text(model.inferenceStatus).modifier(LumaSecondaryText())
        }
    }
    @ViewBuilder private var searchControls: some View {
        Button { editing = false; model.stop() } label: { Label("Stop search", systemImage: "stop.fill") }
            .accessibilityIdentifier("find.stop").buttonStyle(ShellButtonStyle(destructive: true))
        Button { editing = false; model.pause(); help = true } label: { Label("Help", systemImage: "questionmark.circle") }
            .buttonStyle(ShellButtonStyle())
    }
}
