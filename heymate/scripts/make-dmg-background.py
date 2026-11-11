#!/usr/bin/env python3
"""Draw the animated Retina background for the 660×400-point Finder window.

Run on macOS with Pillow:
    python3 scripts/make-dmg-background.py dmg-background.png
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


WIDTH, HEIGHT = 660, 400
SCALE = 4
SIZE = WIDTH * SCALE, HEIGHT * SCALE
CURSOR_BLUE = "#3380FF"  # AppTheme.defaultHex
HAND_FONT = Path(__file__).resolve().parents[1] / "HeyMate/PatrickHand-Regular.ttf"


def scaled(values):
    return tuple(round(value * SCALE) for value in values)


def route(progress):
    return 228 + 191 * progress, 200 - 12 * math.sin(progress * math.pi * 0.85)


def layout():
    image = Image.new("RGB", SIZE, "#F7FAFE")
    draw = ImageDraw.Draw(image)

    # Lead from the HeyMate icon at (160, 200) to Applications at (500, 200).
    for step in range(12):
        t = step / 11
        x, y = route(t * 168 / 191)
        radius = 1.5 + t * 0.5
        draw.ellipse(scaled((x - radius, y - radius, x + radius, y + radius)),
                     fill="#97BFFB")

    # One instruction, using the same typeface as the in-app Buddy captions.
    caption = "Drag HeyMate into Applications"
    font = ImageFont.truetype(str(HAND_FONT), 21 * SCALE)
    cx, cy = scaled((330, 128))
    half_width = round(draw.textlength(caption, font=font) / 2) + 14 * SCALE
    draw.rounded_rectangle((cx - half_width, cy - 17 * SCALE,
                            cx + half_width, cy + 17 * SCALE),
                           radius=12 * SCALE, fill="#E8F1FF")
    draw.text((cx, cy), caption, font=font, fill="#1C3D6F", anchor="mm")
    return image


def frame(base, progress):
    image = base.copy()
    cx, cy = route(progress)
    # CompanionCursorShape's normalized vertices, rotated to point right.
    vertices = [(0.50, 0.04), (0.08, 0.92), (0.50, 0.66), (0.92, 0.92)]
    points = [scaled((cx + (0.5 - y) * 29, cy + (x - 0.5) * 29))
              for x, y in vertices]
    glow = Image.new("L", SIZE)
    ImageDraw.Draw(glow).polygon(points, fill=86)
    image.paste(CURSOR_BLUE, (0, 0, *SIZE), glow.filter(ImageFilter.GaussianBlur(7 * SCALE)))
    ImageDraw.Draw(image).polygon(points, fill=CURSOR_BLUE)
    return image.resize((WIDTH * 2, HEIGHT * 2), Image.Resampling.LANCZOS)


def save_background(path):
    base = layout()
    flight = []
    for step in range(21):
        t = step / 20
        flight.append(frame(base, t * t * (3 - 2 * t)))
    durations = [80] * (len(flight) - 1) + [2600]
    # The standalone PNG image points at Applications in static viewers.
    # Finder uses the density for logical size and plays the APNG frames.
    flight[-1].save(path, dpi=(144, 144), optimize=True, save_all=True,
                    default_image=True, append_images=flight,
                    duration=durations, loop=1)


if __name__ == "__main__":
    save_background(sys.argv[1])
