#!/usr/bin/env python3
"""Render approved Mischief SVG into app, extension, website and marketing assets.

Run from any directory: python3 heymate/scripts/generate_brand_assets.py
Requires Pillow. The SVG remains the source of truth; no external kit is needed.
"""
from pathlib import Path
import json
import re
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'heymate/docs/notch-mischief.svg'
BLUE = '#A8CBFA'
INK = '#191919'
DARK = '#0A0A0A'
NS = '{http://www.w3.org/2000/svg}'


def sample_path(data):
    tokens = re.findall(r'[MLQC]|-?\d+(?:\.\d+)?', data)
    points, i, current = [], 0, (0, 0)
    while i < len(tokens):
        command = tokens[i]
        i += 1
        count = {'M': 2, 'L': 2, 'Q': 4, 'C': 6}[command]
        values = list(map(float, tokens[i:i + count]))
        i += count
        controls = list(zip(values[::2], values[1::2]))
        if command in ('M', 'L'):
            current = controls[0]
            points.append(current)
            continue
        start = current
        for step in range(1, 65):
            t = step / 64
            if command == 'Q':
                a, b = controls
                point = tuple((1-t)**2*start[k] + 2*(1-t)*t*a[k] + t*t*b[k] for k in (0, 1))
            else:
                a, b, c = controls
                point = tuple((1-t)**3*start[k] + 3*(1-t)**2*t*a[k] + 3*(1-t)*t*t*b[k] + t**3*c[k] for k in (0, 1))
            points.append(point)
        current = controls[-1]
    return points


def icon(size, paths, stroke, background=INK, mac=False):
    side = max(1024, size * 3)
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    inset = side * 0.075 if mac else 0
    tile = side - inset * 2
    draw.rounded_rectangle((inset, inset, side-inset-1, side-inset-1), radius=tile*0.22, fill=background)
    frame = tile * 0.82
    scale = frame / 128
    origin = (side-frame) / 2
    radius = stroke * scale / 2
    for data in paths:
        points = [(origin+x*scale, origin+y*scale) for x, y in sample_path(data)]
        draw.line(points, fill=BLUE, width=round(stroke*scale), joint='curve')
        for x, y in points:
            draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=BLUE)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def main():
    svg = ET.parse(SOURCE).getroot()
    assert svg.get('viewBox') == '0 0 128 128'
    paths = [p.attrib['d'] for p in svg.findall(f'.//{NS}path')]
    assert len(paths) == 4
    stroke = float(svg.find(f'{NS}g').get('stroke-width'))
    assert stroke == 9
    outputs = []

    def save(path, size, background=INK, mac=False):
        target = ROOT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        icon(size, paths, stroke, background, mac).save(target, optimize=True)
        outputs.append({'path': path, 'pixels': size, 'background': background, 'macPadding': mac})

    for name, suffix, background in [('AppIcon', 'v8', INK), ('AppIconDark', 'dark-v8', DARK)]:
        folder = f'heymate/HeyMate/Assets.xcassets/{name}.appiconset'
        contents = json.loads((ROOT / folder / 'Contents.json').read_text())
        for filename in sorted({i['filename'] for i in contents['images']}):
            size = int(filename.split('-')[0])
            save(f'{folder}/{filename}', size, background, mac=True)

    for appearance, background in [('Light', INK), ('Dark', DARK)]:
        save(f'heymate/HeyMate/Assets.xcassets/BrandIcon{appearance}.imageset/brand-icon-{appearance.lower()}.png', 1024, background)
    for size in (16, 48, 128):
        save(f'heymate/HeyMate/BrowserExtension/icon-{size}.png', size)
        save(f'heymate/browser/extension/icon-{size}.png', size)
    for filename, size in [('favicon-32.png', 32), ('favicon-mischief-32.png', 32), ('apple-touch.png', 180), ('apple-touch-mischief.png', 180), ('icon-192.png', 192), ('icon-mischief-192.png', 192)]:
        save(f'website/assets/img/icon/{filename}', size)
    save('docs/media/heymate-icon.png', 256)
    for path in ('marketing/demo-video/public/icon.png', 'marketing/demo-video/clip-a/public/icon.png'):
        save(path, 1024)

    # The same native vector is available for downstream web and marketing use.
    for path in ('website/assets/img/icon/heymate-mischief.svg', 'marketing/demo-video/public/heymate-mischief.svg'):
        target = ROOT / path
        target.write_text(SOURCE.read_text())
    manifest = {'source': str(SOURCE.relative_to(ROOT)), 'primary': '05 Mischief', 'color': BLUE, 'outputs': outputs}
    (ROOT / 'heymate/docs/brand-assets.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Generated {len(outputs)} PNG assets and 2 SVG copies from {SOURCE.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
