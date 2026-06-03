#!/usr/bin/env python3
"""Render a public README demo GIF for the framework."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "assets" / "demo.gif"


def main() -> None:
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as exc:
        raise SystemExit("Pillow is required: python3 -m pip install Pillow") from exc

    width, height = 1200, 680
    bg = (8, 13, 25)
    panel = (15, 25, 42)
    border = (46, 72, 98)
    green = (104, 255, 176)
    blue = (96, 184, 255)
    cyan = (103, 232, 249)
    text = (229, 239, 251)
    muted = (142, 162, 183)

    font_paths = [
        "/System/Library/Fonts/Menlo.ttc",
        "/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/SFNSMono.ttf",
    ]
    font = None
    title_font = None
    small_font = None
    for path in font_paths:
        if Path(path).exists():
            font = ImageFont.truetype(path, 22)
            title_font = ImageFont.truetype(path, 24)
            small_font = ImageFont.truetype(path, 18)
            break
    if font is None:
        font = ImageFont.load_default()
        title_font = font
        small_font = font

    lines = [
        "$ swift test",
        "[1/6] Compiling ICloudTestFramework CloudAPIClient.swift",
        "[2/6] Compiling ICloudTestFramework CloudTestBase.swift",
        "[3/6] Compiling ICloudTestFramework FailureAnalyzer.swift",
        "Test Suite 'CloudSyncTests' passed: 11 tests, 0 failures",
        "Test Suite 'FailureAnalyzerTests' passed: 11 tests, 0 failures",
        "",
        "$ python3 scripts/triage.py log build/xcodebuild.log",
        "category=infrastructure confidence=0.91 signal=timeout retryable=true",
        "category=product confidence=0.84 signal=assertion actionable=true",
        "",
        "$ python3 scripts/coverage_gap.py --source Sources --tests Tests",
        "public symbols checked: 21  covered: 21  coverage: 100.0%",
        "status: ready for CI publishing",
    ]

    frames = []
    for visible in range(2, len(lines) + 1):
        image = Image.new("RGB", (width, height), bg)
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((28, 28, width - 28, height - 28), radius=16, fill=panel, outline=border, width=2)
        draw.ellipse((52, 52, 70, 70), fill=(255, 99, 112))
        draw.ellipse((82, 52, 100, 70), fill=(255, 205, 93))
        draw.ellipse((112, 52, 130, 70), fill=(91, 218, 140))
        draw.text((156, 48), "icloud-automation-framework / XCTest + CI triage", font=title_font, fill=muted)

        draw.rounded_rectangle((54, 106, 330, 160), radius=8, fill=(12, 44, 70), outline=(46, 113, 155), width=1)
        draw.text((76, 121), "Cloud sync test harness", font=small_font, fill=cyan)
        draw.rounded_rectangle((354, 106, 630, 160), radius=8, fill=(17, 50, 46), outline=(45, 140, 113), width=1)
        draw.text((376, 121), "Swift actors + retry budget", font=small_font, fill=green)
        draw.rounded_rectangle((654, 106, 930, 160), radius=8, fill=(45, 37, 74), outline=(104, 93, 180), width=1)
        draw.text((676, 121), "Python failure triage", font=small_font, fill=(196, 181, 253))

        y = 198
        for line in lines[:visible]:
            if line.startswith("$"):
                fill = green
            elif "passed" in line or "ready" in line:
                fill = blue
            elif "category=" in line or "coverage:" in line:
                fill = cyan
            elif not line:
                y += 15
                continue
            else:
                fill = text
            draw.text((58, y), line, font=font, fill=fill)
            y += 33

        frames.append(image)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(OUT, save_all=True, append_images=frames[1:], duration=250, loop=0, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
