# LumaPath interface previews

Explore the native iPhone interface and optional Apple Watch companion through six illustrative mockups: Home, Find, camera adjustments, object and distance readouts, interaction preferences, and Watch cues.

The images illustrate the interface; example measurements and cues are not validated sensing results. Routes and Community are not available in the app. See [validation and limitations](../VALIDATION.md).

## Browse the previews

Open [the interface gallery](index.html) or [brand assets](logos.html) locally in a browser. Both pages work without a server. When browsing on GitHub, HTML links open the source; download or clone the repository to view the rendered pages.

[Native simulator captures](../screenshots/) show the implemented interface separately from these mockups.

## Reproduce the assets

The native interface uses [shared SwiftUI components](../../LumaPath/App/DesignSystem.swift) and [semantic tokens](../design/tokens.json). Native SF Symbols, system navigation, and scalable text preserve platform behavior and accessibility.

With the original design archive, `cwebp`, Google Chrome, and Playwright available to Node:

```sh
python3 Tools/Design/import_deck.py '/path/to/design-archive.zip'
node Tools/Design/render_deck.cjs
python3 Tools/Design/generate_assets.py
```

Run these commands from the repository root. The importer keeps the source sheets and their dependencies in the ignored `.impeccable/reference/` folder. The renderer exports the six public PNG previews, app icons, and brand-mark resolutions without replacing the public gallery pages.

Artwork and image provenance are recorded in [third-party notices](../../THIRD_PARTY_NOTICES.md#interface-illustrations-and-artwork).
