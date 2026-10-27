import SwiftUI

/// Opaque, adaptive semantic roles generated from docs/design/tokens.json.
enum LumaTheme {
    static let canvas = Color("Luma.background")
    static let surface = Color("Luma.surface")
    static let sunken = Color("Luma.surface.sunken")
    static let ink = Color("Luma.text.primary")
    static let secondaryInk = Color("Luma.text.secondary")
    static let action = Color("Luma.accent")
    static let pressedAction = Color("Luma.accent.pressed")
    static let onAction = Color("Luma.text.onAccent")
    static let boundary = Color("Luma.border.strong")
    static let selection = Color("Luma.selection.fill")
    static let selectionText = Color("Luma.selection.text")
    static let danger = Color("Luma.danger.text")
    static let dangerFill = Color("Luma.danger.fill")
}

struct LumaAppTheme: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(LumaTheme.ink).tint(LumaTheme.action).background(LumaTheme.canvas)
    }
}

struct LumaActionText: ViewModifier {
    @ScaledMetric(relativeTo: .headline) private var size = 20.0
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .semibold)) }
}

struct LumaReading: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size = 20.0
    func body(content: Content) -> some View {
        content.font(.system(size: size)).lineSpacing(4).foregroundStyle(LumaTheme.ink)
            .tint(LumaTheme.action).background(LumaTheme.canvas)
    }
}

struct LumaSecondaryText: ViewModifier {
    @ScaledMetric(relativeTo: .callout) private var size = 18.0
    func body(content: Content) -> some View { content.font(.system(size: size)) }
}

struct LumaMetadataText: ViewModifier {
    @ScaledMetric(relativeTo: .subheadline) private var size = 17.0
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .medium)) }
}

struct LumaObservationText: ViewModifier {
    @ScaledMetric(relativeTo: .title) private var size = 28.0
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .semibold)) }
}

struct ShellButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var size = 20.0
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: size, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: prominent ? 64 : 56)
            .foregroundStyle(foreground)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(prominent && isEnabled ? Color.clear : LumaTheme.boundary,
                                  lineWidth: contrast == .increased ? 2 : 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    private var foreground: Color {
        if !isEnabled { return Color("Luma.disabled.text") }
        if destructive { return LumaTheme.danger }
        return prominent ? LumaTheme.onAction : LumaTheme.ink
    }
    private func fill(pressed: Bool) -> Color {
        if !isEnabled { return Color("Luma.disabled.fill") }
        if destructive { return LumaTheme.dangerFill }
        if prominent { return pressed ? LumaTheme.pressedAction : LumaTheme.action }
        return pressed ? LumaTheme.sunken : LumaTheme.surface
    }
}

struct ShellCard<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(contrast == .increased ? LumaTheme.boundary : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
    }
}

struct ShellSectionHeading: View {
    let title: String
    let subtitle: String?
    @ScaledMetric(relativeTo: .title2) private var size = 24.0
    init(_ title: String, subtitle: String?) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: size, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk) }
        }
    }
}

struct ShellNavigationLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var iconWidth = 28.0
    @ScaledMetric(relativeTo: .headline) private var titleSize = 20.0
    init(_ title: String, subtitle: String, systemImage: String) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(LumaTheme.action)
                .frame(width: iconWidth).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(LumaTheme.ink)
                Text(subtitle).modifier(LumaSecondaryText()).foregroundStyle(LumaTheme.secondaryInk)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward").font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaTheme.secondaryInk).accessibilityHidden(true)
        }.padding(.vertical, 12).frame(minHeight: 64)
            .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityHint(subtitle)
    }
}

struct LumaNotice: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle").font(.headline)
            Text(detail).modifier(LumaSecondaryText())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .foregroundStyle(Color("Luma.warning.text"))
            .background(Color("Luma.warning.fill"), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color("Luma.warning.border"), lineWidth: 1.5) }
            .accessibilityElement(children: .combine)
    }
}

/// Shared brand signature. The adjacent name carries the accessible label.
struct LumaBrandSignature: View {
    var compact = false
    @ScaledMetric(relativeTo: .title) private var markSize = 64.0
    var body: some View {
        HStack(spacing: compact ? 8 : 16) {
            Image("LumaBrand").resizable().interpolation(.high).scaledToFit()
                .frame(width: compact ? 32 : markSize, height: compact ? 32 : markSize)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 14))
                .accessibilityHidden(true)
            Text("LumaPath")
                .font(.system(compact ? .title : .largeTitle, design: .rounded, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }
}
