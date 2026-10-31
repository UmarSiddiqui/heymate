#!/usr/bin/env python3
"""Verify historical journal provenance without requiring the removed port."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
manifest = json.loads((root / 'heymate/scripts/recovered-journal-provenance.json').read_text())
target = root / manifest['target']
if target.exists():
    raise SystemExit('Recovered journal module still exists; replacement is incomplete.')
source = root / manifest['segments'][0]['source']
if source.exists():
    original = source.read_bytes()
    assert hashlib.sha256(original).hexdigest() == manifest['sourceSHA256'], 'Historical bundle changed'
    for segment in manifest['segments']:
        data = original[segment['startByte']:segment['endByte']]
        assert hashlib.sha256(data).hexdigest() == segment['sha256'], 'Historical source range changed'
    print('PASS historical journal source hashes; recovered module absent')
else:
    print('PASS recovered module absent; historical source unavailable for hash verification')
