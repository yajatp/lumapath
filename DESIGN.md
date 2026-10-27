---
name: LumaPath MHS
description: Native accessibility tools in the user-supplied MHS visual system.
colors:
  teal: "#006B63"
  teal-pressed: "#00564F"
  mint: "#A7F3D0"
  mint-pressed: "#8BDFB9"
  light-canvas: "#F5F7F4"
  light-card: "#FFFFFF"
  light-sunken: "#E9F0ED"
  light-ink: "#14282B"
  light-secondary: "#455B5D"
  light-selection: "#DDF3E9"
  light-hairline: "#E3EAE7"
  dark-card: "#20373A"
  dark-sunken: "#0D1C1F"
  dark-secondary: "#B7CCCA"
  dark-selection: "#284C45"
  dark-hairline: "#3C5758"
typography:
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "20pt"
    fontWeight: 400
  secondary:
    fontFamily: "SF Pro, system-ui"
    fontSize: "18pt"
    fontWeight: 400
  metadata:
    fontFamily: "SF Pro, system-ui"
    fontSize: "17pt"
    fontWeight: 500
  action:
    fontFamily: "SF Pro, system-ui"
    fontSize: "20pt"
    fontWeight: 600
  section:
    fontFamily: "SF Pro, system-ui"
    fontSize: "24pt"
    fontWeight: 600
  observation:
    fontFamily: "SF Pro, system-ui"
    fontSize: "28pt"
    fontWeight: 600
rounded:
  notice: "12pt"
  icon: "18pt"
  control: "24pt"
  card: "24pt"
  camera: "28pt"
  hero: "28pt"
spacing:
  text: "8pt"
  controls: "12pt"
  component: "16pt"
  hero: "20pt"
  screen: "24pt"
  sections: "32pt"
components:
  button-primary:
    backgroundColor: "{colors.teal}"
    textColor: "{colors.light-card}"
    typography: "{typography.action}"
    rounded: "{rounded.control}"
    padding: "16pt"
  button-primary-pressed:
    backgroundColor: "{colors.teal-pressed}"
  button-secondary:
    backgroundColor: "{colors.light-card}"
    textColor: "{colors.light-ink}"
    typography: "{typography.action}"
    rounded: "{rounded.control}"
    padding: "16pt"
  card:
    backgroundColor: "{colors.light-card}"
    textColor: "{colors.light-ink}"
    rounded: "{rounded.card}"
    padding: "16pt"
  target-pill:
    backgroundColor: "{colors.light-selection}"
    textColor: "{colors.teal-pressed}"
    padding: "14pt 16pt"
  live-entry:
    backgroundColor: "{colors.teal}"
    textColor: "{colors.light-card}"
    rounded: "{rounded.hero}"
    padding: "20pt"
---

# LumaPath design system

## Overview

**Creative North Star: “The MHS LumaPath reference”**

The user-supplied MHS app-screen and logo sheets are the visual authority for LumaPath presentation work. Deep teal, mint accents, warm light surfaces, and rounded native components carry the identity across the iPhone app, Watch companion, and public README. This replaces the earlier illustrated lantern and flat Home entry layout.

Use the teal lantern tile with cream frame, mint rays, and amber flame. Editable artwork lives in `docs/brand/lumapath-icon.svg`; `Tools/Design/render_deck.cjs` generates native and public rasters. Native system typography and SF Symbols translate the reference into SwiftUI. The deck’s Bricolage and IBM Plex faces belong to its presentation wrapper.

**Key Characteristics:**

- Adaptive teal and mint semantic colors.
- Rounded cards, icon chips, and a prominent camera entry.
- Scalable native typography and familiar system navigation.
- Explicit distinctions between design illustrations and current sensor evidence.

## Colors

`docs/design/tokens.json` is the canonical palette source. The frontmatter records its principal standard-contrast colors; the JSON owns all four light/dark and increased-contrast variants. Run `python3 Tools/Design/generate_assets.py` to update both catalogs. The iPhone receives all four variants; the Watch receives the dark palette as its default plus the dark increased-contrast variant, without relying on iOS luminosity matching.

Teal is the light appearance’s action color; mint is the dark appearance’s action color. Warm pale canvas and white cards support dark ink in light mode. Dark mode uses ink-colored canvas, lighter teal-black cards, pale text, and softened secondary text. Selection fills tint the relevant surface rather than replacing it with a generic gray.

**The Semantic Boundary Rule.** Decorative hairlines describe cards and separators; stronger boundary assets identify outlined controls. `ShellCard` and `LumaShortcutTile` increase their strokes to two points and use the strong boundary when Increase Contrast is active. Warning, disabled, and destructive roles retain their separate contrast-tested asset colors.

Camera imagery and detection outlines describe evidence or user rendering preferences. Do not recolor those as decorative brand elements.

## Typography

Use SF Pro through SwiftUI’s system APIs. The wordmark is bold and rounded, using semantic `.title` in compact signatures and `.largeTitle` in full signatures. It is not implemented as a fixed 32-point wordmark. Reading, support, metadata, section, observation, and action roles use the scalable sizes recorded in frontmatter at the default content size. Reading text adds four points of line spacing; other native text keeps its system line metrics.

