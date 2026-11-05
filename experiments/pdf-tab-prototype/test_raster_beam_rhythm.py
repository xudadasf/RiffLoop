import unittest
from fractions import Fraction
from pathlib import Path
import tempfile
from PIL import Image
from unittest.mock import patch

import cv2
import numpy as np

from raster_beam_rhythm import fill_bar, prepare_image_score, read_beamed_notes, read_plain_stems, validate_bar_timing


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


def shared_beams():
    gray = np.full((180, 240), 255, np.uint8)
    for y in range(60, 131, 14):
        cv2.line(gray, (10, y), (230, y), 0, 1)
    notes = []
    for x in (40, 70, 100):
        notes.append({'bar': 1, 'x': x, 'y': 130, 'string': 6, 'fret': 7,
                      'box': [[x-5,122],[x+5,122],[x+5,138],[x-5,138]]})
        cv2.line(gray, (x, 87), (x, 121), 0, 2)
    for y in (87, 99):
        cv2.rectangle(gray, (40, y), (105, y+5), 0, -1)
    gray[106:115, 68:73] = 255  # A lightly broken middle stem.
    return gray, notes, {'ys': list(range(60, 131, 14)), 'crop': [0, 0, 240, 180]}


def plain_stem():
    gray = np.full((220, 260), 255, np.uint8)
    ys = [40, 55, 70, 85, 100, 115]
    for y in ys:
        cv2.line(gray, (10, y), (250, y), 0, 1)
    cv2.line(gray, (80, 78), (80, 150), 0, 2)
    notes = [{'bar':1, 'x':80, 'string':3, 'fret':5,
              'box':[[75,62],[85,62],[85,78],[75,78]]}]
    return gray, notes, {'ys':ys, 'crop':[0,0,260,220], 'bar_boundaries':[10,250]}


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

    def test_possible_cutoff_is_saved_in_the_gp_review_data(self):
        gray, notes, region = example()
        region.update(expected_bars=1, right_may_be_cut=True)
        data = {'manual_settings': {'tempo': 100, 'meter': [4,4], 'tuning': [64,59,55,50,45,40]},
                'systems': [{'id': 'p1-s1', 'page': 1, 'region': region, 'notes': notes, 'unresolved': []}]}
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            Image.fromarray(gray).save(folder/'p1-s1.png')
            bar = prepare_image_score(data, folder)['systems'][0]['bars'][0]
            self.assertTrue(any('谱行右侧可能被截断' in issue for issue in bar['issues']))

    def test_counts_visible_beams_instead_of_dividing_bar_by_note_count(self):
        gray, notes, region = example((1, 2, 1, 2))
        result = read_beamed_notes(gray, notes, region)
        self.assertEqual([r['duration'] for r in result], [8, 16, 8, 16])

    def test_downward_beams_are_read(self):
        gray, notes, region = example(down=True)
        self.assertEqual([r['duration'] for r in read_beamed_notes(gray, notes, region)], [16]*4)

    def test_plain_stem_proposes_reviewable_quarter_note(self):
        gray, notes, region = plain_stem()
        result = read_plain_stems(gray, notes, region, [{'duration':None}])[0]
        self.assertEqual(result['duration'], 4)
        self.assertEqual(result['source'], 'image-stem')
        self.assertTrue(result['review_reason'])

    def test_plain_stem_rejects_beam_dot_or_tuplet_bracket(self):
        for mark in ('beam-left','beam-right','flag','dot','bracket'):
            gray, notes, region = plain_stem()
            if mark == 'beam-left':
                cv2.rectangle(gray, (55,145), (80,150), 0, -1)
            elif mark == 'beam-right':
                cv2.rectangle(gray, (80,145), (105,150), 0, -1)
            elif mark == 'flag':
                cv2.ellipse(gray, (82,140), (7,9), 0, -75, 75, 0, 2)
            elif mark == 'dot':
                cv2.circle(gray, (88,148), 2, 0, -1)
            else:
                cv2.line(gray, (50,165), (120,165), 0, 1)
            with self.subTest(mark=mark):
                self.assertIsNone(read_plain_stems(gray, notes, region, [{'duration':None}])[0]['duration'])

    def test_new_stem_evidence_does_not_shift_other_default_notes(self):
        gray = np.full((220, 400), 255, np.uint8)
        region = {'ys':[40,55,70,85,100,115], 'crop':[0,0,400,220],
                  'bar_boundaries':[0,400], 'expected_bars':1}
        notes = [{'bar':1, 'x':20+i*40, 'string':3, 'fret':i,
                  'box':[[20+i*40,60],[25+i*40,60],[25+i*40,80],[20+i*40,80]]} for i in range(8)]
        data = {'manual_settings': {'tempo':100,'meter':[4,4],'tuning':[64,59,55,50,45,40]},
                'systems':[{'id':'p1-s1','page':1,'region':region,'notes':notes,'unresolved':[]}]}
        old = [{'duration':None} for _ in notes]
        proposed = [{'duration':4,'source':'image-stem','review_reason':'待核对'}] + old[1:]
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); Image.fromarray(gray).save(folder/'p1-s1.png')
            with patch('raster_beam_rhythm.read_beamed_notes',return_value=old), \
                 patch('raster_beam_rhythm.read_plain_stems',return_value=proposed):
                beats = prepare_image_score(data, folder)['systems'][0]['bars'][0]['beats']
        self.assertEqual([b['duration'] for b in beats], [8]*8)
        self.assertTrue(all(b['placeholder'] for b in beats))

    def test_unconnected_lines_are_not_rhythm_evidence(self):
        gray, notes, region = example(stems=False)
        self.assertTrue(all(r['duration'] is None for r in read_beamed_notes(gray, notes, region)))

    def test_note_position_slightly_outside_beam_is_matched_to_its_stem(self):
        gray, notes, region = example()
        notes[0]['x'] -= 5
        self.assertEqual(read_beamed_notes(gray, notes, region)[0]['duration'], 16)

    def test_weak_stem_requires_same_bar_and_same_beam_group(self):
        gray, notes, region = shared_beams()
        readings = read_beamed_notes(gray, notes, region)
        self.assertEqual([r['duration'] for r in readings], [16, 16, 16])
        self.assertTrue(readings[1]['review_reason'])
        self.assertIsNone(read_beamed_notes(gray, [notes[1]], region)[0]['duration'])
        other_bar = [{**notes[0], 'bar': 2}, notes[1], {**notes[2], 'bar': 2}]
        self.assertIsNone(read_beamed_notes(gray, other_bar, region)[1]['duration'])

    def test_adjacent_partial_beam_is_not_attributed_to_an_unconnected_stem(self):
        gray = np.full((180, 240), 255, np.uint8)
        for y in range(60, 131, 14):
            cv2.line(gray, (10, y), (230, y), 0, 1)
        notes = []
        for x in (40, 70, 100):
            notes.append({'bar': 1, 'x': x, 'y': 130, 'string': 6, 'fret': 7,
                          'box': [[x-5,122],[x+5,122],[x+5,138],[x-5,138]]})
            cv2.line(gray, (x, 87), (x, 121), 0, 2)
        cv2.rectangle(gray, (40, 87), (105, 92), 0, -1)
        cv2.rectangle(gray, (40, 99), (65, 104), 0, -1)
        region = {'ys': list(range(60, 131, 14)), 'crop': [0, 0, 240, 180]}
        readings = read_beamed_notes(gray, notes, region)
        self.assertEqual([r['duration'] for r in readings], [16, None, 8])

    def test_weak_reading_stays_marked_for_review(self):
        gray, notes, region = shared_beams()
        beats, issues = fill_bar(notes, read_beamed_notes(gray, notes, region), [4, 4])
        self.assertFalse(beats[1]['placeholder'])
        self.assertTrue(beats[1]['rhythm_review'])
        self.assertTrue(any('第 2 项' in issue and '符干' in issue for issue in issues))

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
