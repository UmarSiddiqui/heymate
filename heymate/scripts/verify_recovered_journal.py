#!/usr/bin/env python3
"""Check retained original journal bytes and their adapter-only module boundary."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
manifest = json.loads((root / 'heymate/scripts/recovered-journal-provenance.json').read_text())
target = (root / manifest['target']).read_bytes()
assert hashlib.sha256(target).hexdigest() == manifest['targetSHA256'], 'Recovered journal module changed'
source = root / manifest['segments'][0]['source']
if source.exists():
    original = source.read_bytes()
    assert hashlib.sha256(original).hexdigest() == manifest['sourceSHA256'], 'Recovered original bundle changed'
    for segment in manifest['segments']:
        data = original[segment['startByte']:segment['endByte']]
        assert hashlib.sha256(data).hexdigest() == segment['sha256'], 'Original journal source range changed'
        assert data in target, 'Original journal bytes missing from port'
    print('PASS original emitted journal ranges and target SHA-256')
else:
    print('PASS pinned journal target SHA-256 (private original bundle unavailable)')
