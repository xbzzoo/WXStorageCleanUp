#!/usr/bin/env python3
"""Convert the checked-in PNG artwork into a complete macOS icon family."""
from pathlib import Path
import subprocess

PROJECT = Path(__file__).resolve().parents[1]


def build_icon(output: Path) -> Path:
    source = PROJECT / "assets" / "AppIcon.png"
    if not source.is_file():
        raise RuntimeError("Missing icon artwork: assets/AppIcon.png")
    iconset = output / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            size = points * scale
            suffix = "@2x" if scale == 2 else ""
            destination = iconset / f"icon_{points}x{points}{suffix}.png"
            subprocess.run(["sips", "-z", str(size), str(size), str(source), "--out", str(destination)],
                           check=True, stdout=subprocess.DEVNULL)
    destination = output / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)
    return destination


if __name__ == "__main__":
    output = PROJECT / "build"
    output.mkdir(exist_ok=True)
    print(build_icon(output))
