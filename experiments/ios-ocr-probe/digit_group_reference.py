"""Generate synthetic grouping results from the existing desktop rule.

No user image or model data is read. The source path must be supplied by the
caller; output is created exclusively and never overwrites an existing file.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys


CASES = (
    ('single_and_double', 14, [('7', 10, True), ('1', 30, True), ('0', 39, True),
                               ('8', 60, True), ('1', 80, True), ('1', 89, True)]),
    ('symbol_barrier', 14, [('1', 10, True), ('h', 14, True), ('0', 18, True)]),
    ('unknown_barrier', 14, [('1', 10, True), (None, 14, True), ('0', 18, True)]),
    ('outside_barrier', 14, [('1', 10, True), ('7', 14, False), ('0', 18, True)]),
    ('dense_distinct', 16, [('1', 0, True), ('1', 10.66, True),
                            ('1', 24.87, True), ('3', 35.53, True)]),
    ('dense_ambiguous', 16, [('1', 0, True), ('1', 10, True), ('1', 20, True), ('3', 30, True)]),
    ('leading_zero', 20, [('0', 4, True), ('1', 10, True)]),
    ('over_fret_limit', 20, [('3', 4, True), ('7', 10, True)]),
    ('join_threshold', 20, [('1', 0, True), ('0', 19, True), ('2', 38.001, True)]),
    ('non_ascii_digit', 14, [('1', 0, True), ('٣', 5, True), ('2', 10, True)]),
    ('empty', 14, ()),
)


def reference(source):
    source = Path(source).resolve(strict=True)
    if source.name != 'raster_string_digits.py':
        raise ValueError('Expected the existing raster_string_digits.py')
    sys.path.insert(0, str(source.parent))
    spec = importlib.util.spec_from_file_location('riffloop_desktop_group_reference', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cases = []
    for name, gap, raw in CASES:
        items = [{'char': char, 'x': x, 'isWithinSource': inside} for char, x, inside in raw]
        # Desktop accepts only strings. Unknown/outside items deliberately
        # become non-digit barriers for parity; they are separately reported.
        desktop = [{'char': item['char'] if item['char'] is not None and item['isWithinSource'] else '?',
                    'x': item['x'], 'index': i} for i, item in enumerate(items)]
        groups = []
        for group in module.group_characters(desktop, gap):
            text = ''.join(item['char'] for item in group)
            valid = len(text) <= 2 and not (len(text) > 1 and text.startswith('0')) and int(text) <= 36
            groups.append({'inputIndices': [item['index'] for item in group],
                           'text': text, 'fret': int(text) if valid else None})
        unresolved = [{'inputIndex': i, 'reason': 'outsideSource' if not item['isWithinSource'] else 'unknownCharacter'}
                      for i, item in enumerate(items) if not item['isWithinSource'] or item['char'] is None]
        cases.append({'name': name, 'gap': gap, 'input': items, 'groups': groups, 'unresolved': unresolved})
    return {'scope': 'Synthetic grouping only; not real note accuracy', 'cases': cases}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop-source', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    result = reference(args.desktop_source)
    with Path(args.output).open('x', encoding='utf-8', newline='\n') as out:
        json.dump(result, out, ensure_ascii=False, indent=2)
        out.write('\n')
