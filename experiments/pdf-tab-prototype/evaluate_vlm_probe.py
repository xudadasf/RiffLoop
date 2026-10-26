"""Compare frozen compact-rhythm responses, retaining malformed/uncertain outputs."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import re

from evaluate_model_probe import timing
from local_model_probe import sha256


def compact_bars(prediction):
    choice = prediction['response']['choices'][0]
    if choice['finish_reason'] != 'stop':
        raise ValueError('Output truncated')
    text = choice['message']['content'].strip()
    fenced = re.fullmatch(r'```(?:json)?\s*([\s\S]*?)\s*```', text)
    data = json.loads(fenced.group(1) if fenced else text)
    if set(data) != {'bars', 'uncertain'} or not isinstance(data['uncertain'], list):
        raise ValueError('Invalid response schema')
    if data['uncertain']:
        raise ValueError('Model reported uncertainty')
    bars = data['bars']
    if not isinstance(bars, list) or not bars:
        raise ValueError('No bars')
    for bar in bars:
        if not isinstance(bar, list) or not bar:
            raise ValueError('Invalid bar')
        for beat in bar:
            if not isinstance(beat, list) or len(beat) != 7 or any(type(x) is not int for x in beat):
                raise ValueError('Unreadable or malformed beat')
            d, dots, n, den, rest, ties, grace = beat
            if (d not in (1, 2, 4, 8, 16, 32, 64) or not 0 <= dots <= 2 or
                    n <= 0 or den <= 0 or rest not in (0, 1) or not 0 <= ties <= 6 or
                    grace not in (0, 1) or (rest and ties)):
                raise ValueError('Invalid rhythm values')
    return bars


def compact_timing(beats, meter):
    result = []
    for d, dots, n, den, rest, ties, grace in beats:
        duration = Fraction(4, d)*(2-Fraction(1, 2**dots))
        if n > 1:
            duration *= Fraction(den, n)
        if len(beats) == 1 and d == 1 and rest:
            duration = Fraction(meter[0]*4, meter[1])
        result.append((duration, bool(grace), bool(rest), ties))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--predictions', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--geometry', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    data = json.loads(args.predictions.read_text(encoding='utf-8'))
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
    expected_ids = [c['id'] for c in manifest]
    if data['manifest_sha256'] != sha256(args.manifest) or [p['id'] for p in data['predictions']] != expected_ids:
        raise ValueError('Incomplete run or wrong manifest')
    geometry = {g['id']: g for g in json.loads(args.geometry.read_text(encoding='utf-8'))}
    entries = {e['case']: e for e in json.loads((args.baseline/'results.json').read_text(encoding='utf-8'))}
    rows = []
    for prediction in data['predictions']:
        if prediction['id'] == 'official-example':
            continue  # Public smoke control; no GP reference, excluded explicitly.
        geo = geometry[prediction['id']]
        if prediction['image_sha256'] != geo['image_sha256']:
            raise ValueError('Image mismatch')
        folder = args.baseline/geo['case']
        system = json.loads((folder/'recognized.json').read_text(encoding='utf-8'))['systems'][geo['system_index']]
        if system['page'] != geo['page'] or system['ys'] != geo['ys']:
            raise ValueError('Staff geometry mismatch')
        reference = json.loads((folder/'reference.json').read_text(encoding='utf-8'))
        tracks = [t for t in reference['tracks'] if t['name'] == entries[geo['case']]['track']]
        if len(tracks) != 1:
            raise ValueError('Ambiguous reference')
        truth_bars = {b['number']: b for b in tracks[0]['bars']}
        row = {'id': prediction['id'], 'expected_bars': len(system['bars']),
               'baseline_timing_pass': [], 'model_timing_pass': [], 'error': None}
        try:
            bars = compact_bars(prediction)
            if len(bars) != len(system['bars']):
                raise ValueError('Bar count mismatch')
        except (ValueError, KeyError, TypeError) as error:
            row['error'] = str(error)
            bars = []
        for i, bar in enumerate(system['bars']):
            truth = truth_bars[bar['number']]
            expected = timing(truth['beats'], truth['meter'])
            if timing(bar['beats'], bar['meter']) == expected:
                row['baseline_timing_pass'].append(bar['number'])
            if bars and compact_timing(bars[i], bar['meter']) == expected:
                row['model_timing_pass'].append(bar['number'])
        rows.append(row)
    totals = {'clips': len(rows), 'bars': sum(r['expected_bars'] for r in rows),
              'invalid_or_uncertain_clips': sum(r['error'] is not None for r in rows),
              'baseline_timing_pass': sum(len(r['baseline_timing_pass']) for r in rows),
              'model_timing_pass': sum(len(r['model_timing_pass']) for r in rows)}
    report = {'predictions_sha256': sha256(args.predictions), 'totals': totals, 'clips': rows}
    args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(totals))


if __name__ == '__main__':
    main()
