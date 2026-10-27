import unittest

from raster_digit_probe import group_glyphs


class DigitGroupingTests(unittest.TestCase):
    def test_two_digit_frets_stay_separate_from_neighboring_notes(self):
        groups = group_glyphs('81191011', [
            (0, 9), (30, 33), (38, 41), (60, 69),
            (90, 93), (98, 107), (125, 128), (133, 136),
        ])
        self.assertEqual([g['fret'] for g in groups], [8, 11, 9, 10, 11])

    def test_spaced_single_digits_are_not_joined(self):
        groups = group_glyphs('888', [(0, 9), (25, 34), (50, 59)])
        self.assertEqual([g['fret'] for g in groups], [8, 8, 8])

    def test_missing_glyph_rejects_row_instead_of_dropping_character(self):
        with self.assertRaisesRegex(ValueError, '字符数'):
            group_glyphs('810', [(0, 9), (25, 34)])

    def test_only_narrow_digits_cannot_establish_fret_boundaries(self):
        with self.assertRaisesRegex(ValueError, '窄数字'):
            group_glyphs('111', [(0, 3), (8, 11), (25, 28)])

    def test_invalid_join_is_not_silently_split_into_plausible_notes(self):
        for chars, spans in [
            ('88', [(0, 9), (11, 20)]),
            ('08', [(0, 9), (11, 20)]),
            ('888', [(0, 9), (11, 20), (22, 31)]),
        ]:
            with self.subTest(chars=chars), self.assertRaisesRegex(ValueError, '歧义'):
                group_glyphs(chars, spans)


if __name__ == '__main__':
    unittest.main()
