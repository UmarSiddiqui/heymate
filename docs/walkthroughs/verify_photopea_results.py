#!/usr/bin/env python3
"""Check actual Photopea exports against the shareable flat-color inputs."""
from collections import Counter
import hashlib
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent


def main():
    results = []
    for sample in ('a', 'b'):
        original = ROOT / 'assets' / f'sample-logo-{sample}.png'
        exported = ROOT / 'assets' / f'sample-logo-{sample}-transparent.png'
        source = Image.open(original).convert('RGB')
        result = Image.open(exported).convert('RGBA')
        assert source.size == result.size == (320, 240)
        totals = Counter()
        for before, after in zip(source.getdata(), result.getdata()):
            background = before == (255, 255, 255)
            totals['transparent_background_pixels' if background else 'unchanged_logo_pixels'] += 1
            assert after[3] == (0 if background else 255), 'Background or logo alpha mismatch'
            if not background:
                assert after[:3] == before, 'A logo pixel changed color'
        results.append({'sample': sample, 'width': 320, 'height': 240, **dict(totals),
                        'input_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
                        'export_sha256': hashlib.sha256(exported.read_bytes()).hexdigest(),
                        'alpha_mismatches': 0, 'color_mismatches': 0})
    print(json.dumps(results, indent=2))
    (ROOT / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
