"""Protect model-evaluation semantics, not model-generated answers."""
from fractions import Fraction
import unittest

from evaluate_model_probe import parse_tokens, timing
from evaluate_vlm_probe import compact_bars, compact_timing
from local_vlm_cli_probe import generation_finished
import json


class ModelProbeTests(unittest.TestCase):
    def test_cli_token_limit_is_not_reported_as_finished(self):
        prompt = 'prompt eval time = 400 ms / 1024 tokens\n'
        self.assertTrue(generation_finished(0, prompt+'eval time = 300 ms / 99 runs', 4096))
        self.assertFalse(generation_finished(0, prompt+'eval time = 300 ms / 4096 runs', 4096))
        self.assertFalse(generation_finished(0, prompt, 4096))
        self.assertFalse(generation_finished(130, 'eval time = 300 ms / 99 runs', 4096))

    def test_duration_dots_tuplets_and_note_numbering(self):
        beats = parse_tokens('BAR BEAT DUR_8 DOTS_1 N_S6_F7 BEAT DUR_8 TUPLET_3_2 REST END_BAR'.split())[0]
        self.assertEqual(beats[0]['notes'][0]['string'], 1)
        self.assertEqual(timing(beats), [(Fraction(3, 4), False, False, 0),
                                         (Fraction(1, 3), False, True, 0)])

    def test_tie_belongs_only_to_preceding_note(self):
        beats = parse_tokens('BAR BEAT DUR_4 N_S6_F7 NTECH_TIE_DEST N_S5_FX END_BAR'.split())[0]
        self.assertEqual([n['tie'] for n in beats[0]['notes']], [True, False])
        self.assertIsNone(beats[0]['notes'][1]['fret'])
        self.assertEqual(timing(beats), [(Fraction(1), False, False, 1)])

    def test_corrupt_sequences_are_not_repaired(self):
        for text in ('BAR BEAT DUR_4 N_S6_F1',
                     'BAR BEAT DUR_4 N_S6_F1 N_S6_F2 END_BAR',
                     'BAR BEAT DUR_4 REST N_S6_F1 END_BAR',
                     'BAR BEAT DUR_4 N_S6_F1 REST END_BAR',
                     'BAR BEAT DUR_4 NTECH_TIE_DEST END_BAR',
                     'BAR BEAT DUR_4 DUR_8 REST END_BAR',
                     'BAR BEAT REST END_BAR', 'BAR END_BAR'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_tokens(text.split())

    def test_wrong_dot_rest_or_tie_cannot_pass(self):
        truth = timing(parse_tokens('BAR BEAT DUR_4 N_S6_F1 END_BAR'.split())[0])
        for text in ('BAR BEAT DUR_4 DOTS_1 N_S6_F1 END_BAR',
                     'BAR BEAT DUR_4 REST END_BAR',
                     'BAR BEAT DUR_4 N_S6_F1 NTECH_TIE_DEST END_BAR'):
            with self.subTest(text=text):
                self.assertNotEqual(timing(parse_tokens(text.split())[0]), truth)

    def test_gp_empty_bar_uses_meter_not_storage_duration(self):
        model = parse_tokens('BAR BEAT DUR_1 REST END_BAR'.split())[0]
        reference = [dict(model[0], duration=4, empty=True)]
        self.assertEqual(timing(model, [3, 4]), timing(reference, [3, 4]))
        self.assertEqual(timing(reference, [3, 4])[0][0], 3)
        # A regular quarter rest is not silently lengthened to a full bar.
        reference[0]['empty'] = False
        self.assertNotEqual(timing(model, [3, 4]), timing(reference, [3, 4]))

    def test_vlm_timing_matches_token_semantics(self):
        tokens = 'BAR BEAT DUR_8 DOTS_1 N_S6_F7 NTECH_TIE_DEST BEAT DUR_8 TUPLET_3_2 REST END_BAR'.split()
        compact = [[8, 1, 1, 1, 0, 1, 0], [8, 0, 3, 2, 1, 0, 0]]
        self.assertEqual(compact_timing(compact, [4, 4]), timing(parse_tokens(tokens)[0], [4, 4]))

    def test_vlm_invalid_or_uncertain_answers_fail(self):
        valid = {'bars': [[[4, 0, 1, 1, 0, 0, 0]]], 'uncertain': []}
        make = lambda data, finish='stop': {'response': {'choices': [
            {'finish_reason': finish, 'message': {'content': '```json\n'+json.dumps(data)+'\n```'}}]}}
        self.assertEqual(compact_bars(make(valid)), valid['bars'])
        invalid = [dict(valid, uncertain=['cannot read bar 1']), dict(valid, bars=[[None]]),
                   dict(valid, bars=[[[4, 0, 0, 1, 0, 0, 0]]]),
                   dict(valid, bars=[[[4, 0, 1, 1, 1, 1, 0]]]),
                   dict(valid, bars=[{'beats': valid['bars'][0]}])]
        for data in invalid:
            with self.subTest(data=data), self.assertRaises(ValueError):
                compact_bars(make(data))
        with self.assertRaises(ValueError):
            compact_bars(make(valid, 'length'))


if __name__ == '__main__':
    unittest.main()
