"""Evaluation-only note-content audit; timing and playing techniques are excluded."""
import argparse
import json
from pathlib import Path

from evaluate_bar_probe import reference_notes, note_matches
from local_model_probe import sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Preserve previous audit')
    read = lambda path: json.loads(path.read_text(encoding='utf-8'))
    rows, excluded = [], []
    for entry in read(args.baseline/'results.json'):
        case = entry['case']
        if entry['status'] != 'evaluated':
            excluded.append({'case': case, 'reason': entry['status']})
            continue
        folder = args.baseline/case
        pred, ref = read(folder/'recognized.json'), read(folder/'reference.json')
        tracks = [t for t in ref['tracks'] if t['name'] == entry['track']]
        if len(tracks) != 1:
            excluded.append({'case': case, 'reason': 'ambiguous frozen reference track name'})
            continue
        truth = {b['number']: b for b in tracks[0]['bars']}
        bars = {b['number']: b for s in pred['systems'] for b in s['bars']}
        if len(bars) != sum(len(s['bars']) for s in pred['systems']):
            raise ValueError('Duplicate recognized bar numbers')
        row = {'case': case, 'pairing': entry['pairing_checks']['status'], 'bars': 0,
               'exact_note_groups': 0, 'reference_notes': 0, 'predicted_notes': 0, 'matched_notes': 0,
               'missing_bars': len(truth.keys()-bars.keys()), 'extra_bars': len(bars.keys()-truth.keys()),
               'prediction_sha256': sha256(folder/'recognized.json'), 'reference_sha256': sha256(folder/'reference.json')}
        for number in sorted(truth.keys() | bars.keys()):
            expected = reference_notes(truth[number]['beats']) if number in truth else []
            actual = reference_notes(bars[number]['beats']) if number in bars else []
            row['bars'] += 1
            row['exact_note_groups'] += number in truth and number in bars and actual == expected
            row['reference_notes'] += sum(map(len, expected))
            row['predicted_notes'] += sum(map(len, actual))
            row['matched_notes'] += note_matches(actual, expected)
        rows.append(row)
    report = {'scope': 'Primary voice string/fret/dead groups and order, including tie-destination notes; '
                      'not timing/rest/tie/technique correctness. Missing/extra bars retained; '
                      'ambiguous frozen track names excluded, never reselected.',
              'baseline_results_sha256': sha256(args.baseline/'results.json'), 'rows': rows, 'excluded': excluded}
    for pairing in ('all', 'consistent', 'uncertain'):
        selected = [r for r in rows if pairing == 'all' or r['pairing'] == pairing]
        totals = {k: sum(r[k] for r in selected) for k in ('bars', 'exact_note_groups', 'reference_notes',
                  'predicted_notes', 'matched_notes', 'missing_bars', 'extra_bars')}
        totals['cases'] = len(selected)
        report[pairing] = totals
    args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report['consistent']))


if __name__ == '__main__':
    main()
