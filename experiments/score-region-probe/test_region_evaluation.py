import unittest

from region_evaluation import Box, assess
from synthetic_pages import Staff, make_page


class RegionAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.first = Box(10, 20, 110, 60)
        self.second = Box(10, 100, 110, 140)

    def test_one_to_one_complete_and_missing(self):
        result = assess([self.first, self.second], [Box(8, 18, 112, 62)])
        self.assertEqual(result.matched, ((0, 0),))
        self.assertEqual(result.missing, (1,))
        self.assertEqual(result.truncated, ())

    def test_partial_and_two_fragments_are_distinguished_from_missing(self):
        partial = assess([self.first], [Box(10, 20, 60, 60)])
        self.assertEqual(partial.truncated, (0,))
        self.assertEqual(partial.fragmented, ())
        split = assess([self.first], [Box(10, 20, 60, 60), Box(60, 20, 110, 60)])
        self.assertEqual(split.truncated, (0,))
        self.assertEqual(split.fragmented, (0,))
        self.assertEqual(split.missing, ())
        self.assertEqual(split.matched, ())

    def test_huge_box_does_not_become_two_correct_matches(self):
        result = assess([self.first, self.second], [Box(0, 0, 200, 160)])
        self.assertEqual(result.merged, (0,))
        self.assertEqual(result.oversized, ())
        self.assertEqual(result.matched, ())
        self.assertEqual(result.truncated, ())

    def test_single_staff_page_box_is_oversized_not_a_correct_match(self):
        result = assess([self.first], [Box(0, 0, 400, 400)])
        self.assertEqual(result.oversized, (0,))
        self.assertEqual(result.merged, ())
        self.assertEqual(result.matched, ())
        self.assertEqual(result.missing, ())
        self.assertEqual(result.truncated, ())

    def test_configurable_margins_and_a_valid_alternative(self):
        slightly_larger = Box(0, 10, 120, 70)  # area / reference area = 1.8
        result = assess([self.first], [slightly_larger, self.first], max_area_ratio=1.5)
        self.assertEqual(result.oversized, (0,))
        self.assertEqual(result.matched, ((0, 1),))
        self.assertEqual(result.duplicate, ())
        result = assess([self.first], [slightly_larger], max_area_ratio=1.8)
        self.assertEqual(result.oversized, ())
        self.assertEqual(result.matched, ((0, 0),))
        result = assess([self.first], [slightly_larger], max_area_ratio=1.79)
        self.assertEqual(result.oversized, (0,))
        self.assertEqual(result.matched, ())

    def test_oversized_and_separate_valid_staffs_do_not_change_merge_detection(self):
        right = Box(160, 20, 260, 60)
        wide_left = Box(0, 0, 130, 80)
        result = assess([self.first, right], [wide_left, right])
        self.assertEqual(result.oversized, (0,))
        self.assertEqual(result.merged, ())
        self.assertEqual(result.matched, ((1, 1),))
        covering_both = assess([self.first, right], [Box(0, 0, 270, 80)])
        self.assertEqual(covering_both.merged, (0,))
        self.assertEqual(covering_both.oversized, ())

    def test_decoys_duplicates_and_empty_inputs(self):
        result = assess([self.first], [self.first, self.first, Box(200, 200, 250, 240)])
        self.assertEqual(len(result.matched), 1)
        self.assertEqual(len(result.duplicate), 1)
        self.assertEqual(result.false_positive, (2,))
        self.assertEqual(assess([], [self.first]).false_positive, (0,))
        self.assertEqual(assess([self.first], []).missing, (0,))
        self.assertEqual(assess([], []).matched, ())

    def test_separate_columns_and_minimum_overlap(self):
        right = Box(160, 20, 260, 60)
        result = assess([self.first, right], [right, self.first, Box(109, 20, 150, 60)])
        self.assertEqual(result.matched, ((0, 1), (1, 0)))
        self.assertEqual(result.false_positive, (2,))
        self.assertEqual(result.merged, ())

    def test_invalid_geometry_and_thresholds(self):
        with self.assertRaises(ValueError):
            Box(0, 0, 0, 1)
        with self.assertRaises(ValueError):
            Box(0, float('nan'), 1, 2)
        with self.assertRaises(ValueError):
            assess([], [], complete=.1, relevant=.2)
        for area_ratio in (0.9, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                assess([], [], max_area_ratio=area_ratio)


class SyntheticPagesTests(unittest.TestCase):
    def test_multiple_staves_are_labelled_but_decoys_are_not(self):
        staffs = [Staff(20, 50, 180), Staff(220, 50, 380, slope=2, broken=True),
                  Staff(20, 130, 380)]
        pixels, references = make_page(400, 240, staffs, five_line_decoy=True, grid_decoy=True)
        self.assertEqual(len(pixels), 400 * 240)
        self.assertEqual(references, tuple(s.reference() for s in staffs))
        self.assertEqual(pixels[50 * 400 + 20], 0)
        self.assertEqual(pixels[55 * 400 + 20], 255)
        self.assertEqual(pixels[8 * 400 + 8], 0)
        self.assertEqual(pixels[200 * 400 + 8], 0)
        self.assertEqual(pixels[225 * 400 + 8], 0)
        self.assertEqual(assess(references, references).matched, ((0, 0), (1, 1), (2, 2)))

    def test_decoy_only_page_does_not_create_a_reference(self):
        pixels, references = make_page(200, 120, five_line_decoy=True, grid_decoy=True)
        self.assertFalse(references)
        self.assertIn(0, pixels)
        self.assertEqual(assess(references, [Box(8, 80, 192, 106)]).false_positive, (0,))

    def test_out_of_page_reference_rejected(self):
        with self.assertRaises(ValueError):
            make_page(100, 100, [Staff(2, 10, 90)])


if __name__ == '__main__':
    unittest.main()
