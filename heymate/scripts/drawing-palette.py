#!/usr/bin/env python3
"""HeyMate's drawing palette, defined in OKLCH and written out as sRGB hex.

Each tone is (lightness, chroma, hue in degrees). Lightness sits on 0.05 steps and chroma on 0.03 steps, so the
tones keep even perceptual distances; the hue is the colour the name means. TONES are Mate's ink and fills (2D
drawings); REAL_TONES are the muted colours real things have, for 3D figures. A colour outside sRGB loses chroma until
it fits. mate-draw-engine.js (TONES, REAL_TONES, COLOR_WORDS) and DrawingBrush.swift use these values:

    python3 scripts/drawing-palette.py          print the tables
    python3 scripts/drawing-palette.py --check  fail if the engine or the Swift brushes differ from them
"""
import math, pathlib, sys

TONES = {
    'ink': (0.3, 0.012, 265),
    'grey': (0.6, 0.012, 265),
    'butter': (0.9, 0.15, 95),
    'sun': (0.85, 0.15, 80),
    'orange': (0.8, 0.15, 60),
    'peach': (0.85, 0.09, 40),
    'coral': (0.65, 0.15, 25),
    'red': (0.6, 0.18, 25),
    'pink': (0.8, 0.12, 0),
    'lilac': (0.7, 0.12, 290),
    'violet': (0.55, 0.18, 285),
    'sky': (0.7, 0.15, 250),
    'blue': (0.5, 0.18, 260),
    'mint': (0.8, 0.12, 155),
    'leaf': (0.6, 0.12, 150),
    'brown': (0.55, 0.09, 55),
    'tan': (0.75, 0.09, 65),
    'cream': (0.95, 0.03, 90),
    'teal': (0.6, 0.09, 185),
    'turquoise': (0.7, 0.12, 185),
}
REAL_TONES = {
    'white': (0.95, 0.012, 90),
    'ink': (0.3, 0.012, 270),
    'grey': (0.6, 0.012, 260),
    'butter': (0.85, 0.09, 90),
    'sun': (0.75, 0.12, 85),
    'orange': (0.6, 0.15, 50),
    'peach': (0.75, 0.06, 50),
    'coral': (0.6, 0.12, 30),
    'red': (0.45, 0.15, 30),
    'pink': (0.65, 0.09, 10),
    'lilac': (0.65, 0.06, 295),
    'violet': (0.45, 0.12, 295),
    'sky': (0.7, 0.06, 240),
    'blue': (0.4, 0.09, 255),
    'mint': (0.75, 0.06, 155),
    'leaf': (0.5, 0.09, 140),
    'brown': (0.4, 0.06, 60),
    'tan': (0.65, 0.06, 65),
    'cream': (0.9, 0.03, 85),
}


def lin_to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def oklch_rgb(L, C, H):
    a, b = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l, m, s = ((L + 0.3963377774 * a + 0.2158037573 * b) ** 3, (L - 0.1055613458 * a - 0.0638541728 * b) ** 3,
               (L - 0.0894841775 * a - 1.2914855480 * b) ** 3)
    return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]


def to_hex(L, C, H):
    for _ in range(60):
        rgb = oklch_rgb(L, C, H)
        if all(-1e-4 <= v <= 1 + 1e-4 for v in rgb):
            break
        C *= 0.95
    return '#' + ''.join(f'{round(lin_to_srgb(min(1, max(0, v))) * 255):02X}' for v in rgb)


def table(spec):
    return {name: to_hex(*lch) for name, lch in spec.items()}


if __name__ == '__main__':
    tones, real = table(TONES), table(REAL_TONES)
    tones['white'] = '#FFFFFF'                          # paper white is plain white
    if '--check' not in sys.argv:
        print('TONES', tones)
        print('REAL_TONES', real)
        sys.exit(0)
    root = pathlib.Path(__file__).resolve().parents[1]
    engine = (root / 'HeyMate/mate-draw-engine.js').read_text()
    brushes = (root / 'HeyMate/DrawingBrush.swift').read_text()
    block = lambda name: engine[engine.index(f'const {name} = {{'):engine.index('};', engine.index(f'const {name} = {{'))]
    wrong = []
    for name, hex_ in tones.items():
        if name in ('teal', 'turquoise'):
            if f"{name}: '{hex_}'" not in engine: wrong.append(f'engine COLOR_WORDS {name}')
            continue
        if f"{name}: '{hex_}'" not in block('TONES'): wrong.append(f'engine TONES {name}')
        if name not in ('ink', 'white') and f'case .{name}: return Color(hex: "{hex_}")' not in brushes: wrong.append(f'DrawingBrush {name}')
    for name, hex_ in real.items():
        if f"{name}: '{hex_}'" not in block('REAL_TONES'): wrong.append(f'engine REAL_TONES {name}')
    print('\n'.join(wrong) if wrong else 'palette matches')
    sys.exit(1 if wrong else 0)
