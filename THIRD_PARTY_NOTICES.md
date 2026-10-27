# Third-party notices and development credits

## YOLOv3 models

LumaPath bundles YOLOv3 model assets attributed to **Joseph Redmon and Ali Farhadi**, distributed through Apple’s Core ML model catalog:

- `YOLOv3Int8LUT.mlmodel` — full Research preset.
- `YOLOv3TinyFP16.mlmodel` — Tiny comparison/fallback preset.

Provenance, exact download URLs, SHA-256 checksums, transform behavior, and limitations are recorded in [MODEL.md](LumaPath/Models/Assets/MODEL.md). The original model metadata references the Darknet license, reproduced in [DARKNET-LICENSE.txt](LumaPath/Models/Assets/DARKNET-LICENSE.txt). These are the original Darknet models, rather than Ultralytics model assets.

## Platform frameworks and tooling

The native project uses Apple frameworks including SwiftUI, ARKit, AVFoundation, Vision, Core ML, Core Image, Core Haptics, and WatchConnectivity under their applicable platform terms. XcodeGen generates project configuration; it is not an app runtime dependency.

The optional Python service uses PyJWT, cryptography, Pillow, cffi, and pycparser. Exact pinned dependencies are listed in [Server/requirements.lock](Server/requirements.lock). Simulation and optional plotting dependencies are declared in their respective Research directories. Those dependencies retain their upstream licenses.

## Optional research integrations

The offline [Laya adapter](Research/Fusion/LAYA.md) documents its upstream source and Apache-2.0 reference. Laya weights are not bundled, and protocol-stub tests do not establish execution of those weights. No credentials or hosted-provider account are included.

## AI assistance

The team used OpenAI Codex throughout development, including substantial code generation from team prompts. The team directed product design, testing, and debugging. Private conversations and detailed development-session logs are not published in this repository. Removing those logs does not change the project’s AI-assistance disclosure.

## MHS design reference

The lantern artwork and public mockups in `docs/brand/` and `docs/demos/` were supplied in **LumaPath deck styled for MHS.zip**. The static gallery preserves its scene photography and bundled Bricolage Grotesque, IBM Plex Mono, Instrument Serif, and Material Symbols Rounded fonts. These are reference assets, not native app font dependencies. Upstream photograph credits and license texts were not included in the supplied archive. Import provenance and regeneration steps are recorded in [the demo guide](docs/demos/README.md).
