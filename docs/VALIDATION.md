# Validation and limitations

This repository is a research prototype submitted to the 2026 Congressional App Challenge. Software checks, simulator screenshots, and synthetic experiments are distinct from physical sensor, accessibility, and user-study evidence.

## Reproduce software checks

Run from the repository root on a Mac with the recorded Xcode/Swift baseline:

```sh
swift test
python3 Tools/Checks/check_scene_model.py
python3 -m unittest discover -s Research/Models -p 'test_*.py'
python3 -m unittest discover -s Research/Fusion -v
python3 -m unittest discover -s Research/Validation -v
python3 -m unittest discover -s Tools/Design -p 'test_*.py' -v
python3 -m unittest discover -s Tools/Release -p 'test_*.py' -v
python3 Tools/Release/audit.py
```

Service tests need the separately pinned Python dependencies:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Server/requirements.lock
PYTHONPATH=Server .venv/bin/python -m unittest discover -s Server/tests -v
```

The simulation generator has its own [dependencies and workflow](../Research/Simulation/README.md). Use a separate environment because its Pillow pin differs from the service:

```sh
python3 -m venv .venv-simulation
.venv-simulation/bin/pip install -r Research/Simulation/requirements.txt
.venv-simulation/bin/python -m unittest discover -s Research/Simulation -v
```

For native builds:

```sh
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPathWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For native/UI tests, select an installed iPhone simulator using `xcrun simctl list devices available`, then run:

```sh
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_IPHONE' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test
```

## Interpreting the evidence

`Evaluation/` retains historical technical records and synthetic data required by the release-audit tools. Records describe their original source revisions and scope. They are not a current blanket test pass. This public snapshot has fresh Git history, so historical development commit IDs are provenance references rather than public commit links.

The release audit validates evidence structure and pending gates. A successful audit does **not** approve a production release. Empty physical-trial files and null measurements mean evidence is missing, not that a test passed.

## Open validation work

- Physical accuracy, low-light/depth behavior, camera alignment, and end-to-end latency.
- Sustained battery, memory, and thermal behavior across supported phones and OS versions.
- VoiceOver, Voice Control, Switch Control, speech intelligibility, and haptic comprehension on real devices with users.
- Watch pairing, timing, cancellation, and usability.
- Consented datasets, independently labeled held-out evaluation, and target-specific model training.
- Routes/Community product integration, real identity-provider staging, and production operations.

Both bundled YOLOv3 presets cover the same 80 categories. Doors, stairs, curbs, and potholes are not added by selecting the larger model. Local object recognition does not certify navigation or replace a cane, guide dog, or mobility training. Continuous spoken assistance remains experimental, including the effect of the 300 ms evidence deadline on utterances.
