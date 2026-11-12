#!/usr/bin/env python3
"""Run the real Talk model/renderer and check a retained F1 colour edit.

Use after build_and_run.sh --verify, with Talk idle. Screenshots capture only
HeyMate's drawing window and stay in the supplied local evidence directory.
This does not inject a hand-authored model or change the selected AI provider.
"""
import argparse
import json
import math
import os
import subprocess
import time
import urllib.request
from pathlib import Path

PROMPT = 'Draw a red Formula 1 car in 3D, front three-quarter view, with visible suspension, cockpit and wings.'
EDIT = 'Make front wing blue; preserve everything else.'
PORT = int(os.environ.get('HEYMATE_BRIDGE_PORT', '18732'))
assert 0 < PORT <= 65535, 'HEYMATE_BRIDGE_PORT must be a valid local port'
BASE = 'http://127.0.0.1:' + str(PORT)


def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data, {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=8) as response:
        return json.load(response)


def run_turn(text, fresh, output, label, screenshot, capture_screen=False, require_figure=True):
    speech = request('/speech/state')
    assert not speech['turnInFlight'] and not speech['replyPlaying'], 'Talk is busy; do not interrupt another conversation'
    if fresh:
        request('/clear', {})
    request('/ask', {'text': text, 'newChat': fresh, 'asHeyMateTalk': True, 'captureScreen': capture_screen})
    started = time.monotonic()
    previous = None
    while time.monotonic() - started < 240:
        state, speech = request('/explain/state'), request('/speech/state')
        signature = (state['lines'], state.get('native', {}).get('meshes'), speech['turnInFlight'], speech['replyPlaying'])
        if signature != previous:
            print(label, round(time.monotonic() - started, 1), signature, flush=True)
            previous = signature
        if state['showing']:
            (output / (label + '-state.json')).write_text(json.dumps(state, indent=2))
        beats = state.get('beats', [])
        finished_beats = len(beats) == state['lines'] and all(beat.get('endedAt') for beat in beats)
        if time.monotonic() - started > 3 and not speech['turnInFlight'] and not speech['replyPlaying'] and finished_beats:
            assert not state.get('validationError'), state.get('validationError')
            assert state['showing'] and state['streamDone'], 'Model did not finish a visible drawing'
            if require_figure:
                assert state['figures'], 'Model did not produce a 3D figure'
            time.sleep(1)  # Let the last part finish its reveal animation.
            state = request('/explain/state')
            (output / (label + '-state.json')).write_text(json.dumps(state, indent=2))
            if screenshot:
                subprocess.run(['screencapture', '-x', '-o', '-l', str(state['drawingWindow']),
                                str(output / (label + '-drawing.png'))], check=True)
            return state
        time.sleep(0.5)
    raise TimeoutError('Real Talk did not finish within four minutes')


def check_edit(before, after):
    assert len(before['figures']) == len(after['figures']) == 1
    a, b = before['figures'][0], after['figures'][0]
    assert a.get('interaction') == b.get('interaction'), 'Manual orbit/zoom overlapped the colour check; rerun with the drawing untouched'
    for key in ['id', 'yaw', 'tilt', 'zoom', 'spin', 'fov', 'target']:
        assert a[key] == b[key], 'Colour-only edit changed ' + key
    old, new = ({p['id']: p for p in f['parts']} for f in [a, b])
    assert old.keys() == new.keys(), 'Colour-only edit added or removed parts'
    changed = []
    for key, part in old.items():
        updated = new[key]
        for field in part.keys() - {'color'}:
            assert part[field] == updated[field], 'Colour-only edit changed ' + field
        if part['color'] != updated['color']:
            red, green, blue = (int(updated['color'][i:i+2], 16) for i in [0, 2, 4])
            assert blue > red * 1.3 and blue > green, 'Edited part is not blue'
            changed.append({'id': key, 'name': part['name'], 'before': part['color'], 'after': updated['color']})
    assert changed, 'Requested part colour did not change'
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--screenshots', action='store_true')
    parser.add_argument('--views', action='store_true', help='Also ask for front and side views, then restore three-quarter')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    initial = run_turn(PROMPT, True, args.output, 'f1', args.screenshots)
    camera = initial['figures'][0]
    yaw = (math.degrees(camera['yaw']) + 180) % 360 - 180
    assert 15 <= abs(yaw) <= 65, 'Initial view is not front three-quarter'
    assert 0 < math.degrees(camera['tilt']) <= 40, 'Initial view does not show the requested cockpit'
    assert camera['spin'] == 0, 'Requested view is rotating'
    edited = run_turn(EDIT, False, args.output, 'blue-wing', args.screenshots)
    changed = check_edit(initial, edited)
    report = {'prompt': PROMPT, 'edit': EDIT, 'meshes': initial['native']['meshes'], 'changedParts': changed,
              'retainedGeometryAndCamera': True, 'visualReviewRequired': True, 'views': []}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2))
    print('PASS: real model, visible native meshes, blue edit, unchanged geometry and camera; inspect changed parts and screenshots', flush=True)
    if args.views:
        for label, prompt in [('front', 'Show the same car directly from the front. Keep it still. Change only the camera.'),
                              ('side', 'Show the same car directly from the side. Keep it still. Change only the camera.'),
                              ('three-quarter', 'Return to front three-quarter view, turn 35 degrees and tilt 18 degrees, spin zero. Change only the camera.')]:
            view = run_turn(prompt, False, args.output, label, args.screenshots)
            figure = view['figures'][0]
            assert len(view['figures']) == 1 and figure['id'] == edited['figures'][0]['id']
            for old, new in zip(edited['figures'][0]['parts'], figure['parts']):
                assert old == new, 'Camera-only request changed a part'
            assert len(figure['parts']) == len(edited['figures'][0]['parts'])
            angle = math.degrees(figure['yaw'])
            expected = 0 if label == 'front' else 90 if label == 'side' else 35
            assert math.isclose(abs(angle) if label == 'side' else angle, expected, abs_tol=0.1), 'Requested view was not applied'
            assert figure['spin'] == 0, 'Requested still view is rotating'
            report['views'].append({'view': label, 'yaw': angle, 'tilt': math.degrees(figure['tilt']), 'retainedParts': True})
            (args.output / 'report.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
