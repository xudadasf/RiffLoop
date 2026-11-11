import unittest

from note_evaluation import Note, assess, assess_crops


class NoteEvaluationTests(unittest.TestCase):
    def test_correct_missing_extra_and_wrong_fret_are_separate(self):
        reference = [Note(.1, 1, 2), Note(.3, 2, 10), Note(.5, 3, 0)]
        predictions = [Note(.1, 1, 2), Note(.3, 2, 1), Note(.9, 4, 3)]
        result = assess(reference, predictions, max_x_error=.01)
        self.assertEqual((result.localized, result.correct, result.missing, result.extra), (2, 1, 1, 1))
        self.assertEqual(result.localized_but_incorrect, 1)
        self.assertEqual((result.precision, result.recall), (1 / 3, 1 / 3))

    def test_wrong_string_unknown_and_duplicate_do_not_count_correct(self):
        result = assess([Note(.5, 2, 12)],
                        [Note(.5, 1, 12), Note(.5, 2, None), Note(.5, 2, 12), Note(.5, 2, 12)],
                        max_x_error=0)
        self.assertEqual((result.correct, result.localized, result.extra, result.unresolved), (1, 1, 3, 1))
        self.assertEqual(result.precision, .25)

    def test_chord_requires_each_string_and_fret(self):
        reference = [Note(.5, 1, 0), Note(.5, 2, 1), Note(.5, 3, 2)]
        predictions = [Note(.5, 3, 2), Note(.5, 1, 0), Note(.5, 2, 0)]
        result = assess(reference, predictions, max_x_error=0)
        self.assertEqual((result.localized, result.correct, result.localized_but_incorrect), (3, 2, 1))

    def test_matching_is_not_greedy_and_respects_distance(self):
        # A greedy first match of .5 to .49 would strand reference .48.
        result = assess([Note(.5, 1, 1), Note(.48, 1, 1)],
                        [Note(.49, 1, 1), Note(.51, 1, 1)], max_x_error=.011)
        self.assertEqual((result.localized, result.correct), (2, 2))
        result = assess([Note(.3, 1, 1)], [Note(.4, 1, 1)], max_x_error=.05)
        self.assertEqual((result.missing, result.extra, result.correct), (1, 1, 0))

    def test_different_crops_cannot_match_each_other(self):
        result = assess_crops([([Note(.5, 1, 5)], []), ([], [Note(.5, 1, 5)])], max_x_error=.01)
        self.assertEqual((result.missing, result.extra, result.correct), (1, 1, 0))
        self.assertEqual((result.precision, result.recall), (0, 0))

    def test_empty_cases_do_not_report_perfect_rates(self):
        result = assess([], [], max_x_error=.01)
        self.assertIsNone(result.precision)
        self.assertIsNone(result.recall)
        result = assess([], [Note(.5, 1, 0)], max_x_error=.01)
        self.assertEqual(result.precision, 0)
        self.assertIsNone(result.recall)

    def test_invalid_inputs_are_rejected(self):
        for reference in ([Note(float('nan'), 1, 1)], [Note(-.1, 1, 1)], [Note(.1, None, 1)],
                          [Note(.1, True, 1)], [Note(.1, 1, 37)]):
            with self.subTest(reference=reference), self.assertRaises(ValueError):
                assess(reference, [], max_x_error=.01)
        for tolerance in (float('nan'), -1, 1.1, True):
            with self.subTest(tolerance=tolerance), self.assertRaises(ValueError):
                assess([], [], max_x_error=tolerance)
            with self.subTest(empty_crops_tolerance=tolerance), self.assertRaises(ValueError):
                assess_crops([], max_x_error=tolerance)
        with self.assertRaises(ValueError):
            assess([Note(.1, 1, 1)] * 513, [], max_x_error=.01)


if __name__ == '__main__':
    unittest.main()
