#!/usr/bin/env python3
"""Compile and exercise production camera geometry without running the app."""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Screendrop"


def main():
    with tempfile.TemporaryDirectory(prefix="screendrop-camera-motion-") as directory:
        work = Path(directory)
        # The app's storage and preferences have unrelated AppKit dependencies.
        # Keep only their input fields; compile the real layout, edit map,
        # pointer event declarations, and both motion planners below.
        storage = (SOURCE / "RecordingSession.swift").read_text()
        events = storage[storage.index("nonisolated struct PointerTravelSample:"):
                         storage.index("/// A captured pointer image")]
        stubs = work / "Inputs.swift"
        stubs.write_text("""import Foundation
import CoreGraphics
nonisolated struct RecordingStudioStyle {
    var padding: CGFloat = 0.04
    var cornerRadius: CGFloat = 0.03
    var camera = Camera()
    struct Camera: Sendable {
        var layout = RecordingCameraLayout()
        var roundness: CGFloat = 0.12
        var shrinksDuringZoom = true
        var zoomShrinkAmount: CGFloat = 0.2
    }
}
nonisolated struct PointerCaptureFile: Sendable {
    var travel: [PointerTravelSample] = []
    var presses: [PointerPressEvent] = []
}
""" + events)
        style = (SOURCE / "RecordingStudioStyle.swift").read_text()
        geometry = work / "Geometry.swift"
        geometry.write_text("import CoreGraphics\nimport Foundation\n"
                            + style[style.index("nonisolated struct RecordingStudioLayout:"):])
        sources = ["RecordingMotionSpring.swift", "RecordingClipTimeline.swift",
                   "RecordingViewportTimeline.swift", "RecordingCameraLayout.swift",
                   "RecordingStudioMotionTimeline.swift"]
        executable = work / "checks"
        environment = os.environ.copy()
        environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(work / "ModuleCache"),
                        "-parse-as-library", str(stubs), str(geometry),
                        *[str(SOURCE / name) for name in sources],
                        str(ROOT / "scripts/check-studio-camera-motion.swift"),
                        "-o", str(executable)], check=True, env=environment)
        subprocess.run([str(executable)], check=True, env=environment)


if __name__ == "__main__":
    main()
