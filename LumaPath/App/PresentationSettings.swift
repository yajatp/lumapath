import SwiftUI

enum InteractionStyle: String, CaseIterable, Identifiable {
    case visual = "Visual", voice = "Voice", combined = "Combined"
    var id: String { rawValue }
    var symbol: String { self == .visual ? "camera" : self == .voice ? "text.bubble" : "rectangle.on.rectangle" }
    var explanation: String {
        switch self {
        case .visual: "Emphasize the camera with readable observations."
        case .voice: "Emphasize readable observations and command controls."
        case .combined: "Balance the camera and readable observations."
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

/// Presentation is independent of capture, permission, feedback channels and profiles.
@MainActor final class PresentationSettings: ObservableObject {
    @Published var style: InteractionStyle { didSet { defaults.set(style.rawValue, forKey: "presentation.style") } }
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "presentation.appearance") } }
    @Published var welcomed: Bool { didSet { defaults.set(welcomed, forKey: "presentation.welcomed") } }
    static func forApp() -> PresentationSettings {
        guard ProcessInfo.processInfo.arguments.contains("-presentation-testing"),
              let defaults = UserDefaults(suiteName: "LumaPathUITestPresentation") else { return PresentationSettings() }
        if ProcessInfo.processInfo.arguments.contains("-reset-presentation") {
            defaults.removePersistentDomain(forName: "LumaPathUITestPresentation")
        }
        return PresentationSettings(defaults: defaults)
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = InteractionStyle(rawValue: defaults.string(forKey: "presentation.style") ?? "") ?? .combined
        appearance = AppAppearance(rawValue: defaults.string(forKey: "presentation.appearance") ?? "") ?? .system
        welcomed = defaults.bool(forKey: "presentation.welcomed")
    }
}

struct PresentationSettingsView: View {
    @EnvironmentObject private var settings: PresentationSettings
    @Environment(\.dismiss) private var dismiss
    @State private var style: InteractionStyle
    @State private var appearance: AppAppearance
    init(style: InteractionStyle, appearance: AppAppearance) {
        _style = State(initialValue: style); _appearance = State(initialValue: appearance)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    StyleChoices(selection: $style)
                    AppearanceChoices(selection: $appearance)
                    PresentationSample(style: style)
                    Text("Every style supports touch, VoiceOver and Voice Control. Applying a style preserves your task. Speech, haptics and microphone access stay under your control.")
                        .modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                }.padding(24)
            }.background(LumaTheme.canvas).modifier(LumaReading()).navigationTitle("Interaction and appearance")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 12) {
                        Button("Apply choices") {
                            settings.style = style; settings.appearance = appearance
                            dismiss()
                            UIAccessibility.post(notification: .announcement, argument: "\(style.rawValue) style applied")
                        }.buttonStyle(ShellButtonStyle(prominent: true)).accessibilityIdentifier("presentation.apply")
                        Button("Cancel") { dismiss() }.buttonStyle(ShellButtonStyle())
                    }.padding(16).background(LumaTheme.surface)
                }
        }.preferredColorScheme(appearance.scheme)
    }
}

struct StyleChoices: View {
    @Binding var selection: InteractionStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShellSectionHeading("Choose your interaction style", subtitle: "You can change this at any time.")
            ForEach(InteractionStyle.allCases) { style in
                Button { selection = style } label: {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: style.symbol).frame(width: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(style.rawValue).modifier(LumaActionText())
                            Text(style.explanation).modifier(LumaSecondaryText())
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selection == style ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                    }.padding(16).frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
                        .foregroundStyle(selection == style ? LumaTheme.selectionText : LumaTheme.ink)
                        .background(selection == style ? LumaTheme.selection : LumaTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(selection == style ? LumaTheme.action : LumaTheme.boundary, lineWidth: 2) }
                }.buttonStyle(.plain).accessibilityLabel(style.rawValue).accessibilityHint(style.explanation)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                    .accessibilityIdentifier("presentation.\(style.rawValue.lowercased())")
            }
        }
    }
}

private struct AppearanceChoices: View {
    @Binding var selection: AppAppearance
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShellSectionHeading("Appearance", subtitle: "Follow your device, or choose light or dark.")
            ForEach(AppAppearance.allCases) { appearance in
                Button { selection = appearance } label: {
                    HStack {
                        Text(appearance.rawValue)
                        Spacer()
                        if selection == appearance { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }.buttonStyle(ShellButtonStyle())
                    .accessibilityAddTraits(selection == appearance ? .isSelected : [])
                    .accessibilityIdentifier("appearance.\(appearance.rawValue.lowercased())")
            }
        }
    }
}

private struct PresentationSample: View {
    let style: InteractionStyle
    var body: some View {
        ShellCard {
            ShellSectionHeading("Sample preview", subtitle: "Synthetic information. No camera or microphone is running.")
            if style != .voice {
                Label("Camera preview area", systemImage: "camera")
                    .frame(maxWidth: .infinity, minHeight: style == .visual ? 140 : 80)
                    .padding(12).background(LumaTheme.sunken, in: RoundedRectangle(cornerRadius: 28))
            }
            Text("No current observations.").font(.title2.weight(.semibold))
            Text("\(style.rawValue) style keeps the same actions and sensing status.").modifier(LumaSecondaryText())
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var settings: PresentationSettings
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var style = InteractionStyle.combined
    @State private var appearance = AppAppearance.system
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    LumaBrandSignature()
                    Text("Step \(step) of 3").modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
                    if step == 1 {
                        Text("Your view. Your way.").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text("Choose how information is presented. Your usual aids and system accessibility tools remain available.")
                        StyleChoices(selection: $style)
                    } else if step == 2 {
                        AppearanceChoices(selection: $appearance)
                        PresentationSample(style: style)
                    } else {
                        ShellSectionHeading("Ready when you are", subtitle: "Camera and microphone access are requested only when you use them.")
                        Text("Start with a demo, adjust your camera image, or save a place note. Research sensing remains unvalidated. This build does not provide walking guidance.")
                        Text("Speech and haptics are separate choices in Profiles and Research tools. Choosing a style does not turn them on.")
                    }
                }.padding(24)
            }.modifier(LumaReading()).background(LumaTheme.canvas)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 12) {
                        Button(step == 3 ? "Use these choices" : "Continue") {
                            if step < 3 { step += 1 }
                            else { settings.style = style; settings.appearance = appearance; settings.welcomed = true; dismiss() }
                        }.buttonStyle(ShellButtonStyle(prominent: true))
                        if step > 1 { Button("Back") { step -= 1 }.buttonStyle(ShellButtonStyle()) }
                        Button("Skip setup") { settings.welcomed = true; dismiss() }.buttonStyle(ShellButtonStyle())
                    }.padding(16).background(LumaTheme.surface)
                }
        }.preferredColorScheme(appearance.scheme)
            .onAppear { style = settings.style; appearance = settings.appearance }
    }
}

struct InteractionShortcut: View {
    @EnvironmentObject private var settings: PresentationSettings
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            Label("Style: \(settings.style.rawValue)", systemImage: "slider.horizontal.3")
        }.buttonStyle(ShellButtonStyle()).accessibilityIdentifier("presentation.shortcut")
            .sheet(isPresented: $editing) { PresentationSettingsView(style: settings.style, appearance: settings.appearance) }
    }
}
