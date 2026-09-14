#!/usr/bin/env python3
"""Check gallery palette drift and WCAG AA contrast for every theme branch."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / "Sources" / "Theme.swift",
    ROOT.parent / "PhoneLockbox" / "DesignGallery" / "GalleryTheme.swift",
]
THEMES = ["midnight", "midnightOriginal", "midnightContrast", "adaptivePreview", "circadian", "lantern"]
TOKENS = re.compile(
    r"(?P<name>background|surface|primary|secondary|accent|rest|focus|onAccent): "
    r"(?:Color\(red: (?P<red>[0-9.]+), green: (?P<green>[0-9.]+), blue: (?P<blue>[0-9.]+)\)|Color\.white)"
)


def luminance(rgb):
    linear = []
    for value in rgb:
        value = float(value)
        linear.append(value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4)
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(first, second):
    one, two = luminance(first), luminance(second)
    return (max(one, two) + 0.05) / (min(one, two) + 0.05)


def parse_palette(text, theme):
    case_label = "case .midnight, .midnightOriginal:" if theme in {"midnight", "midnightOriginal"} else f"case .{theme}:"
    segment = text.split(case_label, 1)[1]
    segment = re.split(r"\n        case \.", segment, maxsplit=1)[0]
    blocks = segment.split("return GalleryPalette(")[1:]
    palettes = []
    for block in blocks[:2]:
        tokens = {}
        for match in TOKENS.finditer(block):
            if match.group("red") is None:
                tokens[match.group("name")] = (1.0, 1.0, 1.0)
            else:
                tokens[match.group("name")] = tuple(float(match.group(channel)) for channel in ("red", "green", "blue"))
        palettes.append(tokens)
    if len(palettes) != 2:
        raise SystemExit(f"Expected dark and light branches for {theme}")
    return palettes


def check_branch(theme, branch, palette):
    pairs = {
        "primary/background": (palette["primary"], palette["background"]),
        "primary/surface": (palette["primary"], palette["surface"]),
        "secondary/background": (palette["secondary"], palette["background"]),
        "secondary/surface": (palette["secondary"], palette["surface"]),
        "accent/surface": (palette["accent"], palette["surface"]),
        "rest/surface": (palette["rest"], palette["surface"]),
        "focus/surface": (palette["focus"], palette["surface"]),
        "onAccent/accent": (palette["onAccent"], palette["accent"]),
    }
    ratios = {label: contrast(*colors) for label, colors in pairs.items()}
    label, ratio = min(ratios.items(), key=lambda item: item[1])
    print(f"{theme} {branch}: minimum {ratio:.2f}:1 ({label})")
    failures = [(label, ratio) for label, ratio in ratios.items() if ratio < 4.5]
    if failures:
        details = ", ".join(f"{label} {ratio:.2f}:1" for label, ratio in failures)
        raise SystemExit(f"FAIL {theme} {branch}: {details}")


texts = [path.read_text() for path in SOURCES]
if texts[0] != texts[1]:
    raise SystemExit("FAIL palette source drift: standalone Theme.swift differs from embedded GalleryTheme.swift")

for theme in THEMES:
    dark, light = parse_palette(texts[0], theme)
    check_branch(theme, "dark", dark)
    check_branch(theme, "light", light)

lantern_light = parse_palette(texts[0], "lantern")[1]
print(f"Lantern white on accent: {contrast((1, 1, 1), lantern_light['accent']):.2f}:1")
print(f"Lantern accent on light card: {contrast(lantern_light['accent'], (1, 0.985, 0.94)):.2f}:1")
print(f"Lantern white on rest: {contrast((1, 1, 1), lantern_light['rest']):.2f}:1")
print(f"Lantern rest on light card: {contrast(lantern_light['rest'], (1, 0.985, 0.94)):.2f}:1")
print("PASS: all gallery palette branches meet WCAG AA normal-text contrast")
