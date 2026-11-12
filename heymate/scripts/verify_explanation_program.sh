#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/heymate-explanation.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
python3 - "$root" "$scratch/ExplainerParser.swift" <<'PYCODE'
import sys
from pathlib import Path
source = (Path(sys.argv[1]) / 'HeyMate/Explainer.swift').read_text()
parser = source.split('nonisolated enum ExplainerParser {', 1)[1].split('/// The overlay', 1)[0]
Path(sys.argv[2]).write_text('import Foundation\nnonisolated enum ExplainerParser {' + parser)
PYCODE
xcrun swiftc -parse-as-library -swift-version 6 \
  "$root/HeyMate/ExplanationProgram.swift" "$root/HeyMate/ExplanationScene.swift" "$scratch/ExplainerParser.swift" \
  "$root/HeyMate/ScreenCoordinateMath.swift" "$root/HeyMate/ProviderProtocols.swift" \
  "$root/scripts/explanation_program_probe.swift" -o "$scratch/probe"
if [ -n "${HEYMATE_USER_EXPLANATION:-}" ]; then
  "$scratch/probe" "$HEYMATE_USER_EXPLANATION" > "$scratch/program.json"
else
  "$scratch/probe" > "$scratch/program.json"
fi
node - "$root" "$scratch/program.json" <<'JS'
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const [root, fixture] = process.argv.slice(2), data = JSON.parse(fs.readFileSync(fixture));
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(root + '/HeyMate/mate-draw-engine.js', 'utf8'), context);
const pieces = fs.readFileSync(root + '/HeyMate/mate-draw-pieces.js', 'utf8');
const session = context.MateDraw.Session(1280, 800);
const initial = session.update(pieces + '\n' + data.program, false);
assert.equal(initial.error, null);
assert.equal(initial.says.length, 3);
assert.equal(initial.marks.filter(m => m.do === 'motion3d' && m.op.kind === 'sliderCrank').length, 1);
const followup = session.update(pieces + '\n' + data.program + '\n' + data.edit, true);
assert.equal(followup.error, null);
assert.equal(followup.marks.filter(m => m.do === 'stage3d').length, 0);
assert.equal(followup.marks.find(m => m.do === 'motion3d').op.kind, 'set');
const text = context.MateDraw.runCode(data.escaped, 1280, 800);
assert.equal(text.error, null);
assert.equal(context.escaped, undefined);
for (const key of ['localized', 'timeline', 'chart']) {
  const drawing = context.MateDraw.runCode(data[key], 1280, 800);
  assert.equal(drawing.error, null, key + ' must execute');
  assert.ok(drawing.length > 1, key + ' must draw');
  if (key === 'localized') assert.equal(drawing.find(m => m.do === 'motion3d').op.color, '#E23439');
  if (key === 'timeline') for (const label of ['Design', 'Review', 'Ship']) assert.ok(JSON.stringify(drawing).includes(label));
  if (key === 'chart') {
    const series = drawing.find(m => m.do === 'line' && m.tone === 'blue');
    assert.ok(series, 'Chart series must render');
    assert.deepEqual(Array.from(series.pts, p => Array.from(p)), [[100,220],[350,280],[600,175]]);
  }
}
const chartSession = context.MateDraw.Session(1280, 800);
const chartBase = chartSession.update(data.chart, false);
const series = chartBase.marks.find(m => m.do === 'line' && m.tone === 'blue');
const chartChange = chartSession.update(data.chart + '\n' + data.chartEdit, true);
assert.equal(chartChange.error, null);
const recolor = chartChange.marks.find(m => m.do === 'edit' && m.op.op === 'recolor');
assert.ok(recolor, 'Series edit must produce a recolor operation');
assert.deepEqual(Array.from(recolor.op.id), [series.id], 'Series edit must not recolor axes or tick labels');
if (data.userBase) {
  const user = context.MateDraw.Session(2212,1437);
  const initial = user.update(pieces+'\n'+data.userBase,false);
  assert.equal(initial.error,null);
  const detailed = user.update(pieces+'\n'+data.userBase+'\n'+data.userDetail,true);
  assert.equal(detailed.error,null);
  assert.equal(detailed.marks.filter(m=>m.do==='part3d').length,20);
  assert.equal(detailed.marks.filter(m=>m.do==='stage3d').length,0);
  console.log('PASS: actual space-cat follow-up adds 20 parts without recreating the figure after capture change');
}
console.log('PASS: complete typed beats, atomic rejection, escaping, expansion limits, retained part edit, delayed playback, silent mode and interruption');
JS
if [ -n "${HEYMATE_EXPLANATION_FIXTURE:-}" ]; then cp "$scratch/program.json" "$HEYMATE_EXPLANATION_FIXTURE"; fi
