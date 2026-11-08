#!/usr/bin/env python3
"""Exercise the installed app's real screenshot/model/TTS/Metal Talk path.

Run while the named control is visible. No generated drawing source is injected.
Evidence contains this test's requests, scene metadata and playback/paint times.
"""
import argparse
import json
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--target', required=True, help='Description of a control actually visible on the current screen')
parser.add_argument('--output', required=True)
parser.add_argument('--talk', action='store_true')
parser.add_argument('--expiry-regression', action='store_true')
args = parser.parse_args()
base = 'http://127.0.0.1:18732'


def request(path, body=None):
    if path == '/ask' and body is not None:
        body = dict(body, asHeyMateTalk=args.talk)
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data, {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=4) as response:
        return json.load(response)


def wait_for(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = request('/explain/state')
        if predicate(state):
            return state
        time.sleep(0.15)
    raise RuntimeError('Live Talk did not reach the expected scene state')


speech = request('/speech/state')
assert not speech['silentMode'], 'Live speech test requires Silent Mode off'
assert not speech['replyPlaying'], 'Another reply is speaking'
request('/clear', {})
question = (
    f'Look at my actual current screen. Start a NEW scene with startOver. Explain with exactly three spoken drawing beats. '
    f'First ring the real {args.target} and label it Screen control. '
    'Second build a labelled 3D cutaway cylinder and piston in clear space on the right. '
    'Third add and label the connecting rod and crankshaft and animate them together with sliderCrank. '
    'Name the connecting rod command id rod and figure command id engine. '
    'Keep the real control clickable. This is an explanation only.'
)
request('/ask', {'text': question, 'newChat': not args.talk})
samples = []
started = time.monotonic()
while time.monotonic() - started < 90:
    state = request('/explain/state')
    samples.append({
        'elapsed': round(time.monotonic() - started, 3), 'beats': state.get('beats', []),
        'native': state['native'], 'speechPlaying': request('/speech/state')['replyPlaying'],
        'screenHighlightVisible': 'Screen control' in state.get('drawing', ''),
        'captureStale': state.get('capture', {}).get('stale', False),
    })
    beats = state.get('beats', [])
    figures = state.get('figures', [])
    mechanism_ready = len(figures) == 1 and 'sliderCrank' in figures[0].get('motions', [])
    if len(beats) == 3 and all('endedAt' in beat for beat in beats) and state['native'].get('meshes', 0) >= 4 and mechanism_ready:
        break
    time.sleep(0.15)
else:
    raise RuntimeError('Live Talk did not finish three spoken drawing beats')
assert state['capture']['pixelWidth'] > 0, 'Talk did not bind a real screenshot'
assert state['capture'].get('stale') is not True, f"Screen changed during this run: {state['capture'].get('staleReason', 'unknown')}"
assert 'Screen control' in state['drawing'], 'Screen highlight absent from retained scene'
assert state.get('backgroundClickThrough') is True, 'Full-screen drawing intercepted background input'
assert len(state.get('inputWindows', [])) > 0, 'Interactive figure has no bounded input window'
assert all(test['expected'] == test['actual'] for test in state['inputHitTests']), 'WindowServer did not route figure input to its bounded panel'
assert state['backgroundHitWindow'] != state['drawingWindow'], 'WindowServer routed background input to drawing overlay'
assert len(state['figures']) == 1, 'Expected one figure'
figure = state['figures'][0]
assert 'sliderCrank' in figure['motions'], 'Mechanism did not start'
rod = next(part for part in figure['parts'] if 'rod' in part['name'].lower())
for beat in beats:
    visible = beat.get('visualAt', beat.get('nativeAt'))
    assert visible is not None, 'Missing actual visual acknowledgement'
    assert beat['playbackAt'] <= visible <= beat['endedAt'], 'Visual fell outside its spoken beat'
for previous, current in zip(beats, beats[1:]):
    assert previous['endedAt'] <= current['playbackAt'], 'Speech beats overlapped'
assert any(sample['speechPlaying'] for sample in samples), 'No live voice playback observed'
print('PASS: real screen, three spoken beats, visible marks during their beats, moving native meshes', flush=True)

if args.expiry_regression:
    print('Waiting 58 seconds before follow-up to cross the original scene-expiry deadline.', flush=True)
    elapsed_since_speech = time.time() - max(beat['endedAt'] for beat in beats) / 1000
    deadline = time.monotonic() + max(0, 58 - elapsed_since_speech)
    while time.monotonic() < deadline:
        assert request('/explain/state')['showing'], 'Scene expired before its deadline'
        time.sleep(0.25)
# This wording deliberately needs no new screen capture. Existing canvas units,
# figure handles and GPU geometry must survive the follow-up.
followup_started_at = time.time()
request('/ask', {'text': 'Recolor rod red.', 'newChat': False, 'captureScreen': False})

def edited(current):
    if len(current.get('figures', [])) != 1 or len(current.get('beats', [])) != 1:
        return False
    parts = current['figures'][0]['parts']
    updated = next((part for part in parts if part['id'] == rod['id']), None)
    if not updated or not updated['color']:
        return False
    color = updated['color']
    return int(color[:2], 16) > int(color[2:4], 16) * 1.5 and 'endedAt' in current['beats'][0]

followup = wait_for(edited)
if args.expiry_regression:
    original_expiry = max(beat['endedAt'] for beat in beats) / 1000 + 60
    assert followup_started_at < original_expiry < time.time(), 'Follow-up did not cross the old expiry deadline'
updated_figure = followup['figures'][0]
updated_rod = next(part for part in updated_figure['parts'] if part['id'] == rod['id'])
assert updated_rod['geometry'] == rod['geometry'], 'Edit replaced the rod geometry'
assert updated_figure['id'] == figure['id'] and updated_figure['zoom'] == figure['zoom'], 'Edit reset figure or zoom'
assert 'pixelWidth' not in followup['capture'], 'No-capture follow-up unexpectedly took a screenshot'
assert followup['captureWidth'] == state['captureWidth'], 'No-capture follow-up changed canvas units'
assert 'sliderCrank' in updated_figure['motions'], 'Edit stopped mechanism'
print('PASS: live follow-up retained figure, geometry, zoom and running mechanism', flush=True)

interrupt_question = (
    'Draw a fresh piston explanation over seven short spoken beats, adding a few labelled parts in each beat, '
    'then a sliderCrank mechanism. Use heymate drawing data. Start a new scene with startOver.'
)
request('/ask', {'text': interrupt_question, 'newChat': False})
interrupted = wait_for(lambda current: current['showing'] and not current['streamDone'] and current['lines'] >= 1)
request('/clear', {})
# Stay through the final model result, not merely until the first hidden frame.
deadline = time.monotonic() + 90
settled = False
while time.monotonic() < deadline:
    assert not request('/explain/state')['showing'], 'Dismissed response reopened its overlay'
    speech = request('/speech/state')
    settled = not speech['turnInFlight'] and not speech['replyPlaying']
    if settled:
        break
    time.sleep(0.25)
assert settled, 'Interrupted model response did not settle'
print('PASS: Clear interrupted actual model streaming and speech; final chunks kept overlay dismissed', flush=True)
output = {'target': args.target, 'initial': state, 'samples': samples, 'followup': followup,
          'interruptedDuringStream': not interrupted['streamDone'], 'dismissedFinalResponse': settled,
          'crossedOriginalExpiry': args.expiry_regression}
Path(args.output).parent.mkdir(parents=True, exist_ok=True)
Path(args.output).write_text(json.dumps(output, indent=2))
print('Evidence saved to', args.output)
