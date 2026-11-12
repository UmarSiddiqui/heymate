#!/usr/bin/env python3
"""Check contextual 2D/3D through the installed app's real Talk model.

No fixture drawing code is injected. The requests carry different subject data;
commands, layout diagnostics and fresh window captures are saved for review.
Use --case screen with the MDN Overview of HTTP article visible in Chrome.
"""
import argparse
import json
from pathlib import Path
from live_f1_quality_check import check_edit, run_turn

CASES = {
    'chart': ('Draw a line chart of tickets resolved: Monday 12, Tuesday 8, Wednesday 15, Thursday 9. Explain the largest change. Use only these numbers.', False),
    'timeline': ('Show our launch timeline: design on day 0, prototype on day 2, testing on day 5, release on day 8. Preserve the relative time gaps.', False),
    'flow': ('Our checkout reserves stock successfully, then payment authorization times out. Shipment creation never runs. Explain why the order cannot ship and where retry belongs.', False),
    'lamp': ('Show a desk lamp in 3D: round base, jointed arm, hollow shade and a visible bulb inside. Use blue paint on the shade. Keep the view still.', False),
    'screen': ('Use the HTTP article on my current screen. Explain the relationship between the browser request and server response. Mark the relevant heading, then draw a compact flow in unused space. Keep the article readable.', True),
}


def commands(state):
    return [op for row in state['commandRows'] for op in json.loads(row)['ops']]


def check_layout(state):
    drawing = state.get('drawing2D', {})
    assert not drawing.get('error'), drawing.get('error')
    width, height = state['captureWidth'], state['captureHeight']
    clipped = [item['text'] for item in drawing.get('text', [])
               if item['box'][0] < -2 or item['box'][1] < -2
               or item['box'][0] + item['box'][2] > width + 2
               or item['box'][1] + item['box'][3] > height + 2]
    assert not clipped, 'Clipped text: ' + repr(clipped)
    return {'textCount': len(drawing.get('text', [])), 'warnings': drawing.get('warnings', [])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=['all', *CASES], default='all')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = []
    selected = ['chart', 'timeline', 'flow', 'lamp'] if args.case == 'all' else [args.case]
    for name in selected:
        prompt, capture = CASES[name]
        state = run_turn(prompt, True, args.output, name, True, capture_screen=capture, require_figure=name == 'lamp')
        ops = commands(state)
        result = {'case': name, 'request': prompt, 'layout': check_layout(state), 'visualReviewRequired': True}
        if name != 'lamp':
            assert not state['figures'], 'Abstract data/process should use 2D'
            assert state['drawing2D']['text'], '2D answer has no visible labels'
        if name == 'chart':
            graphs = [op for op in ops if op['op'] == 'graph']
            plots = [op for op in ops if op['op'] == 'call' and op['method'] == 'plot']
            assert graphs and plots, 'Chart needs data-space axes and a plotted series'
            assert any([p[1] for p in op['args'][0]] == [12, 8, 15, 9] for op in plots), 'Chart changed source values'
            result['sourceValuesPreserved'] = True
            series = {op['id'] for op in plots if op.get('id')}
            assert series, 'Chart series needs a retained handle for follow-up edits'
            edit = run_turn('Make only the plotted line red. Keep all data, axes, labels and layout unchanged.',
                            False, args.output, 'chart-edit', True, require_figure=False)
            changes = commands(edit)
            assert changes and all(op['op'] == 'recolor' and op.get('target') in series for op in changes), 'Line edit rebuilt or changed unrelated content'
            assert state['drawing2D']['text'] == edit['drawing2D']['text'], 'Line edit changed labels or their positions'
            assert state['drawing2D']['cards'] == edit['drawing2D']['cards'], 'Line edit changed card layout'
            result['retainedSeriesEdit'] = {'targets': sorted(series), 'layoutPreserved': True}
        if name == 'timeline':
            timelines = [op for op in ops if op['op'] == 'timeline']
            assert timelines, 'Timeline missing'
            events = timelines[0]['args'][3]
            assert [(e[0] if isinstance(e, list) else e.get('date', e.get('at'))) for e in events] == [0, 2, 5, 8]
            assert not (timelines[0]['args'][4] if len(timelines[0]['args']) > 4 else {}).get('even'), 'Timeline discarded time gaps'
            result['sourceDatesPreserved'] = True
        if name == 'flow':
            description = json.dumps(state['commandRows']).lower()
            assert 'payment' in description and ('ship' in description or 'shipment' in description), 'Flow lost the relevant steps'
        if name == 'screen':
            description = json.dumps(state['commandRows']).lower()
            assert 'request' in description and 'response' in description, 'Screen explanation lost the article topic'
            assert state.get('capture', {}).get('pixelWidth', 0) > 0, 'Missing current screen capture'
            assert not state['capture'].get('stale'), 'Screen changed during test'
            assert any(op['op'] in ['ring', 'highlight', 'frame', 'point'] for op in ops), 'Missing screen anchor'
            result['freshScreenUsed'] = True
        if name == 'lamp':
            assert state['native']['meshes'] >= 8 and state['figures'][0]['spin'] == 0
            edit = run_turn('Make the shade bright blue (#3388ff). Preserve everything else.', False, args.output, 'lamp-edit', True)
            result['retainedEdit'] = check_edit(state, edit)
        report.append(result)
        (args.output / 'report.json').write_text(json.dumps(report, indent=2))
        print('PASS:', name, 'protocol, content and layout checks; visual review still required', flush=True)


if __name__ == '__main__':
    main()