**The Native Reading Rule.** Keep Dynamic Type unrestricted, preserve native chrome typography, and let content wrap vertically. Do not shrink accessible text to reproduce a fixed-size deck illustration. Bold Text and locale fallback remain system responsibilities.

## Layout

Home uses a 24-point horizontal inset and a 32-point section rhythm. Its first action is the live-view entry, followed by paired Find and Saved Places shortcuts. The shortcut grid changes from two columns to one at accessibility text sizes. Find and Live use a compact 16-point horizontal inset at those sizes. Component interiors generally use 16 points, with eight-point text grouping and 12-point control gaps.

Main primary and secondary buttons keep 64- and 56-point minimum heights. Other explicitly sized navigation targets keep at least 44 points. Fixed safe-area controls remain reachable independently of scrolling content. Native tabs and navigation retain system layout, accessibility, and behavior.

## Elevation & Depth

Native shared components use opaque tonal layering and strokes rather than authored shadows. White or dark-card surfaces separate content from the canvas; selected surfaces use mint/teal tint. The deck mockups’ painted device frames and shadows belong to public illustrations and are not a native shadow vocabulary. Native navigation transitions remain system-controlled; no custom animation timing or focus-ring implementation is claimed.

## Shapes

Shared cards and controls use 24-point radii; camera windows and the live-view entry use 28. Navigation icon tiles use 18, and notices retain 12. Find targets use capsule shapes; shortcut icons use circles. Brand-image clipping retains its compact/full signature dimensions. These shape roles apply across setup, profiles, settings, saved places, previews, and Research screens through shared components.

## Components

### Buttons and target pills

`ShellButtonStyle` uses semibold scalable action text, 16-point padding, full available width, and content that wraps vertically. Prominent actions use the action/on-action pair and its pressed variant. Secondary actions use the surface/ink pair with strong outlines; pressed state uses the sunken surface. Disabled and destructive actions use their semantic roles. Native focus and assistive input remain authoritative.

Find target pills use selection fill, selection text, headline typography, and a 56-point minimum height. They submit a proposal for explicit review. They are action shortcuts, not proof that each target is supported or currently detected.

### Cards, inputs, and navigation rows

`ShellCard` uses 16-point padding and spacing, a surface fill, a decorative stroke, and an increased-contrast boundary. The Find command field uses the sunken surface, a strong outline, and 16-point padding; native text focus and keyboard behavior remain intact.

`ShellNavigationLabel` places a system symbol in a sunken rounded icon tile, with title, supporting text, and a forward chevron. The accessible label and hint describe the destination. Native lists and forms retain system structures while inheriting the app’s semantic foreground, tint, and canvas. All 42 Sections apply semantic row backgrounds and section separators directly; these modifiers are not applied at the app root.

### Live entry and Home shortcuts

`LumaLiveEntry` is a teal/mint action surface with a camera icon, forward arrow, and wrapping title and supporting text. Its “Camera tools” label describes tools, not sensor readiness. At accessibility Dynamic Type sizes the decorative status row and fixed-frame camera icon are hidden to prevent symbol overdraw, while the action title and description retain unrestricted scaling. It opens the existing camera workflow.

`LumaShortcutTile` uses a surface fill, a hairline border that becomes a strong two-point boundary under Increase Contrast, a circular selection-tinted icon, and vertically arranged copy. It is used for Find and Saved Places and preserves explicit accessible names and hints.

### Watch companion

The Watch uses a dark-default color catalog with a dark increased-contrast variant, a rounded bold wordmark, secondary Research status, a rounded cue card, and a native prominent Pause action tinted with the semantic action color. This catalog encodes the dark use scene directly because watchOS did not honor iOS luminosity matching or `preferredColorScheme` in verification. Preserve cue freshness, pause behavior, and the distinction between preview and live Research states.

### Public design demos

README visuals come from `docs/demos/`. The six previews are supplied MHS design mockups, not app captures or physical sensing evidence. They intentionally preserve the reference’s illustrative scenes, measurements, and Watch cues. Reproduction and provenance are recorded in `docs/demos/README.md`; earlier simulator captures remain historical evidence in `docs/screenshots/`.

## Do's and Don'ts

- **Do** use shared SwiftUI components and generated semantic assets across ordinary and Research screens.
- **Do** preserve native navigation, assistive input, unrestricted text scaling, explicit review, permissions, and unavailable states.
- **Do** label public demo images as supplied design mockups and keep physical sensing validation separate.
- **Don't** copy mock measurements, sensor-ready badges, object results, or Watch states into runtime state.
- **Don't** introduce a competing visual style for settings, empty states, Research, or the Watch companion.
- **Don't** imply Routes or Community are available before they are implemented.

Palette and contrast checks run with `python3 -m unittest discover -s Tools/Design -v`. Build both targets through the LumaPath scheme and run native/UI journeys after interface changes. Device usability and physical sensing acceptance remain separate gates in `docs/VALIDATION.md`.
