import json
import unittest

from evaluate_bar_probe import note_groups, note_matches, reference_notes
from prepare_bar_probe import bar_intervals


def prediction(data):
    return {'response': {'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps(data)}}]}}


class BarProbeTests(unittest.TestCase):
    def test_bar_boundaries_ignore_stems_and_double_lines(self):
        staff = {'ys': [10, 16, 22, 28, 34, 40], 'left': 0, 'right': 120}
        lines = [(60, 10, 60, 40), (61, 10, 61, 40), (30, 22, 30, 55)]
        intervals = bar_intervals(staff, lines)
        self.assertEqual(len(intervals), 2)
        self.assertEqual(intervals[0][0], 0)
        self.assertEqual(intervals[-1][1], 120)

    def test_chords_are_unordered_but_groups_and_strings_matter(self):
        groups = note_groups(prediction({'groups': [[[3, 7, False], [1, 5, False]]], 'uncertain': []}))
        self.assertEqual(groups, [[(1, 5, False), (3, 7, False)]])
        self.assertNotEqual(groups, [[(1, 5, False)], [(3, 7, False)]])
        self.assertEqual(note_matches(groups, [[(2, 5, False), (3, 7, False)]]), 1)

    def test_missing_repeated_notes_do_not_match_all_repetitions(self):
        note = [(1, 7, False)]
        self.assertEqual(note_matches([note], [note, note, note]), 1)
        self.assertEqual(note_matches([[(1, 5, False)], note], [note, [(1, 5, False)]]), 1)

    def test_empty_rest_and_dead_note_are_distinct(self):
        self.assertEqual(note_groups(prediction({'groups': [], 'uncertain': []})), [])
        dead = note_groups(prediction({'groups': [[[6, None, True]]], 'uncertain': []}))
        ref = reference_notes([{'notes': [{'string': 6, 'fret': 0, 'dead': True}]}])
        self.assertEqual(dead, ref)

    def test_unknown_and_malformed_notes_cannot_be_repaired(self):
        for groups in ([[[1, None, False]]], [[[1, 7, True]]], [[[True, 7, False]]],
                       [[[1, True, False]]], [[[7, 3, False]]],
                       [[[1, 3, False], [1, 4, False]]], [None], [[]]):
            with self.subTest(groups=groups), self.assertRaises(ValueError):
                note_groups(prediction({'groups': groups, 'uncertain': []}))
        with self.assertRaises(ValueError):
            note_groups(prediction({'groups': [], 'uncertain': ['unreadable']}))


if __name__ == '__main__':
    unittest.main()
