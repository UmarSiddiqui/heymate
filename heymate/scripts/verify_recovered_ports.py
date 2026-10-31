#!/usr/bin/env python3
"""Verify pinned engine bytes and original note functions; optionally inspect installed app."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
target = parser.add_mutually_exclusive_group()
target.add_argument('--installed', action='store_true')
target.add_argument('--bundle', type=Path, help='Inspect a built bundle without installing or launching it')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
pins = json.loads((root / 'scripts/recovered-port-hashes.json').read_text())
resources = (args.bundle or Path('/Applications/HeyMate.app')) / 'Contents/Resources'
inspect_bundle = args.installed or args.bundle is not None
for name, expected in pins['files'].items():
    if name in pins.get('replaced', {}):
        continue  # Historical pin; independently rewritten (see the manifest's replaced entry).
    local = root / name
    assert hashlib.sha256(local.read_bytes()).hexdigest() == expected, f'Engine changed: {name}'
    if inspect_bundle:
        installed = resources / ('BrowserExtension/mate-core.mjs' if name.startswith('browser/') else Path(name).name)
        assert installed.read_bytes() == local.read_bytes(), f'Installed engine differs: {name}'
    print('PASS', name)
if 'agent-runtime/src/notes.mjs' not in pins.get('replaced', {}):
    notes = (root / 'agent-runtime/src/notes.mjs').read_text()
    block = notes[notes.index('function la(e)'):notes.index('\n\n\nvar ns')]
    assert hashlib.sha256(block.encode()).hexdigest() == pins['noteEditingFunctions'], 'Recovered note functions changed'
    print('PASS recovered note-editing functions')
# Additional H1 ports have separate range manifests; preserve the original six
# engine pins and note block rather than silently repinning changed sources.
orchestration = json.loads((root / 'scripts/recovered-h1-orchestration-hashes.json').read_text())
source = root.parent / orchestration['source']
original = source.read_bytes() if source.exists() else None
if original is not None:
    assert hashlib.sha256(original).hexdigest() == orchestration['sourceSHA256'], 'Original H1 bundle changed'
for entry in orchestration['modules']:
    if entry['module'] == 'agent-runtime/src/recovered-h1-early-reads.mjs':
        continue  # Historical manifest entry; independently replaced.
    data = (root / entry['module']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry['moduleSHA256'], 'Recovered H1 orchestration module changed'
    if original is not None:
        block = original[entry['startByte']:entry['endByte']]
        assert hashlib.sha256(block).hexdigest() == entry['sourceSHA256'] and block in data, 'Original H1 orchestration bytes missing'
print('PASS recovered H1 script source range')
shader_pins = json.loads((root / 'scripts/native-shaders/provenance.json').read_text())
assert hashlib.sha256((root / 'scripts/native-shaders/davinci.metal').read_bytes()).hexdigest() == shader_pins['sourceSHA256'], 'Recovered native shader source changed'
assert (root / 'HeyMate/DaVinciShaders.txt').read_bytes() == (root / 'scripts/native-shaders/davinci.metal').read_bytes(), 'Bundled Metal source differs'
print('PASS recovered native shader source hash and native resource')
if inspect_bundle:
    for name in ['mate-host.js', 'mate-stage3d.js', 'mate-metal-bridge.js', 'DaVinciShaders.txt', 'three-r159.min.js']:
        assert (resources / name).read_bytes() == (root / 'HeyMate' / name).read_bytes(), f'Installed wrapper differs: {name}'
    for name in ['harness.mjs', 'notes.mjs', 'pi-session.mjs', 'batch-reads.mjs', 'note-workflow.mjs',
                 'early-reads.mjs', 'recovered-h1-script.mjs', 'script-tools.mjs',
                 'telemetry.mjs', 'step-journal.mjs']:
        assert (resources / 'MateAgent/src' / name).read_bytes() == (root / 'agent-runtime/src' / name).read_bytes(), f'Installed runtime differs: {name}'
    for name in ['background.js', 'manifest.json']:
        assert (resources / 'BrowserExtension' / name).read_bytes() == (root / 'browser/extension' / name).read_bytes(), f'Installed browser wrapper differs: {name}'
    for name in ['package.json', 'package-lock.json']:
        assert (resources / 'MateAgent' / name).read_bytes() == (root / 'agent-runtime' / name).read_bytes(), f'Installed runtime dependency lock differs: {name}'
    print('PASS bundle wrappers and note runtime')
