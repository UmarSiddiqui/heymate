#!/usr/bin/env python3
"""Read-only audit of pinned CodeNotch originals and HeyMate adaptations."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

local = Path(__file__).resolve().parents[1] / 'HeyMate' / 'Codenotch'
manifest = json.loads((local / 'upstream-manifest.json').read_text())
source = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None
if source is None:
    sys.exit('usage: codenotch_source_diff.py /path/to/upstream-checkout')
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if revision != manifest['revision']:
    sys.exit(f'Checkout revision differs from pinned {manifest["revision"]}: {revision}')
for entry in manifest['files']:
    original = (source / entry['upstream']).read_bytes()
    if hashlib.sha256(original).hexdigest() != entry['sha256']:
        sys.exit(f'Original source changed: {entry["upstream"]}')
    adapted = (local / entry['file']).read_text()
    sys.stdout.writelines(difflib.unified_diff(original.decode().splitlines(True), adapted.splitlines(True),
        fromfile=entry['upstream'], tofile='HeyMate/Codenotch/' + entry['file']))
