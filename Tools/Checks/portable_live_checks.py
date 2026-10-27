"""Run actual portable live-readout/recording/command sources and tests without Apple frameworks."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LumaPathPortableChecks", targets: [
    .target(name: "LumaPathDomain", resources: [.copy("Fixtures")]),
    .target(name: "LumaPathRendering", dependencies: ["LumaPathDomain"]),
    .target(name: "LumaPathSensors", dependencies: ["LumaPathDomain"]),
    .target(name: "LumaPathCommands"),
    .testTarget(name: "ReadoutTests", dependencies: ["LumaPathDomain", "LumaPathRendering"]),
    .testTarget(name: "RecorderTests", dependencies: ["LumaPathDomain", "LumaPathSensors"]),
    .testTarget(name: "CommandTests", dependencies: ["LumaPathCommands"])
])
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift", help="Path to a Swift 6 toolchain executable")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="lumapath-portable-") as directory:
        scratch = Path(directory)
        (scratch / "Package.swift").write_text(PACKAGE, encoding="utf-8")
        shutil.copytree(ROOT / "LumaPath/Shared", scratch / "Sources/LumaPathDomain")
        files = {
            "Sources/LumaPathRendering": ["LumaPath/Rendering/StableDistanceReadout.swift", "LumaPath/Rendering/SceneObjectReadout.swift", "LumaPath/Rendering/LowLightPreview.swift"],
            "Sources/LumaPathSensors": ["LumaPath/Sensors/ResearchRecording.swift", "LumaPath/Sensors/CaptureDriver.swift"],
            "Sources/LumaPathCommands": ["LumaPath/Goals/Commands/LiveVoiceCommand.swift"],
            "Tests/ReadoutTests": ["LumaPathRenderingTests/StableDistanceReadoutTests.swift", "LumaPathRenderingTests/SceneObjectReadoutTests.swift", "LumaPathRenderingTests/LowLightPreviewTests.swift"],
            "Tests/RecorderTests": ["LumaPathSensorTests/ResearchRecordingTests.swift"],
            "Tests/CommandTests": ["LumaPathCommandTests/LiveVoiceCommandTests.swift"],
        }
        for target, paths in files.items():
            destination = scratch / target; destination.mkdir(parents=True)
            for path in paths:
                shutil.copy2(ROOT / path, destination / Path(path).name)
        subprocess.run([args.swift, "test"], cwd=scratch, check=True)
    print("Portable logic checks only; full swift test, Xcode and iPhone checks remain separate.")


if __name__ == "__main__":
    main()
