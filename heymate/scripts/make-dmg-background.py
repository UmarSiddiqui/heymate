#!/usr/bin/env python3
"""Draws dmg-background.png, the 660x400 backdrop of the HeyMate DMG window.

The icon wells sit where scripts/release.sh places the icons (y=195, x=160
and x=500). Needs Pillow and the Inter font.

    python3 scripts/make-dmg-background.py dmg-background.png
"""
import math, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
S = 3                      # supersample, then downscale for smooth edges
W, H = 660, 400
img = Image.new("RGB", (W*S, H*S))
px = img.load()
top, bottom = (250, 250, 251), (238, 238, 242)
for y in range(H*S):
    t = y / (H*S - 1)
    c = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    for x in range(W*S):
        px[x, y] = c
d = ImageDraw.Draw(img)
# Soft wells under the two icon positions (create-dmg places icons at y=195).
glow = Image.new("L", (W*S, H*S), 0)
gd = ImageDraw.Draw(glow)
for cx in (160, 500):
    r = 78
    gd.ellipse([(cx-r)*S, (195-r)*S, (cx+r)*S, (195+r)*S], fill=255)
glow = glow.filter(ImageFilter.GaussianBlur(28*S))
white = Image.new("RGB", img.size, (255, 255, 255))
img = Image.composite(white, img, glow.point(lambda v: int(v*0.7)))
d = ImageDraw.Draw(img)
# A gentle arc from the app to Applications, ending in a chevron.
ink = (120, 120, 130)
x0, x1, y, lift = 248, 412, 200, 30
pts = []
for i in range(121):
    t = i / 120
    pts.append(((x0 + (x1 - x0) * t) * S, (y - lift * math.sin(math.pi * t)) * S))
width = round(3 * S)
d.line(pts, fill=ink, width=width, joint="curve")
for p in (pts[0], pts[-1]):
    r = width / 2
    d.ellipse([p[0]-r, p[1]-r, p[0]+r, p[1]+r], fill=ink)
# The chevron follows the arc's tangent where it lands.
slope = lift * math.pi / (x1 - x0)
ang = math.atan2(slope, 1)
tip = pts[-1]
for side in (+1, -1):
    a = ang + math.pi + side * math.radians(42)
    end = (tip[0] + 15 * S * math.cos(a), tip[1] + 15 * S * math.sin(a))
    d.line([tip, end], fill=ink, width=width)
    r = width / 2
    d.ellipse([end[0]-r, end[1]-r, end[0]+r, end[1]+r], fill=ink)
font = ImageFont.truetype("/usr/share/fonts/opentype/inter/Inter-Medium.otf", 15*S)
text = "Drag HeyMate into Applications"
tw = d.textlength(text, font=font)
d.text(((W*S - tw)/2, 318*S), text, font=font, fill=(110, 110, 120))
img = img.resize((W, H), Image.LANCZOS)
img.save(sys.argv[1], optimize=True)
