import unittest
from fractions import Fraction
from pathlib import Path
import tempfile
from PIL import Image

import cv2
import numpy as np

from raster_beam_rhythm import fill_bar, prepare_image_score, read_beamed_notes, validate_bar_timing


def example(beam_counts=(2, 2, 2, 2), stems=True, down=False):
    gray = np.full((180, 240), 255, np.uint8)
    for y in range(60, 131, 14):
        cv2.line(gray, (10, y), (230, y), 0, 1)
    notes = []
    for index, count in enumerate(beam_counts):
        x = 35 + index * 50
        y = 74 if down else 130
        notes.append({'bar': 1, 'x': x, 'y': y, 'string': 2 if down else 6,
                      'fret': 7, 'box': [[x-5,y-8],[x+5,y-8],[x+5,y+8],[x-5,y+8]]})
        if stems:
            cv2.line(gray, (x, y+9 if down else 87), (x, 119 if down else y-9), 0, 2)
        for level in range(count):
            beam_y = (105 + level*12) if down else (87 + level*12)
            cv2.rectangle(gray, (x, beam_y), (x+24, beam_y+5), 0, -1)
    region = {'ys': list(range(60, 131, 14)), 'crop': [0, 0, 240, 180]}
    return gray, notes, region


class BeamRhythmTests(unittest.TestCase):
    def test_chinese_output_path_does_not_silently_replace_readable_beams(self):
        gray, notes, region = example()
        region['expected_bars'] = 1
        data = {'manual_settings': {'tempo': 100, 'meter': [4,4], 'tuning': [64,59,55,50,45,40]},
                'systems': [{'id': 'p1-s1', 'page': 1, 'region': region, 'notes': notes, 'unresolved': []}]}
        with tempfile.TemporaryDirectory(prefix='中文谱图-') as temp:
            folder = Path(temp)
            Image.fromarray(gray).save(folder / 'p1-s1.png')
            score = prepare_image_score(data, folder)
            beats = score['systems'][0]['bars'][0]['beats']
            self.assertTrue(all(b['rhythm_source'] == 'image-beams' and not b['placeholder'] for b in beats[:4]))

    def test_counts_visible_beams_instead_of_dividing_bar_by_note_count(self):
        gray, notes, region = example((1, 2, 1, 2))
        result = read_beamed_notes(gray, notes, region)
        self.assertEqual([r['duration'] for r in result], [8, 16, 8, 16])

    def test_downward_beams_are_read(self):
        gray, notes, region = example(down=True)
        self.assertEqual([r['duration'] for r in read_beamed_notes(gray, notes, region)], [16]*4)

    def test_unconnected_lines_are_not_rhythm_evidence(self):
        gray, notes, region = example(stems=False)
        self.assertTrue(all(r['duration'] is None for r in read_beamed_notes(gray, notes, region)))

    def test_incomplete_recognition_is_not_reported_as_confirmed_meter(self):
        self.assertEqual(validate_bar_timing([16]*16, [4, 4]), None)
        self.assertIsNotNone(validate_bar_timing([16]*15, [4, 4]))
        self.assertIsNotNone(validate_bar_timing([16]*16, [3, 4]))
        self.assertIsNotNone(validate_bar_timing([None]*16, [4, 4]))
        self.assertEqual(validate_bar_timing([8]*6, [6, 8]), None)

    def test_unknowns_use_marked_defaults_without_overflowing(self):
        notes = [{'string': 6, 'fret': 5} for _ in range(16)]
        beats, issues = fill_bar(notes, [{'duration': None}]*16, [4, 4])
        self.assertEqual([b['duration'] for b in beats], [16]*16)
        self.assertTrue(all(b['placeholder'] and b['rhythm_source'] == 'manual-default' for b in beats))
        self.assertTrue(issues)

    def test_evidence_is_preserved_when_only_one_duration_is_unknown(self):
        notes = [{'string': 5, 'fret': 7} for _ in range(16)]
        readings = [{'duration': 16, 'evidence': {'beam_count': 2}} for _ in notes]
        readings[2] = {'duration': None}
        beats, _ = fill_bar(notes, readings, [4, 4])
        self.assertEqual([i for i, b in enumerate(beats) if b['placeholder']], [2])
        self.assertEqual([b['duration'] for b in beats], [16]*16)
        self.assertEqual(beats[0]['rhythm_evidence']['beam_count'], 2)
        self.assertIsNone(beats[2]['rhythm_evidence'])

    def test_missing_notes_use_marked_rest_not_invented_open_strings(self):
        beats, issues = fill_bar([{'string': 2, 'fret': 10}], [{'duration': 16}], [4, 4])
        self.assertEqual(sum(len(b['notes']) for b in beats), 1)
        self.assertTrue(all(not b['notes'] and b['placeholder'] for b in beats[1:]))
        total = sum(Fraction(4, b['duration'])*sum(Fraction(1,2**i) for i in range(b['dots']+1)) for b in beats)
        self.assertEqual(total, 4)
        self.assertTrue(issues)

    def test_conflicting_recognized_durations_are_explicitly_demoted(self):
        beats, issues = fill_bar([{'string': 1, 'fret': 8}]*16, [{'duration': 8}]*16, [4, 4])
        self.assertTrue(all(b['placeholder'] and b['duration'] == 16 for b in beats))
        self.assertIn('冲突', issues[0])


if __name__ == '__main__':
    unittest.main()
