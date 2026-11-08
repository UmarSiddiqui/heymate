#!/usr/bin/env python3
"""Original MIT-licensed, flat-color fixtures; requires Pillow only to regenerate."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent / 'assets'


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    first = Image.new('RGB', (320, 240), 'white')
    draw = ImageDraw.Draw(first)
    draw.polygon([(160, 35), (235, 78), (235, 162), (160, 205), (85, 162), (85, 78)], fill='#167D8D')
    draw.polygon([(160, 75), (200, 98), (200, 142), (160, 165), (120, 142), (120, 98)], fill='white')
    draw.rectangle((149, 109, 171, 131), fill='#EF7046')
    first.save(ROOT / 'sample-logo-a.png', optimize=True)
    second = Image.new('RGB', (320, 240), 'white')
    draw = ImageDraw.Draw(second)
    draw.ellipse((70, 30, 250, 210), fill='#7251B5')
    draw.ellipse((104, 64, 216, 176), fill='white')
    draw.polygon([(160, 84), (190, 145), (130, 145)], fill='#F08B35')
    second.save(ROOT / 'sample-logo-b.png', optimize=True)


if __name__ == '__main__':
    main()
