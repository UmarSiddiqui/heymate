#!/usr/bin/env python3
"""Inspect source review status; this advisory check is not wired to release paths."""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
try:
    inventory = json.loads((root / 'publication-sources.json').read_text())
    unresolved = inventory['unresolved']
    if inventory['schema'] != 1 or not isinstance(unresolved, list):
        raise ValueError('Unsupported source inventory')
    if inventory['reviewStatus'] != 'approved' or unresolved:
        print('Source review incomplete: source provenance review is incomplete.', file=sys.stderr)
        for entry in unresolved:
            print(f"  {entry['path']}: {entry['status']}", file=sys.stderr)
        sys.exit(1)
    if not inventory.get('reviewEvidence'):
        raise ValueError('Approved source review requires recorded evidence')
except (OSError, ValueError, KeyError, TypeError) as error:
    print(f'Source review incomplete: invalid source review: {error}', file=sys.stderr)
    sys.exit(1)
print('Source review approved; retained dependency licenses still apply.')
