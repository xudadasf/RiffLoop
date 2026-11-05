import unittest
from types import SimpleNamespace

import cv2
import numpy as np

from raster_string_digits import group_characters, read_string_bands, recover_isolated_digits


class StringDigitTests(unittest.TestCase):
    def make_isolated_digit(self):
        gray = np.full((200, 400), 255, np.uint8)
        ys = [50, 65, 80, 95, 110, 125]
        for y in ys:
            cv2.line(gray, (10, y), (390, y), 0, 1)
        cv2.rectangle(gray, (195, 86), (213, 104), 255, -1)
        cv2.putText(gray, '9', (198, 102), cv2.FONT_HERSHEY_SIMPLEX, .5, 0, 1, cv2.LINE_AA)
        region = {'ys': ys, 'left': 10, 'crop': [0, 0, 400, 200], 'bar_boundaries': [10, 390]}
        return gray, region

    def test_empty_band_can_recover_a_stable_isolated_digit_as_review_required(self):
        gray, region = self.make_isolated_digit()
        def recognizer(crop, **kwargs):
            return SimpleNamespace(txts=['9'] if crop.shape[1] < 80 else [],
                                   scores=[.99] if crop.shape[1] < 80 else [], word_results=[])
        notes, unresolved, discarded, _ = read_string_bands(gray, region, recognizer)
        self.assertEqual([(n['string'], n['fret']) for n in notes], [(4, 9)])
        self.assertTrue(notes[0]['review'])
        self.assertEqual(notes[0]['method'], 'isolated-digit-retry')
        self.assertEqual(unresolved, [])
        self.assertEqual(discarded, [])

    def test_isolated_retry_rejects_disagreement_and_neighboring_string_overlap(self):
        gray, region = self.make_isolated_digit()
        rows = [{'row':'bar1-string4', 'bar':1, 'string':4, 'box':[10,85,390,105], 'text':''}]
        readings = iter([SimpleNamespace(txts=['9'], scores=[.99]), SimpleNamespace(txts=['8'], scores=[.99])])
        self.assertEqual(recover_isolated_digits(gray, region, [], rows, lambda *a, **k: next(readings)), [])
        neighbor = [{'bar':1, 'string':3, 'fret':9, 'x':203}]
        self.assertEqual(recover_isolated_digits(gray, region, neighbor, rows, lambda *a, **k: self.fail('overlap must not be guessed')), [])

    def test_character_spacing_separates_multi_digit_frets(self):
        chars = [{'char': c, 'x': x} for c, x in zip('710811', [10,30,39,60,80,89])]
        self.assertEqual([''.join(v['char'] for v in g) for g in group_characters(chars, 14)], ['7','10','8','11'])

    def test_symbol_between_digits_prevents_joining_into_a_new_fret(self):
        chars = [{'char': c, 'x': x} for c, x in zip('1h0', [10,14,18])]
        self.assertEqual([''.join(v['char'] for v in g) for g in group_characters(chars, 14)], ['1','0'])

    def test_dense_double_digit_frets_split_only_at_distinct_larger_gap(self):
        chars = [{'char': c, 'x': x} for c,x in zip('1113',[0,10.66,24.87,35.53])]
        self.assertEqual([''.join(v['char'] for v in g) for g in group_characters(chars, 16)], ['11','13'])
        ambiguous = [{'char': c, 'x': x} for c,x in zip('1113',[0,10,20,30])]
        self.assertEqual([''.join(v['char'] for v in g) for g in group_characters(ambiguous, 16)], ['1113'])

    def test_direct_band_reader_keeps_isolated_notes_and_records_rejected_band(self):
        region = {'ys': [30,44,58,72,86,100], 'crop': [0,0,220,120], 'bar_boundaries': [0,220]}
        calls = []
        def recognizer(band, **kwargs):
            calls.append(kwargs)
            index = len(calls)
            if index in (5,6,7):
                return SimpleNamespace(txts=['0000'], scores=[.4], word_results=[])
            if index != 8:
                return SimpleNamespace(txts=[''], scores=[0], word_results=[])
            return SimpleNamespace(txts=['A5 8 6 8'], scores=[.999], word_results=[SimpleNamespace(
                words=[['A'],['5'],['8'],['6'],['8']], word_cols=[[2],[10],[30],[50],[70]],
                line_txt_len=100, confs=[.98]*8)])
        notes, unresolved, discarded, raw = read_string_bands(np.full((120,220),255,np.uint8),region,recognizer)
        self.assertEqual([(n['string'],n['fret']) for n in notes], [(6,5),(6,8),(6,6),(6,8)])
        self.assertEqual(unresolved, [])
        self.assertEqual(len(discarded), 1)
        self.assertEqual(discarded[0]['text'], '0000')
        self.assertEqual(discarded[0]['score'], .4)
        self.assertEqual(len(discarded[0]['box']), 4)
        self.assertEqual(len(discarded[0]['attempts']), 3)
        self.assertEqual(len(raw), 6)
        self.assertTrue(all(c['use_det'] is False for c in calls))


if __name__ == '__main__':
    unittest.main()
