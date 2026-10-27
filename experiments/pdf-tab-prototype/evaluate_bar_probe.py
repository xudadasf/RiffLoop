"""Evaluate frozen per-bar image predictions. GP is opened only in this step."""
import argparse
import json
from pathlib import Path
import re

from evaluate_model_probe import timing
from evaluate_vlm_probe import compact_bars, compact_timing
from local_model_probe import sha256


def note_groups(prediction):
    choice = prediction['response']['choices'][0]
    if choice['finish_reason'] != 'stop':
        raise ValueError('Incomplete output')
    text = choice['message']['content'].strip()
    fence = re.fullmatch(r'```(?:json)?\s*([\s\S]*?)\s*```', text)
    data = json.loads(fence.group(1) if fence else text)
    if (not isinstance(data, dict) or set(data) != {'groups', 'uncertain'} or
            data['uncertain'] != [] or not isinstance(data['groups'], list)):
        raise ValueError('Uncertain or invalid notes')
    groups = []
    for group in data['groups']:
        if not isinstance(group, list) or not group:
            raise ValueError('Unreadable note group')
        notes = []
        for note in group:
            if not isinstance(note, list) or len(note) != 3:
                raise ValueError('Invalid note')
            string, fret, dead = note
            if (type(string) is not int or not 1 <= string <= 6 or type(dead) is not bool or
                    (dead and fret is not None) or
                    (not dead and (type(fret) is not int or not 0 <= fret <= 36))):
                raise ValueError('Invalid string/fret/dead values')
            if any(n[0] == string for n in notes):
                raise ValueError('Duplicate string within chord')
            notes.append((string, fret, dead))
        groups.append(sorted(notes, key=lambda n: n[0]))
    return groups


def reference_notes(beats):
    return [sorted(((n['string'], None if n.get('dead') else n['fret'], bool(n.get('dead')))
                    for n in b['notes']), key=lambda n: n[0])
            for b in beats if b.get('voice', 0) == 0 and b['notes']]


def note_matches(actual, expected):
    """Ordered LCS count: repeated notes consume distinct reference positions.

    This diagnostic ignores chord grouping; strict bar equality below does not.
    It never changes predictions or repairs exported material.
    """
    left, right = [n for g in actual for n in g], [n for g in expected for n in g]
    previous = [0]*(len(right)+1)
    for note in left:
        row = [0]
        for i, other in enumerate(right):
            row.append(previous[i]+1 if note == other else max(row[-1], previous[i+1]))
        previous = row
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('predictions', 'manifest', 'geometry', 'baseline', 'output'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--mode', choices=('rhythm', 'notes'), required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Preserve frozen comparisons')
    read = lambda path: json.loads(path.read_text(encoding='utf-8'))
    data, manifest, geometry = read(args.predictions), read(args.manifest), read(args.geometry)
    ids = [c['id'] for c in manifest]
    if (len(set(ids)) != len(ids) or data['manifest_sha256'] != sha256(args.manifest) or
            [p['id'] for p in data['predictions']] != ids or [g['id'] for g in geometry] != ids):
        raise ValueError('Missing, duplicated or reordered predictions/geometry')
    by_id = {p['id']: p for p in data['predictions']}
    entries = {e['case']: e for e in read(args.baseline/'results.json')}
    parents = {}
    for geo in geometry:
        if by_id[geo['id']]['image_sha256'] != geo['image_sha256']:
            raise ValueError('Image changed')
        parents.setdefault(geo['parent_id'], []).append(geo)
    rows = []
    for parent_id, crops in parents.items():
        first = crops[0]
        folder = args.baseline/first['case']
        system = read(folder/'recognized.json')['systems'][first['system_index']]
        if system['page'] != first['page'] or system['ys'] != first['ys']:
            raise ValueError('Staff geometry mismatch')
        tracks = [t for t in read(folder/'reference.json')['tracks'] if t['name'] == entries[first['case']]['track']]
        if len(tracks) != 1:
            raise ValueError('Ambiguous reference track')
        truth = {b['number']: b for b in tracks[0]['bars']}
        layout_ok = (len(crops) == len(system['bars']) and
                     [c['bar_index'] for c in crops] == list(range(len(system['bars']))) and
                     all(c['parent_bar_count'] == len(crops) and
                         abs(c['left']-b['left']) < .1 and abs(c['right']-b['right']) < .1
                         for c, b in zip(crops, system['bars'])))
        for index, bar in enumerate(system['bars']):
            ref = truth[bar['number']]
            expected_notes = reference_notes(ref['beats'])
            row = {'parent_id': parent_id, 'bar_number': bar['number'], 'error': None,
                   'baseline_pass': False, 'model_pass': False}
            if args.mode == 'notes':
                row.update(reference_notes=sum(map(len, expected_notes)), predicted_notes=0, matched_notes=0)
                row['baseline_pass'] = reference_notes(bar['beats']) == expected_notes
            else:
                row['baseline_pass'] = timing(bar['beats'], bar['meter']) == timing(ref['beats'], ref['meter'])
            try:
                if not layout_ok:
                    raise ValueError('PDF segmentation mismatch; whole parent fails')
                prediction = by_id[crops[index]['id']]
                if args.mode == 'notes':
                    groups = note_groups(prediction)
                    row.update(model_pass=groups == expected_notes, predicted_notes=sum(map(len, groups)),
                               matched_notes=note_matches(groups, expected_notes))
                else:
                    bars = compact_bars(prediction)
                    if len(bars) != 1:
                        raise ValueError('Expected exactly one measure')
                    row['model_pass'] = compact_timing(bars[0], bar['meter']) == timing(ref['beats'], ref['meter'])
            except (ValueError, KeyError, TypeError) as error:
                row['error'] = str(error)
            rows.append(row)
    totals = {'bars': len(rows), 'invalid_bars': sum(r['error'] is not None for r in rows)}
    for key in ('baseline_pass', 'model_pass'):
        totals[key] = sum(r[key] for r in rows)
    totals['new_passes'] = sum(r['model_pass'] and not r['baseline_pass'] for r in rows)
    totals['lost_passes'] = sum(r['baseline_pass'] and not r['model_pass'] for r in rows)
    if args.mode == 'notes':
        for key in ('reference_notes', 'predicted_notes', 'matched_notes'):
            totals[key] = sum(r[key] for r in rows)
        totals['ordered_note_precision'] = totals['matched_notes']/totals['predicted_notes'] if totals['predicted_notes'] else None
        totals['ordered_note_recall'] = totals['matched_notes']/totals['reference_notes'] if totals['reference_notes'] else None
        totals['nonempty_bars_pass'] = sum(r['model_pass'] and r['reference_notes'] > 0 for r in rows)
    report = {'mode': args.mode, 'predictions_sha256': sha256(args.predictions),
              'geometry_sha256': sha256(args.geometry), 'totals': totals, 'bars': rows}
    args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(totals))


if __name__ == '__main__':
    main()
