import unittest
from types import SimpleNamespace

import numpy as np

from raster_string_digits import group_characters, read_string_bands


class StringDigitTests(unittest.TestCase):
    def test_character_spacing_separates_multi_digit_frets(self):
        chars = [{'char': c, 'x': x} for c, x in zip('710811', [10,30,39,60,80,89])]
        self.assertEqual([''.join(v['char'] for v in g) for g in group_characters(chars, 14)], ['7','10','8','11'])

    def test_symbol_between_digits_prevents_joining_into_a_new_fret(self):
        chars = [{'char': c, 'x': x} for c, x in zip('1h0', [10,14,18])]
        self.assertEqual([''.join(v['char'] for v in g) for g in group_characters(chars, 14)], ['1','0'])

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
        self.assertEqual(len(raw), 6)
        self.assertTrue(all(c['use_det'] is False for c in calls))


if __name__ == '__main__':
    unittest.main()
