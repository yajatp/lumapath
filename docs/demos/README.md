# MHS design demos

These are the new public-facing design mockups, imported from the user-supplied **LumaPath deck styled for MHS.zip** on October 26, 2026. The app-screen sheet contains the v2–v4 reference iterations; README previews select the latest supplied iteration for each screen.

Open `index.html` in a browser for the complete app-screen reference, or `logos.html` for the logo sheet. Both are static, self-contained within this folder and require no server. Imported JavaScript was excluded. Fonts and two scene photographs came from the supplied archive; their upstream licensing was not provided. Do not assume that importing them grants additional rights.

The six PNG previews are **design illustrations**, not captures of the running native app. Measurements, detected objects, feedback, and Watch cues shown in them do not establish physical sensing performance. Native UI continues to expose permissions, confirmation, unavailable states, and unvalidated Research features. See [validation](../VALIDATION.md).

The scene photographs are exported as bounded WebP assets; `cwebp` is required for import.

The canonical native implementation is [DesignSystem.swift](../../LumaPath/App/DesignSystem.swift), driven by [tokens.json](../design/tokens.json). Native SF Symbols and system navigation replace the mockup's web icons and painted tab bar. Large text stacks paired Home shortcuts vertically.

To regenerate from the original supplied archive:

```sh
python3 Tools/Design/import_deck.py '/path/to/LumaPath deck styled for MHS.zip'
# With Playwright available to Node, Google Chrome and cwebp installed:
node Tools/Design/render_deck.cjs
python3 Tools/Design/generate_assets.py
```

`render_deck.cjs` renders the extracted SVG into the public icon, both native app icons, and the three brand-mark resolutions. It also refreshes the six PNG previews. The editable SVG is the artwork source; the old hand-drawn icon generator has been retired.

Current native simulator captures are in `docs/screenshots/`. They show the implemented interface, separately from the supplied public design mockups above.
