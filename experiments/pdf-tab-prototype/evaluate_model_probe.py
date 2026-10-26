"""Evaluation-only: compare frozen model tokens to GP, with misses in denominator.

This is local beat timing, not full MIDI playback, tempo or repeat validation.
Bar-count or structural errors fail the entire crop; never realign to hide them.
"""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import re

from local_model_probe import sha256


def parse_tokens(tokens):
    bars, bar, beat, note = [], None, None, None
    for token in tokens:
        if token == 'BAR':
            if bar is not None:
                raise ValueError('Nested bar')
            bar, beat, note = [], None, None
        elif token == 'END_BAR':
            if not bar:
                raise ValueError('Missing or empty bar')
            bars.append(bar)
            bar, beat, note = None, None, None
        elif token == 'BEAT':
            if bar is None:
                raise ValueError('Beat outside bar')
            beat = {'duration': None, 'dots': 0, 'tuplet': [1, 1], 'grace': False, 'notes': []}
            bar.append(beat)
            note = None
        elif token.startswith(('DUR_', 'DOTS_', 'TUPLET_', 'N_S')) or token in ('REST', 'NTECH_TIE_DEST'):
            if beat is None:
                raise ValueError('Content outside beat')
            if token.startswith('DUR_'):
                if beat['duration'] is not None:
                    raise ValueError('Duplicate duration')
                beat['duration'] = int(token[4:])
            elif token.startswith('DOTS_'):
                beat['dots'] = int(token[5:])
            elif token.startswith('TUPLET_'):
                beat['tuplet'] = list(map(int, token[7:].split('_')))
            elif token.startswith('N_S'):
                match = re.fullmatch(r'N_S([1-6])_F(\d+|X)', token)
                if not match or beat.get('rest'):
                    raise ValueError('Invalid note or rest mixed with note')
                string, fret = match.groups()
                # Upstream uses alphaTab numbering (6 = highest TAB line).
                note = {'string': 7-int(string), 'fret': None if fret == 'X' else int(fret),
                        'dead': fret == 'X', 'tie': False}
                if any(n['string'] == note['string'] for n in beat['notes']):
                    raise ValueError('Duplicate string')
                beat['notes'].append(note)
            elif token == 'REST':
                if beat['notes']:
                    raise ValueError('Rest mixed with notes')
                beat['rest'] = True
            elif token == 'NTECH_TIE_DEST':
                if note is None:
                    raise ValueError('Tie without note')
                note['tie'] = True
    if bar is not None or not bars:
        raise ValueError('Incomplete or absent bars')
    for beats in bars:
        for beat in beats:
            if not beat['duration'] or not (beat['notes'] or beat.get('rest')):
                raise ValueError('Incomplete beat')
    return bars


def timing(beats, meter=None):
    beats = [b for b in beats if b.get('voice', 0) == 0]
    events = []
    for beat in beats:
        if not beat.get('duration'):
            return None
        n, d = beat['tuplet']
        duration = Fraction(4, beat['duration']) * (2-Fraction(1, 2**beat['dots']))
        if n > 1:
            duration *= Fraction(d, n)
        if meter and len(beats) == 1 and not beat['notes'] and (
                beat.get('fullBarRest') or beat.get('empty') or beat['duration'] == 1):
            duration = Fraction(meter[0]*4, meter[1])
        events.append((duration, beat['grace'], not beat['notes'],
                       sum(bool(note.get('tie')) for note in beat['notes'])))
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--predictions', type=Path, required=True)
    parser.add_argument('--geometry', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    predictions = json.loads(args.predictions.read_text(encoding='utf-8'))
    geometry = json.loads(args.geometry.read_text(encoding='utf-8'))
    by_id = {p['id']: p for p in predictions['predictions']}
    if len(by_id) != len(predictions['predictions']) or set(by_id) != {g['id'] for g in geometry}:
        raise ValueError('Missing, extra or duplicated predictions')
    baseline = {e['case']: e for e in json.loads((args.baseline/'results.json').read_text(encoding='utf-8'))}
    rows = []
    for geo in geometry:
        prediction = by_id[geo['id']]
        if prediction['image_sha256'] != geo['image_sha256']:
            raise ValueError('Image mismatch')
        folder = args.baseline/geo['case']
        recognized = json.loads((folder/'recognized.json').read_text(encoding='utf-8'))
        system = recognized['systems'][geo['system_index']]
        if system['page'] != geo['page'] or system['ys'] != geo['ys']:
            raise ValueError('Staff geometry mismatch')
        entry = baseline[geo['case']]
        reference = json.loads((folder/'reference.json').read_text(encoding='utf-8'))
        tracks = [t for t in reference['tracks'] if t['name'] == entry['track']]
        if len(tracks) != 1:
            raise ValueError('Ambiguous baseline track')
        reference_bars = {b['number']: b for b in tracks[0]['bars']}
        row = {'id': geo['id'], 'pairing': entry['pairing_checks']['status'],
               'expected_bars': len(system['bars']), 'baseline_timing_pass': [], 'model_timing_pass': [],
               'model_core_pass': [], 'error': None}
        try:
            if not prediction['eos'] or not prediction['upstream_structure_valid']:
                raise ValueError('Incomplete or structurally invalid prediction')
            model_bars = parse_tokens(prediction['tokens'])
            row['model_bars'] = len(model_bars)
            if len(model_bars) != len(system['bars']):
                raise ValueError('Bar count mismatch')
        except ValueError as error:
            row['error'] = str(error)
            model_bars = []
        for i, bar in enumerate(system['bars']):
            reference_bar = reference_bars[bar['number']]
            truth = timing(reference_bar['beats'], reference_bar['meter'])
            if timing(bar['beats'], bar['meter']) == truth:
                row['baseline_timing_pass'].append(bar['number'])
            # Full-bar rests use PDF meter context, never the GP meter as input.
            if model_bars and timing(model_bars[i], bar['meter']) == truth:
                row['model_timing_pass'].append(bar['number'])
                notes = lambda bs: [sorted((n['string'], n['fret'], n.get('dead', False), n.get('tie', False))
                                          for n in b['notes']) for b in bs if b.get('voice', 0) == 0]
                if notes(model_bars[i]) == notes(reference_bar['beats']):
                    row['model_core_pass'].append(bar['number'])
        rows.append(row)
    totals = {'clips': len(rows), 'bars': sum(r['expected_bars'] for r in rows),
              'structural_or_bar_count_failures': sum(r['error'] is not None for r in rows)}
    for metric in ('baseline_timing_pass', 'model_timing_pass', 'model_core_pass'):
        totals[metric] = sum(len(r[metric]) for r in rows)
    totals['model_new_timing_pass'] = sum(len(set(r['model_timing_pass'])-set(r['baseline_timing_pass'])) for r in rows)
    totals['model_lost_timing_pass'] = sum(len(set(r['baseline_timing_pass'])-set(r['model_timing_pass'])) for r in rows)
    report = {'predictions_sha256': sha256(args.predictions),
              'scope': 'exploratory fixed crops; primary-voice durations/rests/grace/tie counts; not playback accuracy',
              'totals': totals, 'clips': rows}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(totals))


if __name__ == '__main__':
    main()
