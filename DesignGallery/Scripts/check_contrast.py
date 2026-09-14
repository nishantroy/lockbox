#!/usr/bin/env python3
"""Check the light Soft Lantern text/action colors against their used backgrounds."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources" / "Theme.swift", ROOT.parent / "PhoneLockbox" / "DesignGallery" / "GalleryTheme.swift"]
COLOR = re.compile(r"(accent|rest): Color\(red: ([0-9.]+), green: ([0-9.]+), blue: ([0-9.]+)\)")


def luminance(rgb):
    channels = []
    for value in rgb:
        value = float(value)
        channels.append(value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast(first, second):
    one, two = luminance(first), luminance(second)
    return (max(one, two) + 0.05) / (min(one, two) + 0.05)


def light_lantern_colors(path):
    text = path.read_text()
    lantern = text.split("case .lantern:", 1)[1]
    values = {}
    for name, red, green, blue in COLOR.findall(lantern):
        values.setdefault(name, []).append((float(red), float(green), float(blue)))
    # Each color occurs once in the dark branch and once in the light branch.
    return values["accent"][-1], values["rest"][-1]


parsed = [light_lantern_colors(path) for path in SOURCES]
if parsed[0] != parsed[1]:
    raise SystemExit(f"Source drift: {parsed[0]} != {parsed[1]}")

accent, rest = parsed[0]
white = (1.0, 1.0, 1.0)
light_card = (1.0, 0.985, 0.94)
checks = {
    "white on Lock now accent": contrast(white, accent),
    "accent text on light card": contrast(accent, light_card),
    "white on active rest icon": contrast(white, rest),
    "rest text on light card": contrast(rest, light_card),
}
for label, ratio in checks.items():
    print(f"{label}: {ratio:.2f}:1")
    if ratio < 4.5:
        raise SystemExit(f"FAIL {label}: {ratio:.2f}:1 < 4.50:1")
print("PASS: all Soft Lantern light-mode pairings meet WCAG AA with margin")
